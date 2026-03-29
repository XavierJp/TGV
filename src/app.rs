//! App state and main event loop
//!
//! All SSH operations run on dedicated threads so the UI never blocks.
//! When entering a session, two panes open: shell + Claude Code,
//! both backed by tmux for persistence.

use crate::config::Config;
use crate::server;
use crate::session::{self, Session};
use crate::terminal_pane::EmbeddedTerminal;
use crate::ui;

use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyModifiers, MouseButton,
    MouseEventKind,
};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use ratatui::prelude::*;
use std::collections::VecDeque;
use std::io::stdout;
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Which pane has focus
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Focus {
    SessionList,
    Terminal,
}

/// Input mode overlay
#[derive(Debug, Clone, PartialEq)]
pub enum InputMode {
    None,
    BranchInput(String),
    ConfirmKill(String), // container name pending kill
}

enum BgResponse {
    Sessions(Result<Vec<Session>, String>),
    Spawned(Result<String, String>),
    Killed(String, Result<(), String>),
    Latency(Option<u128>),
    GitMetrics {
        name: String,
        insertions: Option<u32>,
        deletions: Option<u32>,
    },
}

/// Rolling network statistics from last N pings
const PING_WINDOW: usize = 10;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum NetStatus {
    Unknown,
    Good, // avg < 150ms, loss < 10%, jitter < 50ms
    Poor, // everything else with some connectivity
    Dead, // 100% loss or no data
}

impl NetStatus {
    pub fn icon(&self) -> &'static str {
        match self {
            Self::Unknown => "◌",
            Self::Good => "●",
            Self::Poor => "◐",
            Self::Dead => "○",
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            Self::Unknown => "···",
            Self::Good => "Good",
            Self::Poor => "Poor",
            Self::Dead => "Dead",
        }
    }
}

#[derive(Debug, Clone)]
pub struct NetworkStats {
    /// Rolling window of recent pings (None = failed)
    samples: VecDeque<Option<u128>>,
    pub status: NetStatus,
    pub avg_ms: Option<u128>,
    pub jitter_ms: Option<u128>,
    pub loss_pct: u8,
}

impl Default for NetworkStats {
    fn default() -> Self {
        Self {
            samples: VecDeque::new(),
            status: NetStatus::Unknown,
            avg_ms: None,
            jitter_ms: None,
            loss_pct: 0,
        }
    }
}

impl NetworkStats {
    pub fn push(&mut self, sample: Option<u128>) {
        self.samples.push_back(sample);
        if self.samples.len() > PING_WINDOW {
            self.samples.pop_front();
        }
        self.recompute();
    }

    fn recompute(&mut self) {
        if self.samples.is_empty() {
            self.status = NetStatus::Unknown;
            self.avg_ms = None;
            self.jitter_ms = None;
            self.loss_pct = 0;
            return;
        }

        let total = self.samples.len();
        let successes: Vec<u128> = self.samples.iter().filter_map(|s| *s).collect();
        let ok_count = successes.len();

        self.loss_pct = if total > 0 {
            ((total - ok_count) * 100 / total) as u8
        } else {
            100
        };

        if successes.is_empty() {
            self.status = NetStatus::Dead;
            self.avg_ms = None;
            self.jitter_ms = None;
            return;
        }

        let avg = successes.iter().sum::<u128>() / successes.len() as u128;
        self.avg_ms = Some(avg);

        // Jitter = average absolute difference between consecutive successful pings
        if successes.len() >= 2 {
            let diffs: Vec<u128> = successes
                .windows(2)
                .map(|w| (w[1] as i128 - w[0] as i128).unsigned_abs())
                .collect();
            self.jitter_ms = Some(diffs.iter().sum::<u128>() / diffs.len() as u128);
        } else {
            self.jitter_ms = None;
        }

        // Classify
        self.status = if self.loss_pct >= 100 {
            NetStatus::Dead
        } else if avg < 150 && self.loss_pct < 10 && self.jitter_ms.unwrap_or(0) < 50 {
            NetStatus::Good
        } else {
            NetStatus::Poor
        };
    }
}

