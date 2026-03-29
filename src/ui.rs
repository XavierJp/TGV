//! UI rendering — lazygit-style split pane layout
//!
//! Left column: banner + network + sessions + notifications
//! Right pane: Claude Code terminal (full height)

use crate::app::{App, Focus, InputMode, NetStatus};

use ratatui::prelude::*;
use ratatui::widgets::{
    Block, BorderType, Borders, Clear, List, ListItem, Paragraph, Scrollbar,
    ScrollbarOrientation, ScrollbarState, Wrap,
};
use tui_term::widget::PseudoTerminal;

pub fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();

    let outer = Layout::vertical([
        Constraint::Min(1),
        Constraint::Length(1),
    ])
    .split(area);

    draw_statusline(frame, outer[1], app);
    app.pane_rects.main_area = outer[0];

    if app.has_terminals() {
        let panes = Layout::horizontal([
            Constraint::Percentage(app.left_pane_percent),
            Constraint::Percentage(100 - app.left_pane_percent),
        ])
        .split(outer[0]);

        draw_left_column(frame, panes[0], app);
        draw_claude_pane(frame, panes[1], app);
    } else {
        app.pane_rects.claude_pane = Rect::default();
        draw_left_column(frame, outer[0], app);
    }

    match &app.input_mode {
        InputMode::BranchInput(buf) => draw_branch_input(frame, area, buf),
        InputMode::ConfirmKill(name) => draw_confirm_kill(frame, area, app, name),
        InputMode::None => {}
    }
}

fn draw_left_column(frame: &mut Frame, area: Rect, app: &mut App) {
    let sections = Layout::vertical([
        Constraint::Length(6),
        Constraint::Length(3),
        Constraint::Min(4),
        Constraint::Length(7),
    ])
    .split(area);

    draw_banner(frame, sections[0]);
    draw_network(frame, sections[1], app);
    draw_session_list(frame, sections[2], app);
    draw_notifications(frame, sections[3], app);
}

