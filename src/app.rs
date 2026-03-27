//! App state and main event loop
//!
//! All SSH operations run on dedicated threads so the UI never blocks.

use crate::config::Config;
use crate::server;
use crate::session::{self, Session};
use crate::terminal_pane::EmbeddedTerminal;
use crate::ui;

use crossterm::event::{self, Event, KeyCode, KeyModifiers};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use ratatui::prelude::*;
use std::io::stdout;
use std::sync::mpsc;
use std::time::Duration;

/// Which pane has focus
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Focus {
    SessionList,
    Terminal,
}

// ── Background responses ────────────────────────────────────────────

enum BgResponse {
    Sessions(Result<Vec<Session>, String>),
    Spawned(Result<String, String>),
    Killed(String, Result<(), String>),
    Logs(Result<String, String>),
}

/// Application state
pub struct App {
    pub config: Config,
    pub sessions: Vec<Session>,
    pub selected: usize,
    pub focus: Focus,
    pub terminal: Option<EmbeddedTerminal>,
    pub terminal_session_name: String,
    pub status: String,
    pub should_quit: bool,
    pub show_logs: Option<String>,
    pub loading: bool,
    bg_tx: mpsc::Sender<BgResponse>,
    bg_rx: mpsc::Receiver<BgResponse>,
}

impl App {
    pub fn new(config: Config) -> Self {
        let (bg_tx, bg_rx) = mpsc::channel();

        Self {
            config,
            sessions: Vec::new(),
            selected: 0,
            focus: Focus::SessionList,
            terminal: None,
            terminal_session_name: String::new(),
            status: "Connecting...".to_string(),
            should_quit: false,
            show_logs: None,
            loading: false,
            bg_tx,
            bg_rx,
        }
    }

    /// Request a session list refresh (non-blocking)
    pub fn refresh_sessions(&mut self) {
        self.loading = true;
        let config = self.config.clone();
        let tx = self.bg_tx.clone();
        std::thread::spawn(move || {
            let result = session::list_sessions(&config).map_err(|e| e.to_string());
            let _ = tx.send(BgResponse::Sessions(result));
        });
    }

    /// Request spawning a new session (non-blocking)
    pub fn spawn_session(&mut self) {
        self.status = "Spawning session...".to_string();
        self.loading = true;
        let config = self.config.clone();
        let tx = self.bg_tx.clone();
        std::thread::spawn(move || {
            let result = session::spawn(&config).map_err(|e| e.to_string());
            let _ = tx.send(BgResponse::Spawned(result));
        });
    }

    /// Request killing the selected session (non-blocking)
    pub fn kill_session(&mut self) {
        if let Some(s) = self.sessions.get(self.selected) {
            let name = s.name.clone();
            if self.terminal_session_name == name {
                self.close_terminal();
            }
            self.status = format!("Stopping {name}...");
            self.loading = true;
            let config = self.config.clone();
            let tx = self.bg_tx.clone();
            std::thread::spawn(move || {
                let result = session::stop(&config, &name).map_err(|e| e.to_string());
                let _ = tx.send(BgResponse::Killed(name, result));
            });
        }
    }

    /// Request logs for selected session (non-blocking)
    pub fn show_logs(&mut self) {
        if let Some(s) = self.sessions.get(self.selected) {
            self.status = "Fetching logs...".to_string();
            self.loading = true;
            let config = self.config.clone();
            let name = s.name.clone();
            let tx = self.bg_tx.clone();
            std::thread::spawn(move || {
                let result = session::logs(&config, &name).map_err(|e| e.to_string());
                let _ = tx.send(BgResponse::Logs(result));
            });
        }
    }

    /// Drain all pending background responses
    fn poll_background(&mut self) {
        while let Ok(resp) = self.bg_rx.try_recv() {
            self.loading = false;
            match resp {
                BgResponse::Sessions(Ok(sessions)) => {
                    self.status = format!(
                        "{}  ·  {} session(s)",
                        self.config.ssh_target(),
                        sessions.len()
                    );
                    self.sessions = sessions;
                    if self.selected >= self.sessions.len() && !self.sessions.is_empty() {
                        self.selected = self.sessions.len() - 1;
                    }
                }
                BgResponse::Sessions(Err(e)) => {
                    self.status = format!("Error: {e}");
                }
                BgResponse::Spawned(Ok(name)) => {
                    self.status = format!("Session {name} created");
                    self.refresh_sessions();
                }
                BgResponse::Spawned(Err(e)) => {
                    self.status = format!("Spawn failed: {e}");
                }
                BgResponse::Killed(name, Ok(())) => {
                    self.status = format!("Session {name} removed");
                    self.refresh_sessions();
                }
                BgResponse::Killed(_, Err(e)) => {
                    self.status = format!("Kill failed: {e}");
                }
                BgResponse::Logs(Ok(text)) => {
                    self.show_logs = Some(text);
                }
                BgResponse::Logs(Err(e)) => {
                    self.status = format!("Logs failed: {e}");
                }
            }
        }
    }

