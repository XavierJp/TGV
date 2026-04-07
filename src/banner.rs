//! ASCII banner with gradient colors

pub const GRADIENT: [(u8, u8, u8); 6] = [
    (0x83, 0x3A, 0xB4),
    (0x9C, 0x2E, 0x9E),
    (0xB5, 0x23, 0x88),
    (0xD0, 0x1A, 0x5E),
    (0xE9, 0x1D, 0x3A),
    (0xF4, 0x6A, 0x28),
];

const BANNER: [&str; 6] = [
    "████████╗ ██████╗ ██╗   ██╗",
    "╚══██╔══╝██╔════╝ ██║   ██║",
    "   ██║   ██║  ███╗██║   ██║",
    "   ██║   ██║   ██║╚██╗ ██╔╝",
    "   ██║   ╚██████╔╝ ╚████╔╝ ",
    "   ╚═╝    ╚═════╝   ╚═══╝  ",
];

pub fn print_banner() {
    let term_width = console::Term::stderr()
        .size()
        .1 as usize;
    let banner_width = BANNER[0].chars().count();
    let banner_pad = term_width.saturating_sub(banner_width) / 2;

    let subtitle = "Terminal à Grande Vitesse";
    let subtitle_pad = term_width.saturating_sub(subtitle.chars().count()) / 2;

    eprintln!();
    for (i, line) in BANNER.iter().enumerate() {
        let (r, g, b) = GRADIENT[i];
        eprintln!("{:pad$}\x1b[38;2;{r};{g};{b}m{line}\x1b[0m", "", pad = banner_pad);
    }
    eprintln!();
    let (r, g, b) = GRADIENT[3];
    eprintln!("{:pad$}\x1b[3;38;2;{r};{g};{b}m{subtitle}\x1b[0m", "", pad = subtitle_pad);
    eprintln!();
}