fn draw_banner(frame: &mut Frame, area: Rect) {
    use crate::banner;
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

fn draw_network(frame: &mut Frame, area: Rect, app: &App) {
    let net = &app.network;

    let color = match net.status {
        NetStatus::Good => Color::Green,
        NetStatus::Poor => Color::Yellow,
        NetStatus::Dead => Color::Red,
        NetStatus::Unknown => Color::DarkGray,
    };

    let mut spans = vec![
        Span::styled(net.status.icon(), Style::default().fg(color)),
        Span::raw(" "),
        Span::styled(net.status.label(), Style::default().fg(color)),
    ];

    if let Some(avg) = net.avg_ms {
        spans.push(Span::styled(
            format!("  {avg}ms"),
            Style::default().fg(Color::DarkGray),
        ));
    }

    if let Some(jitter) = net.jitter_ms {
        spans.push(Span::styled(
            format!("  ±{jitter}ms"),
            Style::default().fg(Color::DarkGray),
        ));
    }

    if net.loss_pct > 0 {
        let loss_color = if net.loss_pct >= 50 { Color::Red } else { Color::Yellow };
        spans.push(Span::styled(
            format!("  {}% loss", net.loss_pct),
            Style::default().fg(loss_color),
        ));
    }

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(" Network ")
        .border_style(Style::default().fg(Color::DarkGray));
    frame.render_widget(Paragraph::new(Line::from(spans)).block(block), area);
}

fn draw_statusline(frame: &mut Frame, area: Rect, app: &App) {
    let width = area.width as usize;

    let left = match app.focus {
        Focus::Terminal => "ESC : back to sessions".to_string(),
        Focus::SessionList if app.has_terminals() => {
            "New : n | Kill : k | Switch : ↵ | Quit : q".to_string()
        }
        Focus::SessionList => "New : n | Kill : k | Open : ↵ | Quit : q".to_string(),
    };

    let repo_name = app
        .config
        .repo
        .url
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .replace(".git", "");
    let right = format!("{} • {}", app.config.ssh_target(), repo_name);

    let left_chars = left.chars().count();
    let right_chars = right.chars().count();
    let padding = if width > left_chars + right_chars + 2 {
        width - left_chars - right_chars - 2
    } else {
        1
    };

    let line = Line::from(vec![
        Span::raw(" "),
        Span::styled(left, Style::default().fg(Color::DarkGray)),
        Span::raw(" ".repeat(padding)),
        Span::styled(right, Style::default().fg(Color::DarkGray)),
    ]);
    frame.render_widget(Paragraph::new(line), area);
}

fn draw_session_list(frame: &mut Frame, area: Rect, app: &mut App) {
    app.pane_rects.session_list = area;
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
            let is_attached = s.name == app.attached_session;

            let fg = if is_selected {
                Color::Black
            } else if is_attached {
                Color::Cyan
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

            let metrics = {
                let mut parts = Vec::new();
                if let Some(n) = s.insertions {
                    parts.push(format!("+{n}"));
                }
                if let Some(n) = s.deletions {
                    parts.push(format!("-{n}"));
                }
                if parts.is_empty() {
                    String::new()
                } else {
                    format!("  {}", parts.join(" "))
                }
            };

            let attach_marker = if is_attached { " ◀" } else { "" };

            let text = if app.has_terminals() {
                format!(" {icon} {}{attach_marker}", s.branch)
            } else {
                format!(" {icon}  {} · {}{metrics}", s.branch, s.name)
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

/// Claude Code pane (full right column)
fn draw_claude_pane(frame: &mut Frame, area: Rect, app: &mut App) {
    app.pane_rects.claude_pane = area;
    let is_focused = app.focus == Focus::Terminal;

    let border_style = if app.dragging_border {
        Style::default().fg(Color::Yellow)
    } else if is_focused {
        Style::default().fg(Color::Blue)
    } else {
        Style::default().fg(Color::DarkGray)
    };

    let title = format!(" Claude Code — {} ", app.attached_session);

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
    } else {
        frame.render_widget(Paragraph::new("Connecting...").block(block), area);
    }
}

fn draw_notifications(frame: &mut Frame, area: Rect, app: &mut App) {
    app.pane_rects.notifications = area;

    let inner_height = area.height.saturating_sub(2) as usize;
    let total = app.notifications.len();
    let can_scroll = total > inner_height;

    let scroll_offset = app
        .notification_scroll
        .saturating_sub(inner_height.saturating_sub(1) as u16);

    let title = if can_scroll {
        let at_top = scroll_offset == 0;
        let max_scroll = total.saturating_sub(inner_height);
        let at_bottom = scroll_offset as usize >= max_scroll;
        match (at_top, at_bottom) {
            (true, _) => " Logs ↓ ".to_string(),
            (_, true) => " Logs ↑ ".to_string(),
            _ => " Logs ↑↓ ".to_string(),
        }
    } else {
        " Logs ".to_string()
    };

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(title)
        .border_style(Style::default().fg(Color::DarkGray));

    let lines: Vec<Line> = app
        .notifications
        .iter()
        .enumerate()
        .map(|(i, msg)| {
            let style = if i == total - 1 {
                Style::default().fg(Color::White)
            } else {
                Style::default().fg(Color::DarkGray)
            };
            Line::styled(msg.as_str(), style)
        })
        .collect();

    let paragraph = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: false })
        .scroll((scroll_offset, 0));
    frame.render_widget(paragraph, area);

    if can_scroll {
        let max_scroll = total.saturating_sub(inner_height);
        let mut scrollbar_state =
            ScrollbarState::new(max_scroll).position(scroll_offset as usize);
        let scrollbar = Scrollbar::new(ScrollbarOrientation::VerticalRight)
            .begin_symbol(Some("▲"))
            .end_symbol(Some("▼"))
            .track_symbol(Some("░"))
            .thumb_symbol("█")
            .track_style(Style::default().fg(Color::DarkGray))
            .thumb_style(Style::default().fg(Color::Gray));
        let scrollbar_area = Rect {
            x: area.x,
            y: area.y + 1,
            width: area.width,
            height: area.height.saturating_sub(2),
        };
        frame.render_stateful_widget(scrollbar, scrollbar_area, &mut scrollbar_state);
    }
}

fn draw_branch_input(frame: &mut Frame, area: Rect, buf: &str) {
    let width = 50u16.min(area.width.saturating_sub(4));
    let popup = Rect {
        x: area.x + (area.width.saturating_sub(width)) / 2,
        y: area.y + area.height / 3,
        width,
        height: 3,
    };
    frame.render_widget(Clear, popup);

    let display = if buf.is_empty() {
        Span::styled("empty = tgv/<random>", Style::default().fg(Color::DarkGray))
    } else {
        Span::styled(format!("{buf}▌"), Style::default().fg(Color::White))
    };

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(" New session — branch name ")
        .border_style(Style::default().fg(Color::Blue));
    let paragraph = Paragraph::new(Line::from(vec![Span::raw(" "), display])).block(block);
    frame.render_widget(paragraph, popup);
}

fn draw_confirm_kill(frame: &mut Frame, area: Rect, app: &App, name: &str) {
    let session = app.sessions.iter().find(|s| s.name == name);
    let ins = session.and_then(|s| s.insertions).unwrap_or(0);
    let del = session.and_then(|s| s.deletions).unwrap_or(0);

    let detail_line = if ins > 0 || del > 0 {
        Line::from(vec![
            Span::styled("  Uncommitted: ", Style::default().fg(Color::White)),
            Span::styled(format!("+{ins}"), Style::default().fg(Color::Green)),
            Span::styled(" ", Style::default()),
            Span::styled(format!("-{del}"), Style::default().fg(Color::Red)),
        ])
    } else {
        Line::from(Span::styled(
            "  This will destroy the container and its data.",
            Style::default().fg(Color::DarkGray),
        ))
    };

    let width = 55u16.min(area.width.saturating_sub(4));
    let popup = Rect {
        x: area.x + (area.width.saturating_sub(width)) / 2,
        y: area.y + area.height / 3,
        width,
        height: 6,
    };
    frame.render_widget(Clear, popup);

    let lines = vec![
        Line::from(""),
        Line::from(vec![
            Span::styled("  Kill session ", Style::default().fg(Color::White)),
            Span::styled(name, Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)),
            Span::styled("?", Style::default().fg(Color::White)),
        ]),
        detail_line,
        Line::from(""),
        Line::from(vec![
            Span::styled("  ", Style::default()),
            Span::styled("y", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
            Span::styled(" confirm  ", Style::default().fg(Color::DarkGray)),
            Span::styled("n", Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)),
            Span::styled(" cancel", Style::default().fg(Color::DarkGray)),
        ]),
    ];

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(" Confirm ")
        .border_style(Style::default().fg(Color::Red));
    let paragraph = Paragraph::new(lines).block(block);
    frame.render_widget(paragraph, popup);
}
