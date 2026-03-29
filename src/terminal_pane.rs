//! Embedded terminal — runs `ssh -t ... docker exec` in a PTY
//! and exposes the parsed terminal state for rendering with tui-term.

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::Read;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use vt100::Parser;

/// An embedded terminal session backed by a real PTY
pub struct EmbeddedTerminal {
    /// vt100 parser holding the terminal screen state
    pub parser: Arc<Mutex<Parser>>,
    /// PTY writer — send keystrokes here
    writer: Box<dyn std::io::Write + Send>,
    /// Child process handle — killed on drop
    child: Box<dyn portable_pty::Child + Send>,
    /// PTY master — dropped before reader thread to unblock it
    master: Option<Box<dyn portable_pty::MasterPty + Send>>,
    /// Reader thread handle — joined on drop
    reader_thread: Option<JoinHandle<()>>,
}

impl EmbeddedTerminal {
    pub fn new(
        command: &str,
        args: &[&str],
        cols: u16,
        rows: u16,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let pty_system = native_pty_system();

        let pair = pty_system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let mut cmd = CommandBuilder::new(command);
        cmd.args(args);

        let child = pair.slave.spawn_command(cmd)?;
        // Close parent's copy of slave fd so EOF propagates correctly
        drop(pair.slave);

        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;

        let parser = Arc::new(Mutex::new(Parser::new(rows, cols, 1000)));

        let parser_clone = Arc::clone(&parser);
        let reader_thread = std::thread::spawn(move || {
            let mut buf = [0u8; 65536];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
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
            master: Some(pair.master),
            reader_thread: Some(reader_thread),
        })
    }

    /// Send raw bytes (keystrokes) to the PTY
    pub fn write(&mut self, data: &[u8]) -> Result<(), std::io::Error> {
        use std::io::Write;
        self.writer.write_all(data)?;
        self.writer.flush()?;
        Ok(())
    }

    /// Resize the PTY (call when pane dimensions change)
    pub fn resize(&self, cols: u16, rows: u16) {
        if let Some(ref master) = self.master {
            let _ = master.resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            });
        }
        if let Ok(mut p) = self.parser.lock() {
            p.set_size(rows, cols);
        }
    }
}

impl Drop for EmbeddedTerminal {
    fn drop(&mut self) {
        let _ = self.child.kill();
        // Drop master first to close PTY fd and unblock reader thread
        self.master.take();
        let _ = self.child.wait();
        // Join reader thread
        if let Some(handle) = self.reader_thread.take() {
            let _ = handle.join();
        }
    }
}