/// Application state
pub struct App {
    pub config: Config,
    pub sessions: Vec<Session>,
    pub selected: usize,
    pub focus: Focus,
    pub terminal: Option<EmbeddedTerminal>,
    pub attached_session: String,
    pub notifications: Vec<String>,
    pending_ops: u32, // guard against unbounded thread spawning
    pub notification_scroll: u16,
    pub should_quit: bool,
    pub input_mode: InputMode,
    pub left_pane_percent: u16,
    pub dragging_border: bool,
    pub network: NetworkStats,
    last_ping: Instant,
    pub pane_rects: PaneRects,
    bg_tx: mpsc::Sender<BgResponse>,
    bg_rx: mpsc::Receiver<BgResponse>,
}

#[derive(Default, Clone)]
pub struct PaneRects {
    pub session_list: Rect,
    pub claude_pane: Rect,
    pub notifications: Rect,
    pub main_area: Rect,
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
            attached_session: String::new(),
            notifications: vec!["Connecting...".to_string()],
            pending_ops: 0,
            notification_scroll: 0,
            should_quit: false,
            input_mode: InputMode::None,
            left_pane_percent: 18,
            dragging_border: false,
            network: NetworkStats::default(),
            last_ping: Instant::now(),
            pane_rects: PaneRects::default(),
            bg_tx,
            bg_rx,
        }
    }

    pub fn notify(&mut self, msg: String) {
        self.notifications.push(msg);
        // Cap at 500 entries to prevent unbounded growth
        if self.notifications.len() > 500 {
            self.notifications.drain(..self.notifications.len() - 500);
        }
        self.notification_scroll = self.notifications.len().saturating_sub(1) as u16;
    }

    pub fn ping(&mut self) {
        self.last_ping = Instant::now();
        let config = self.config.clone();
        let tx = self.bg_tx.clone();
        std::thread::spawn(move || {
            let start = Instant::now();
            let result = server::ssh_ping(&config);
            let ms = match result {
                Ok(r) if r.success => Some(start.elapsed().as_millis()),
                _ => None,
            };
            let _ = tx.send(BgResponse::Latency(ms));
        });
    }

    pub fn maybe_ping(&mut self) {
        if self.last_ping.elapsed() > Duration::from_secs(5) {
            self.ping();
        }
    }

    pub fn refresh_sessions(&mut self) {
        if self.pending_ops > 20 { return; }
        self.pending_ops += 1;
        let config = self.config.clone();
        let tx = self.bg_tx.clone();
        std::thread::spawn(move || {
            let result = session::list_sessions(&config).map_err(|e| e.to_string());
            let _ = tx.send(BgResponse::Sessions(result));
        });
    }

    pub fn spawn_session(&mut self, branch: &str) {
        self.notify(format!("Spawning session on {branch}..."));
        let config = self.config.clone();
        let branch = branch.to_string();
        let tx = self.bg_tx.clone();
        std::thread::spawn(move || {
            let result = session::spawn(&config, &branch).map_err(|e| e.to_string());
            let _ = tx.send(BgResponse::Spawned(result));
        });
    }

    pub fn fetch_git_metrics(&mut self) {
        if self.pending_ops > 20 { return; }
        for s in &self.sessions {
            if s.status != "running" {
                continue;
            }
            self.pending_ops += 1;
            let config = self.config.clone();
            let name = s.name.clone();
            let tx = self.bg_tx.clone();
            std::thread::spawn(move || {
                if let Ok(m) = session::git_metrics(&config, &name) {
                    let _ = tx.send(BgResponse::GitMetrics {
                        name,
                        insertions: m.insertions,
                        deletions: m.deletions,
                    });
                }
            });
        }
    }

    pub fn kill_session(&mut self) {
        if let Some(s) = self.sessions.get(self.selected) {
            self.input_mode = InputMode::ConfirmKill(s.name.clone());
        }
    }

    pub fn force_kill_session(&mut self, name: &str) {
        if self.attached_session == name {
            self.close_terminal();
        }
        self.notify(format!("Stopping {name}..."));
        let config = self.config.clone();
        let name = name.to_string();
        let tx = self.bg_tx.clone();
        std::thread::spawn(move || {
            let result = session::stop(&config, &name).map_err(|e| e.to_string());
            let _ = tx.send(BgResponse::Killed(name, result));
        });
    }

    /// Open Claude Code pane for the selected session
    pub fn open_session(&mut self, cols: u16, rows: u16) {
        let Some(s) = self.sessions.get(self.selected) else {
            self.notify("No session selected".to_string());
            return;
        };
        if s.status != "running" {
            self.notify(format!("Session is {}", s.status));
            return;
        }
        let container = s.name.clone();

        if self.attached_session == container {
            self.focus = Focus::Terminal;
            return;
        }

        self.close_terminal();

        let docker_cmd = session::tmux_attach_cmd(&container, "claude", "claude");

        // Try ET first (resilient to network drops), fall back to SSH
        let (bin, args) = if which::which("et").is_ok() {
            let et_target = format!(
                "{}@{}:{}",
                self.config.server.user,
                self.config.server.host,
                self.config.server.et_port
            );
            self.notify(format!("Connecting via ET to {container}..."));
            (
                "et".to_string(),
                vec![
                    et_target,
                    "-c".to_string(),
                    docker_cmd,
                ],
            )
        } else {
            self.notify("ET not found, using SSH (install ET for resilient connections)".to_string());
            let ssh_target = self.config.ssh_target();
            (
                "ssh".to_string(),
                vec!["-t".to_string(), ssh_target, docker_cmd],
            )
        };

        let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        match EmbeddedTerminal::new(&bin, &arg_refs, cols, rows) {
            Ok(term) => {
                self.terminal = Some(term);
                self.attached_session = container.clone();
                self.focus = Focus::Terminal;
                self.notify(format!("Attached to {container}"));
            }
            Err(e) => {
                self.notify(format!("Failed to attach: {e}"));
            }
        }
    }

    pub fn has_terminals(&self) -> bool {
        self.terminal.is_some()
    }

    pub fn close_terminal(&mut self) {
        self.terminal = None;
        self.attached_session.clear();
        self.focus = Focus::SessionList;
    }

    fn poll_background(&mut self) {
        while let Ok(resp) = self.bg_rx.try_recv() {
            self.pending_ops = self.pending_ops.saturating_sub(1);
            match resp {
                BgResponse::Sessions(Ok(sessions)) => {
                    self.notify(format!(
                        "{}  ·  {} session(s)",
                        self.config.ssh_target(),
                        sessions.len()
                    ));
                    self.sessions = sessions;
                    if self.selected >= self.sessions.len() && !self.sessions.is_empty() {
                        self.selected = self.sessions.len() - 1;
                    }
                    self.fetch_git_metrics();
                }
                BgResponse::Sessions(Err(e)) => self.notify(format!("Error: {e}")),
                BgResponse::Spawned(Ok(name)) => {
                    self.notify(format!("Session {name} created"));
                    self.refresh_sessions();
                }
                BgResponse::Spawned(Err(e)) => self.notify(format!("Spawn failed: {e}")),
                BgResponse::Killed(name, Ok(())) => {
                    self.notify(format!("Session {name} removed"));
                    self.refresh_sessions();
                }
                BgResponse::Killed(_, Err(e)) => self.notify(format!("Kill failed: {e}")),
                BgResponse::Latency(ms) => {
                    self.network.push(ms);
                }
                BgResponse::GitMetrics {
                    name,
                    insertions,
                    deletions,
                } => {
                    if let Some(s) = self.sessions.iter_mut().find(|s| s.name == name) {
                        s.insertions = insertions;
                        s.deletions = deletions;
                    }
                }
            }
        }
    }

}

