//! Embedded terminal — runs `ssh -t ... docker exec` in a PTY
//! and exposes the parsed terminal state for rendering with tui-term.

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::Read;
use std::sync::{Arc, Mutex};
use vt100::Parser;

/// An embedded terminal session backed by a real PTY
pub struct EmbeddedTerminal {
    /// vt100 parser holding the terminal screen state
    pub parser: Arc<Mutex<Parser>>,
    /// PTY writer — send keystrokes here
    writer: Box<dyn std::io::Write + Send>,
    /// Child process handle — killed on drop
    child: Box<dyn portable_pty::Child + Send>,
    /// PTY master — held to control lifetime; dropped to close reader thread
    _master: Box<dyn portable_pty::MasterPty + Send>,
}

impl EmbeddedTerminal {
    /// Start a new embedded terminal running the given command.
    /// `cols` and `rows` are the initial terminal size.
    pub fn new(command: &str, args: &[&str], cols: u16, rows: u16) -> Result<Self, Box<dyn std::error::Error>> {
        let pty_system = native_pty_system();

        // Create PTY with the given size
        let pair = pty_system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        // Build the command to run inside the PTY
        let mut cmd = CommandBuilder::new(command);
        cmd.args(args);

        // Spawn the process
        let child = pair.slave.spawn_command(cmd)?;

        // Get a reader for the PTY output
        let mut reader = pair.master.try_clone_reader()?;

        // Get a writer to send input to the PTY
        let writer = pair.master.take_writer()?;

        // Create the vt100 parser that will interpret the terminal output
        let parser = Arc::new(Mutex::new(Parser::new(rows, cols, 1000)));

        // Spawn a thread that reads PTY output and feeds it to the parser
        let parser_clone = Arc::clone(&parser);
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,  // PTY closed
                    Ok(n) => {
                        if let Ok(mut p) = parser_clone.lock() {
                            p.process(&buf[..n]);
                        }
                    }
                    Err(_) => break,
                }
            }
        });

        Ok(Self {
            parser,
            writer,
            child,
            _master: pair.master,
        })
    }

    /// Send raw bytes (keystrokes) to the PTY
    pub fn write(&mut self, data: &[u8]) -> Result<(), std::io::Error> {
        use std::io::Write;
        self.writer.write_all(data)?;
        self.writer.flush()?;
        Ok(())
    }

    /// Resize the PTY
    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), Box<dyn std::error::Error>> {
        // Note: portable-pty doesn't expose resize on the writer directly.
        // For now we update the parser size; full resize needs master handle.
        if let Ok(mut p) = self.parser.lock() {
            p.set_size(rows, cols);
        }
        Ok(())
    }
}

impl Drop for EmbeddedTerminal {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
