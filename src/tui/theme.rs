//! The palette.
//!
//! Truecolor, not the terminal's sixteen: the transcript leans on small
//! differences in weight and warmth to separate what the user said, what the
//! agent did, and what is merely metadata. Sixteen ANSI colours cannot hold
//! that apart, and they change meaning under the reader's theme.

use ratatui::style::{Color, Modifier, Style};

/// Primary text.
pub const FG: Color = Color::Rgb(0xcc, 0xd3, 0xdb);
/// Secondary text: hints, wrapped detail, things you read second.
pub const DIM: Color = Color::Rgb(0x8a, 0x90, 0x98);
/// Structure: rules, bullets, separators, timings.
pub const FAINT: Color = Color::Rgb(0x67, 0x6c, 0x74);
/// The user's voice, and the things they chose (model, description).
pub const ACCENT: Color = Color::Rgb(0x5a, 0xa0, 0xff);
/// Commands, and anything that went wrong.
pub const DANGER: Color = Color::Rgb(0xf3, 0x8b, 0xa8);
/// Work that started or finished well.
pub const GOOD: Color = Color::Rgb(0xa6, 0xe3, 0xa1);
/// Code, identifiers, names.
pub const CODE: Color = Color::Rgb(0x8a, 0xbe, 0xb7);
/// Something is waiting on you.
pub const ALERT: Color = Color::Rgb(0xdb, 0xbc, 0x7f);

/// The shimmer that runs through "Working", brightest to faintest.
pub const SHIMMER: [Color; 4] = [
    Color::Rgb(0xbd, 0xc4, 0xcc),
    Color::Rgb(0x9a, 0xa0, 0xa8),
    Color::Rgb(0x76, 0x7b, 0x83),
    Color::Rgb(0x67, 0x6c, 0x74),
];

pub fn fg() -> Style {
    Style::default().fg(FG)
}
pub fn dim() -> Style {
    Style::default().fg(DIM)
}
pub fn faint() -> Style {
    Style::default().fg(FAINT)
}
pub fn accent() -> Style {
    Style::default().fg(ACCENT)
}
pub fn danger() -> Style {
    Style::default().fg(DANGER)
}
pub fn good() -> Style {
    Style::default().fg(GOOD)
}
pub fn code() -> Style {
    Style::default().fg(CODE)
}
pub fn alert() -> Style {
    Style::default().fg(ALERT)
}
pub fn bold() -> Style {
    Style::default().fg(FG).add_modifier(Modifier::BOLD)
}