/// Main entry point
pub fn run(config: Config) -> Result<(), Box<dyn std::error::Error>> {
    enable_raw_mode()?;
    stdout().execute(EnterAlternateScreen)?;
    stdout().execute(EnableMouseCapture)?;

    // Ensure terminal is restored even on panic
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = stdout().execute(DisableMouseCapture);
        let _ = disable_raw_mode();
        let _ = stdout().execute(LeaveAlternateScreen);
        default_hook(info);
    }));

    let backend = CrosstermBackend::new(stdout());
    let mut term = Terminal::new(backend)?;

    let mut app = App::new(config);
    app.refresh_sessions();
    app.ping();

    loop {
        app.poll_background();
        app.maybe_ping();

        term.draw(|frame| ui::draw(frame, &mut app))?;

        if event::poll(Duration::from_millis(16))? {
            match event::read()? {
                Event::Key(key) => {
                    // Input mode
                    if let InputMode::BranchInput(ref mut buf) = app.input_mode {
                        match key.code {
                            KeyCode::Enter => {
                                let branch = if buf.is_empty() {
                                    session::random_branch_name()
                                } else {
                                    buf.clone()
                                };
                                app.input_mode = InputMode::None;
                                app.spawn_session(&branch);
                            }
                            KeyCode::Esc => app.input_mode = InputMode::None,
                            KeyCode::Backspace => { buf.pop(); }
                            KeyCode::Char(c) => buf.push(c),
                            _ => {}
                        }
                        continue;
                    }

                    // Confirm kill modal
                    if let InputMode::ConfirmKill(ref name) = app.input_mode {
                        let name = name.clone();
                        match key.code {
                            KeyCode::Char('y') | KeyCode::Enter => {
                                app.input_mode = InputMode::None;
                                app.force_kill_session(&name);
                            }
                            _ => {
                                app.input_mode = InputMode::None;
                                app.notify("Kill cancelled".to_string());
                            }
                        }
                        continue;
                    }

                    // Esc switches back to session list
                    if key.code == KeyCode::Esc && app.focus == Focus::Terminal {
                        app.focus = Focus::SessionList;
                        continue;
                    }

                    match app.focus {
                        Focus::Terminal => {
                            if let Some(ref mut t) = app.terminal {
                                let bytes = key_to_bytes(key.code, key.modifiers);
                                if !bytes.is_empty() {
                                    let _ = t.write(&bytes);
                                }
                            }
                        }
                        Focus::SessionList => match key.code {
                            KeyCode::Char('q') => app.should_quit = true,
                            KeyCode::Char('n') => {
                                app.input_mode = InputMode::BranchInput(String::new());
                            }
                            KeyCode::Char('k') => app.kill_session(),
                            KeyCode::Enter => {
                                let area = term.size()?;
                                let right_width = (area.width as u16)
                                    .saturating_mul(100 - app.left_pane_percent) / 100;
                                let cols = right_width.saturating_sub(2);
                                let rows = area.height.saturating_sub(3);
                                app.open_session(cols, rows);
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
                Event::Mouse(mouse) => {
                    let col = mouse.column;
                    let row = mouse.row;
                    match mouse.kind {
                        MouseEventKind::Down(MouseButton::Left) => {
                            if app.has_terminals() {
                                let border_col = app.pane_rects.claude_pane.x;
                                if col == border_col
                                    && row >= app.pane_rects.main_area.y
                                    && row < app.pane_rects.main_area.y
                                        + app.pane_rects.main_area.height
                                {
                                    app.dragging_border = true;
                                } else if rect_contains(app.pane_rects.session_list, col, row) {
                                    app.focus = Focus::SessionList;
                                    let inner_y = row.saturating_sub(
                                        app.pane_rects.session_list.y + 1,
                                    );
                                    if (inner_y as usize) < app.sessions.len() {
                                        app.selected = inner_y as usize;
                                    }
                                } else if rect_contains(app.pane_rects.claude_pane, col, row) {
                                    app.focus = Focus::Terminal;
                                }
                            } else if rect_contains(app.pane_rects.session_list, col, row) {
                                app.focus = Focus::SessionList;
                                let inner_y =
                                    row.saturating_sub(app.pane_rects.session_list.y + 1);
                                if (inner_y as usize) < app.sessions.len() {
                                    app.selected = inner_y as usize;
                                }
                            }
                        }
                        MouseEventKind::Drag(MouseButton::Left) => {
                            if app.dragging_border {
                                let main = app.pane_rects.main_area;
                                if main.width > 0 && col > main.x + 4
                                    && col < main.x + main.width - 4
                                {
                                    let pct =
                                        ((col - main.x) as u32 * 100 / main.width as u32) as u16;
                                    app.left_pane_percent = pct.clamp(10, 60);
                                    // Resize PTY to match new pane
                                    if let Some(ref t) = app.terminal {
                                        let pane = app.pane_rects.claude_pane;
                                        if pane.width > 2 && pane.height > 2 {
                                            t.resize(pane.width - 2, pane.height - 2);
                                        }
                                    }
                                }
                            }
                        }
                        MouseEventKind::Up(MouseButton::Left) => {
                            app.dragging_border = false;
                        }
                        MouseEventKind::ScrollUp => {
                            if rect_contains(app.pane_rects.claude_pane, col, row) {
                                if let Some(ref mut t) = app.terminal {
                                    // X10 mouse protocol: \x1b[M + (button|64+32) + (col+33) + (row+33)
                                    // Button 64 = scroll up, +32 for encoding
                                    let lc = col.saturating_sub(app.pane_rects.claude_pane.x + 1);
                                    let lr = row.saturating_sub(app.pane_rects.claude_pane.y + 1);
                                    let seq = [
                                        0x1b, b'[', b'M',
                                        96,
                                        (lc + 33).min(255) as u8,
                                        (lr + 33).min(255) as u8,
                                    ];
                                    let _ = t.write(&seq);
                                }
                            } else if rect_contains(app.pane_rects.notifications, col, row) {
                                app.notification_scroll =
                                    app.notification_scroll.saturating_sub(1);
                            }
                        }
                        MouseEventKind::ScrollDown => {
                            if rect_contains(app.pane_rects.claude_pane, col, row) {
                                if let Some(ref mut t) = app.terminal {
                                    let lc = col.saturating_sub(app.pane_rects.claude_pane.x + 1);
                                    let lr = row.saturating_sub(app.pane_rects.claude_pane.y + 1);
                                    let seq = [
                                        0x1b, b'[', b'M',
                                        97,
                                        (lc + 33).min(255) as u8,
                                        (lr + 33).min(255) as u8,
                                    ];
                                    let _ = t.write(&seq);
                                }
                            } else if rect_contains(app.pane_rects.notifications, col, row) {
                                let max = app.notifications.len().saturating_sub(1) as u16;
                                if app.notification_scroll < max {
                                    app.notification_scroll += 1;
                                }
                            }
                        }
                        _ => {}
                    }
                }
                Event::Resize(_, _) => {
                    // Resize the PTY to match new pane dimensions
                    if let Some(ref t) = app.terminal {
                        let pane = app.pane_rects.claude_pane;
                        if pane.width > 2 && pane.height > 2 {
                            t.resize(pane.width - 2, pane.height - 2);
                        }
                    }
                }
                _ => {}
            }
        }

        if app.should_quit {
            break;
        }
    }

    app.close_terminal();
    server::close_mux(&app.config);

    stdout().execute(DisableMouseCapture)?;
    disable_raw_mode()?;
    stdout().execute(LeaveAlternateScreen)?;
    Ok(())
}

fn rect_contains(rect: Rect, col: u16, row: u16) -> bool {
    col >= rect.x && col < rect.x + rect.width && row >= rect.y && row < rect.y + rect.height
}

fn key_to_bytes(code: KeyCode, modifiers: KeyModifiers) -> Vec<u8> {
    match code {
        KeyCode::Char(c) => {
            if modifiers.contains(KeyModifiers::CONTROL) {
                let lower = c.to_ascii_lowercase();
                if lower.is_ascii_lowercase() {
                    vec![(lower as u8) - b'a' + 1]
                } else {
                    vec![]
                }
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
