//! ASCII banner with gradient colors

/// Gradient: purple #833AB4 → red #FD1D1D → orange #FCB045
pub const GRADIENT: [(u8, u8, u8); 7] = [
    (0x83, 0x3A, 0xB4), // purple
    (0x9C, 0x2E, 0x9E),
    (0xB5, 0x23, 0x88),
    (0xD0, 0x1A, 0x5E),
    (0xE9, 0x1D, 0x3A),
    (0xF4, 0x6A, 0x28),
    (0xFC, 0xB0, 0x45), // orange
];

const BANNER_LARGE: [&str; 7] = [
    "░▒▓████████▓▒░  ░▒▓██████▓▒░  ░▒▓█▓▒░░▒▓█▓▒░",
    "   ░▒▓█▓▒░     ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░",
    "   ░▒▓█▓▒░     ░▒▓█▓▒░         ░▒▓█▓▒▒▓█▓▒░  ",
    "   ░▒▓█▓▒░     ░▒▓█▓▒▒▓███▓▒░  ░▒▓█▓▒▒▓█▓▒░  ",
    "   ░▒▓█▓▒░     ░▒▓█▓▒░░▒▓█▓▒░   ░▒▓█▓▓█▓▒░   ",
    "   ░▒▓█▓▒░     ░▒▓█▓▒░░▒▓█▓▒░   ░▒▓█▓▓█▓▒░   ",
    "   ░▒▓█▓▒░      ░▒▓██████▓▒░     ░▒▓██▓▒░    ",
];

const BANNER_SMALL: [&str; 4] = [
    "▀█▀  █▀▀  █ █",
    " █   █ █▌ ▀▄▀",
    " ▀   ▀▀▀   ▀ ",
    "Terminal à Grande Vitesse",
];

/// Print the gradient-colored banner to terminal (for `tgv init`)
pub fn print_banner() {
    println!();
    for (i, line) in BANNER_LARGE.iter().enumerate() {
        let (r, g, b) = GRADIENT[i];
        println!("  \x1b[38;2;{r};{g};{b}m{line}\x1b[0m");
    }
    let (r, g, b) = GRADIENT[3];
    println!();
    println!("  \x1b[3;38;2;{r};{g};{b}m        Terminal à Grande Vitesse\x1b[0m");
    println!();
}

/// Small banner for the TUI top panel (3-line logo + subtitle)
pub fn banner_lines() -> Vec<ratatui::text::Line<'static>> {
    use ratatui::style::{Color, Modifier, Style};
    use ratatui::text::{Line, Span};

    let picks = [GRADIENT[0], GRADIENT[3], GRADIENT[6]];

    let mut lines = Vec::new();
    for (i, text) in BANNER_SMALL[..3].iter().enumerate() {
        let (r, g, b) = picks[i];
        lines.push(Line::from(Span::styled(
            *text,
            Style::default()
                .fg(Color::Rgb(r, g, b))
                .add_modifier(Modifier::BOLD),
        )));
    }
    let (r, g, b) = GRADIENT[3];
    lines.push(Line::from(Span::styled(
        BANNER_SMALL[3],
        Style::default()
            .fg(Color::Rgb(r, g, b))
            .add_modifier(Modifier::ITALIC),
    )));
    lines
}
