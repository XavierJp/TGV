//! UI rendering — lazygit-style split pane layout
//!
//! Left column: banner (top) + session list (middle) + status (bottom)
//! Right pane: embedded terminal (when open)

use crate::app::{App, Focus};
use crate::banner;

use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Clear, List, ListItem, Paragraph, Wrap};
use tui_term::widget::PseudoTerminal;

/// Main draw function — called every frame
pub fn draw(frame: &mut Frame, app: &App) {
    let area = frame.area();

    // Layout: main area + statusline (no background, like lazygit)
    let outer = Layout::vertical([
        Constraint::Min(1),    // main content
        Constraint::Length(1), // statusline
    ])
    .split(area);

    draw_statusline(frame, outer[1], app);

    if app.terminal.is_some() {
        let panes = Layout::horizontal([
            Constraint::Percentage(25),
            Constraint::Percentage(75),
        ])
        .split(outer[0]);

        draw_left_column(frame, panes[0], app);
        draw_terminal(frame, panes[1], app);
    } else {
        draw_left_column(frame, outer[0], app);
    }

    // Overlay: container log viewer
    if let Some(ref log_text) = app.show_logs {
        draw_log_overlay(frame, area, log_text);
    }
}

/// Left column: banner + sessions + status
fn draw_left_column(frame: &mut Frame, area: Rect, app: &App) {
    let sections = Layout::vertical([
        Constraint::Length(6), // banner (3-line logo + subtitle + border)
        Constraint::Min(4),   // sessions
        Constraint::Length(5), // status
    ])
    .split(area);

    draw_banner(frame, sections[0]);
    draw_session_list(frame, sections[1], app);
    draw_status_panel(frame, sections[2], app);
}

/// Banner panel (full 7-line gradient logo)
fn draw_banner(frame: &mut Frame, area: Rect) {
    let lines = banner::banner_lines();
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(Color::DarkGray));

    let paragraph = Paragraph::new(lines)
        .block(block)
        .alignment(Alignment::Center);
    frame.render_widget(paragraph, area);
}

/// Statusline at the bottom — `Command : <key> | ...   user@host • repo`
fn draw_statusline(frame: &mut Frame, area: Rect, app: &App) {
    let width = area.width as usize;

    // Left side: commands
    let left = if app.terminal.is_some() {
        if app.focus == Focus::Terminal {
            "Sessions : ⇥ | Close : ESC".to_string()
        } else {
            "Switch : ↵ | Terminal : ⇥ | Close : ESC".to_string()
        }
    } else {
        "New : n | Kill : k | Attach : ↵ | Logs : l | Refresh : r | Quit : q".to_string()
    };

    // Right side: user@host • repo
    let repo_name = app.config.repo.url
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .replace(".git", "");
    let right = format!("{} • {}", app.config.ssh_target(), repo_name);

    // Pad middle with spaces to push right side to the edge
    let left_len = left.len();
    let right_len = right.len();
    let padding = if width > left_len + right_len + 2 {
        width - left_len - right_len - 2
    } else {
        1
    };

    let line = Line::from(vec![
        Span::styled(" ", Style::default()),
        Span::styled(left, Style::default().fg(Color::DarkGray)),
        Span::raw(" ".repeat(padding)),
        Span::styled(right, Style::default().fg(Color::DarkGray)),
    ]);

    frame.render_widget(Paragraph::new(line), area);
}

/// Session list panel
fn draw_session_list(frame: &mut Frame, area: Rect, app: &App) {
    let is_focused = app.focus == Focus::SessionList;

    let border_style = if is_focused {
        Style::default().fg(Color::Blue)
    } else {
        Style::default().fg(Color::DarkGray)
    };

    if app.sessions.is_empty() {
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .title(" Sessions ")
            .border_style(border_style);

        let paragraph = Paragraph::new(Span::styled(
            "  Press 'n' to create a session",
            Style::default().fg(Color::DarkGray),
        ))
        .block(block);
        frame.render_widget(paragraph, area);
        return;
    }

    let items: Vec<ListItem> = app
        .sessions
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let icon = if s.status == "running" { "●" } else { "○" };
            let is_selected = i == app.selected;

            let fg = if is_selected {
                Color::Black
            } else if s.status == "running" {
                Color::Green
            } else {
                Color::DarkGray
            };

            let bg = if is_selected {
                if is_focused { Color::Blue } else { Color::DarkGray }
            } else {
                Color::Reset
            };

            let text = if app.terminal.is_some() {
                format!(" {icon} {}", s.name)
            } else {
                format!(
                    " {icon}  {:<18} {:<22} {:<12} {}",
                    s.name, s.repo, s.branch, s.status
                )
            };

            ListItem::new(Line::styled(text, Style::default().fg(fg)))
                .style(Style::default().bg(bg))
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .title(" Sessions ")
            .border_style(border_style),
    );

    frame.render_widget(list, area);
}

/// Status panel — shows status messages
fn draw_status_panel(frame: &mut Frame, area: Rect, app: &App) {
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(" Status ")
        .border_style(Style::default().fg(Color::DarkGray));

    let paragraph = Paragraph::new(app.status.as_str())
        .block(block)
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, area);
}

/// Embedded terminal pane (right side)
fn draw_terminal(frame: &mut Frame, area: Rect, app: &App) {
    let is_focused = app.focus == Focus::Terminal;

    let border_style = if is_focused {
        Style::default().fg(Color::Blue)
    } else {
        Style::default().fg(Color::DarkGray)
    };

    let title = format!(" {} ", app.terminal_session_name);

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(title)
        .border_style(border_style);

    if let Some(ref term) = app.terminal {
        if let Ok(parser) = term.parser.lock() {
            let pseudo_term = PseudoTerminal::new(parser.screen()).block(block);
            frame.render_widget(pseudo_term, area);
        }
    }
}

/// Container log overlay (modal, triggered by 'l')
fn draw_log_overlay(frame: &mut Frame, area: Rect, log_text: &str) {
    let popup_area = centered_rect(80, 80, area);
    frame.render_widget(Clear, popup_area);

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(" Container Logs (press any key to close) ")
        .border_style(Style::default().fg(Color::Yellow));

    let paragraph = Paragraph::new(log_text)
        .block(block)
        .wrap(Wrap { trim: false });

    frame.render_widget(paragraph, popup_area);
}

/// Create a centered rectangle (percentage of parent)
fn centered_rect(percent_x: u16, percent_y: u16, area: Rect) -> Rect {
    let popup_layout = Layout::vertical([
        Constraint::Percentage((100 - percent_y) / 2),
        Constraint::Percentage(percent_y),
        Constraint::Percentage((100 - percent_y) / 2),
    ])
    .split(area);

    Layout::horizontal([
        Constraint::Percentage((100 - percent_x) / 2),
        Constraint::Percentage(percent_x),
        Constraint::Percentage((100 - percent_x) / 2),
    ])
    .split(popup_layout[1])[1]
}
