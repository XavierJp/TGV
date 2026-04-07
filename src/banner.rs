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
    eprintln!();
    for (i, line) in BANNER.iter().enumerate() {
        let (r, g, b) = GRADIENT[i];
        eprintln!("  \x1b[38;2;{r};{g};{b}m{line}\x1b[0m");
    }
    eprintln!();
    let (r, g, b) = GRADIENT[3];
    eprintln!("  \x1b[3;38;2;{r};{g};{b}m        Terminal à Grande Vitesse\x1b[0m");
    eprintln!();
}