    /// Open embedded terminal for the selected session
    pub fn open_terminal(&mut self, cols: u16, rows: u16) {
        let session_info = self
            .sessions
            .get(self.selected)
            .map(|s| (s.name.clone(), s.status.clone()));
        let Some((name, status)) = session_info else {
            self.status = "No session selected".to_string();
            return;
        };
        if status != "running" {
            self.status = format!("Session is {status}");
            return;
        }

        if self.terminal_session_name == name {
            self.focus = Focus::Terminal;
            return;
        }

        self.close_terminal();

        let ssh_target = self.config.ssh_target();
        let docker_cmd =
            format!("docker exec -it {name} bash -c 'cd /workspace/repo && exec bash'");

        match EmbeddedTerminal::new("ssh", &["-t", &ssh_target, &docker_cmd], cols, rows) {
            Ok(term) => {
                self.terminal = Some(term);
                self.terminal_session_name = name.clone();
                self.focus = Focus::Terminal;
                self.status = format!("Attached to {name}");
            }
            Err(e) => {
                self.status = format!("Failed to attach: {e}");
            }
        }
    }

    /// Close the embedded terminal
    pub fn close_terminal(&mut self) {
        self.terminal = None;
        self.terminal_session_name.clear();
        self.focus = Focus::SessionList;
    }
}

/// Main entry point — sets up terminal and runs event loop
pub fn run(config: Config) -> Result<(), Box<dyn std::error::Error>> {
    enable_raw_mode()?;
    stdout().execute(EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout());
    let mut term = Terminal::new(backend)?;

    let mut app = App::new(config);
    app.refresh_sessions(); // fires async — UI renders immediately

    loop {
        // Drain background results
        app.poll_background();

        // Draw UI
        term.draw(|frame| ui::draw(frame, &app))?;

        // Handle input (poll with 50ms timeout for snappy UI)
        if event::poll(Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                if app.show_logs.is_some() {
                    app.show_logs = None;
                    continue;
                }

                // Tab toggles focus when terminal is open
                if key.code == KeyCode::Tab && app.terminal.is_some() {
                    app.focus = match app.focus {
                        Focus::SessionList => Focus::Terminal,
                        Focus::Terminal => Focus::SessionList,
                    };
                } else if key.code == KeyCode::Esc && app.terminal.is_some() {
                    // Esc always closes terminal
                    app.close_terminal();
                } else {
                    match app.focus {
                        Focus::Terminal => {
                            if let Some(ref mut term) = app.terminal {
                                let bytes = key_to_bytes(key.code, key.modifiers);
                                if !bytes.is_empty() {
                                    let _ = term.write(&bytes);
                                }
                            }
                        }
                        Focus::SessionList => match key.code {
                            KeyCode::Char('q') if app.terminal.is_none() => {
                                app.should_quit = true;
                            }
                            KeyCode::Char('n') => app.spawn_session(),
                            KeyCode::Char('k') => app.kill_session(),
                            KeyCode::Char('r') => app.refresh_sessions(),
                            KeyCode::Char('l') => app.show_logs(),
                            KeyCode::Enter => {
                                let area = term.size()?;
                                let term_cols = (area.width * 3 / 4).saturating_sub(2);
                                let term_rows = area.height.saturating_sub(3);
                                app.open_terminal(term_cols, term_rows);
                            }
                            KeyCode::Up => {
                                if app.selected > 0 {
                                    app.selected -= 1;
                                }
                            }
                            KeyCode::Down => {
                                if app.selected + 1 < app.sessions.len() {
                                    app.selected += 1;
                                }
                            }
                            _ => {}
                        },
                    }
                }
            }
        }

        if app.should_quit {
            break;
        }
    }

    // Cleanup
    app.close_terminal();
    server::close_mux(&app.config);

    disable_raw_mode()?;
    stdout().execute(LeaveAlternateScreen)?;
    Ok(())
}

/// Convert a crossterm key event to raw bytes for the PTY
fn key_to_bytes(code: KeyCode, modifiers: KeyModifiers) -> Vec<u8> {
    match code {
        KeyCode::Char(c) => {
            if modifiers.contains(KeyModifiers::CONTROL) {
                let byte = (c as u8).wrapping_sub(b'a').wrapping_add(1);
                vec![byte]
            } else {
                let mut buf = [0u8; 4];
                let s = c.encode_utf8(&mut buf);
                s.as_bytes().to_vec()
            }
        }
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Backspace => vec![0x7f],
        KeyCode::Tab => vec![b'\t'],
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => vec![0x1b, b'[', b'A'],
        KeyCode::Down => vec![0x1b, b'[', b'B'],
        KeyCode::Right => vec![0x1b, b'[', b'C'],
        KeyCode::Left => vec![0x1b, b'[', b'D'],
        KeyCode::Home => vec![0x1b, b'[', b'H'],
        KeyCode::End => vec![0x1b, b'[', b'F'],
        KeyCode::Delete => vec![0x1b, b'[', b'3', b'~'],
        KeyCode::PageUp => vec![0x1b, b'[', b'5', b'~'],
        KeyCode::PageDown => vec![0x1b, b'[', b'6', b'~'],
        _ => vec![],
    }
}
