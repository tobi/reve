//! Light markdown, for a transcript rather than a document.
//!
//! Deliberately small. A model's reply is read once, in a narrow column, next
//! to tool output — so what earns its place is: emphasis, inline code, fenced
//! code, bullets, numbered lists, headings, and block quotes. Tables, images,
//! footnotes and reference links do not survive the width and are left as
//! their source text rather than mangled.
//!
//! Everything wraps to the available width with a hanging indent, so a wrapped
//! bullet still reads as one bullet.

use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use unicode_width::UnicodeWidthStr;

use super::theme;

/// Render markdown into wrapped lines.
///
/// `width` is the usable column count; `indent` is prepended to every line,
/// including wraps.
pub fn render(source: &str, width: usize, indent: &str) -> Vec<Line<'static>> {
    let width = width.max(8);
    let mut out = Vec::new();
    let mut fenced: Option<Vec<String>> = None;

    for raw in source.split('\n') {
        let line = raw.trim_end();

        // Fenced code: kept verbatim, never wrapped — wrapping code is worse
        // than letting it be clipped, because the reader may want to copy it.
        if line.trim_start().starts_with("```") {
            match fenced.take() {
                Some(body) => out.extend(code_block(&body, indent)),
                None => fenced = Some(Vec::new()),
            }
            continue;
        }
        if let Some(body) = fenced.as_mut() {
            body.push(line.to_string());
            continue;
        }

        if line.trim().is_empty() {
            out.push(Line::from(""));
            continue;
        }

        let trimmed = line.trim_start();

        // Headings read as bold; a transcript has no room for a hierarchy of
        // sizes and `###` in the output is noise.
        if let Some(rest) = heading(trimmed) {
            out.extend(wrap(&inline(rest, theme::bold()), width, indent, indent));
            continue;
        }

        if let Some(rest) = trimmed.strip_prefix("> ") {
            let mut spans = vec![Span::styled("│ ", theme::faint())];
            spans.extend(inline(rest, theme::dim()));
            out.extend(wrap(&spans, width, indent, &format!("{indent}  ")));
            continue;
        }

        if let Some((marker, rest)) = bullet(trimmed) {
            let pad = " ".repeat(marker.width());
            let mut spans = vec![Span::styled(marker, theme::faint())];
            spans.extend(inline(rest, theme::fg()));
            out.extend(wrap(&spans, width, indent, &format!("{indent}{pad}")));
            continue;
        }

        out.extend(wrap(&inline(trimmed, theme::fg()), width, indent, indent));
    }

    // An unterminated fence still renders; a truncated stream is normal.
    if let Some(body) = fenced {
        out.extend(code_block(&body, indent));
    }
    out
}

fn heading(line: &str) -> Option<&str> {
    let hashes = line.len() - line.trim_start_matches('#').len();
    (1..=6)
        .contains(&hashes)
        .then(|| line[hashes..].trim_start())
}

/// `- x`, `* x`, `• x`, or `1. x` → the marker we will draw, and the content.
fn bullet(line: &str) -> Option<(String, &str)> {
    for prefix in ["- ", "* ", "• ", "+ "] {
        if let Some(rest) = line.strip_prefix(prefix) {
            return Some(("• ".to_string(), rest));
        }
    }
    let digits: String = line.chars().take_while(char::is_ascii_digit).collect();
    if !digits.is_empty() {
        let rest = &line[digits.len()..];
        if let Some(rest) = rest.strip_prefix(". ") {
            return Some((format!("{digits}. "), rest));
        }
    }
    None
}

fn code_block(body: &[String], indent: &str) -> Vec<Line<'static>> {
    body.iter()
        .map(|line| {
            Line::from(vec![
                Span::styled(format!("{indent}│ "), theme::faint()),
                Span::styled(line.clone(), theme::code()),
            ])
        })
        .collect()
}

/// Inline emphasis: `code`, **bold**, *italic*.
///
/// A single pass, because nesting emphasis inside code (or vice versa) is not
/// something a terminal transcript needs to get right.
pub fn inline(text: &str, base: Style) -> Vec<Span<'static>> {
    let mut spans = Vec::new();
    let mut buffer = String::new();
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;

    let flush = |buffer: &mut String, spans: &mut Vec<Span<'static>>| {
        if !buffer.is_empty() {
            spans.push(Span::styled(std::mem::take(buffer), base));
        }
    };

    while i < chars.len() {
        let rest: String = chars[i..].iter().collect();
        if let Some(end) = delimited(&rest, "`") {
            flush(&mut buffer, &mut spans);
            spans.push(Span::styled(rest[1..end].to_string(), theme::code()));
            i += rest[..end + 1].chars().count();
        } else if let Some(end) = delimited(&rest, "**") {
            flush(&mut buffer, &mut spans);
            spans.push(Span::styled(
                rest[2..end].to_string(),
                base.add_modifier(Modifier::BOLD),
            ));
            i += rest[..end + 2].chars().count();
        } else if let Some(end) = delimited(&rest, "*") {
            flush(&mut buffer, &mut spans);
            spans.push(Span::styled(
                rest[1..end].to_string(),
                base.add_modifier(Modifier::ITALIC),
            ));
            i += rest[..end + 1].chars().count();
        } else {
            buffer.push(chars[i]);
            i += 1;
        }
    }
    flush(&mut buffer, &mut spans);
    if spans.is_empty() {
        spans.push(Span::styled(String::new(), base));
    }
    spans
}

/// Byte index of the closing `marker`, if this text opens with one and closes
/// it on the same line with something in between.
fn delimited(text: &str, marker: &str) -> Option<usize> {
    if !text.starts_with(marker) {
        return None;
    }
    let body = &text[marker.len()..];
    let end = body.find(marker)?;
    (end > 0).then_some(marker.len() + end)
}

/// Wrap styled spans, breaking on spaces and preserving style runs.
///
/// `width` is the **total** line width, indent included — the number of columns
/// the caller has. Getting this wrong is easy and silent, so it is stated here
/// and asserted in the tests.
pub fn wrap(
    spans: &[Span<'static>],
    width: usize,
    first_indent: &str,
    hanging_indent: &str,
) -> Vec<Line<'static>> {
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut current: Vec<Span<'static>> = Vec::new();
    if !first_indent.is_empty() {
        current.push(Span::raw(first_indent.to_string()));
    }
    let mut used = first_indent.width();
    let limit = width;

    for span in spans {
        for word in split_keeping_spaces(&span.content) {
            let w = word.width();
            let is_space = word.trim().is_empty();
            if used + w > limit {
                // A space at a break point is the break; it is never drawn.
                if is_space {
                    continue;
                }
                lines.push(Line::from(std::mem::take(&mut current)));
                if !hanging_indent.is_empty() {
                    current.push(Span::raw(hanging_indent.to_string()));
                }
                used = hanging_indent.width();
            }
            // Nor does a line ever open with one.
            if is_space && used == hanging_indent.width() && !lines.is_empty() {
                continue;
            }
            current.push(Span::styled(word.to_string(), span.style));
            used += w;
        }
    }
    if current.iter().any(|s| !s.content.trim().is_empty()) || lines.is_empty() {
        lines.push(Line::from(current));
    }
    lines
}

/// Split into words and the runs of spaces between them, so wrapping can drop
/// a break-point space without eating the ones inside a line.
fn split_keeping_spaces(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut in_space = None;
    for (i, ch) in text.char_indices() {
        let space = ch == ' ';
        match in_space {
            None => in_space = Some(space),
            Some(previous) if previous != space => {
                out.push(&text[start..i]);
                start = i;
                in_space = Some(space);
            }
            _ => {}
        }
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(lines: &[Line<'_>]) -> Vec<String> {
        lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect()
    }

    #[test]
    fn paragraphs_wrap_with_a_hanging_indent() {
        let text = "the quick brown fox jumps over the lazy dog and keeps running";
        let lines = render(text, 24, "  ");
        let rendered = plain(&lines);
        assert!(rendered.len() > 1, "it wrapped: {rendered:?}");
        for line in &rendered {
            assert!(line.starts_with("  "), "every line is indented: {line:?}");
            assert!(line.width() <= 24, "and fits: {line:?} ({})", line.width());
        }
        let joined = rendered.join("").replace("  ", " ");
        assert!(
            joined.contains("quick brown fox"),
            "no words were lost: {joined:?}"
        );
    }

    #[test]
    fn bullets_keep_their_marker_and_align_wraps_under_the_text() {
        let lines = render("- alpha beta gamma delta epsilon zeta", 20, "");
        let rendered = plain(&lines);
        assert!(rendered[0].starts_with("• "), "{rendered:?}");
        assert!(rendered.len() > 1, "{rendered:?}");
        assert!(
            rendered[1].starts_with("  "),
            "wrap aligns under the text: {rendered:?}"
        );
        assert!(
            !rendered[1].starts_with("• "),
            "and does not repeat the bullet"
        );
    }

    #[test]
    fn numbered_lists_keep_their_number() {
        let rendered = plain(&render("1. first\n2. second", 40, ""));
        assert_eq!(
            rendered,
            vec!["1. first".to_string(), "2. second".to_string()]
        );
    }

    #[test]
    fn inline_code_is_styled_and_the_backticks_are_gone() {
        let spans = inline("run `cargo test` now", theme::fg());
        let text: String = spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(text, "run cargo test now");
        let coded = spans
            .iter()
            .find(|s| s.content == "cargo test")
            .expect("a code span");
        assert_eq!(coded.style.fg, Some(theme::CODE));
    }

    #[test]
    fn bold_and_italic_are_distinguished() {
        let spans = inline("**hard** and *soft*", theme::fg());
        let hard = spans.iter().find(|s| s.content == "hard").unwrap();
        let soft = spans.iter().find(|s| s.content == "soft").unwrap();
        assert!(hard.style.add_modifier.contains(Modifier::BOLD));
        assert!(soft.style.add_modifier.contains(Modifier::ITALIC));
    }

    #[test]
    fn an_unmatched_marker_is_left_alone() {
        let spans = inline("2 * 3 and a `dangling", theme::fg());
        let text: String = spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(text, "2 * 3 and a `dangling", "no characters are eaten");
    }

    #[test]
    fn fenced_code_is_verbatim_and_never_wrapped() {
        let source = "before\n```\nlet x = a_very_long_identifier_that_would_wrap();\n```\nafter";
        let rendered = plain(&render(source, 20, ""));
        assert!(
            rendered
                .iter()
                .any(|l| l.contains("a_very_long_identifier_that_would_wrap")),
            "code is intact: {rendered:?}"
        );
        assert!(
            rendered.iter().any(|l| l.starts_with("│ ")),
            "and gutter-marked: {rendered:?}"
        );
    }

    #[test]
    fn an_unterminated_fence_still_renders() {
        let rendered = plain(&render("```\nstreaming and cut off", 40, ""));
        assert!(
            rendered.iter().any(|l| l.contains("streaming and cut off")),
            "{rendered:?}"
        );
    }

    #[test]
    fn headings_become_bold_without_their_hashes() {
        let lines = render("## Findings", 40, "");
        assert_eq!(plain(&lines), vec!["Findings".to_string()]);
        assert!(
            lines[0]
                .spans
                .iter()
                .any(|s| s.style.add_modifier.contains(Modifier::BOLD))
        );
    }

    #[test]
    fn block_quotes_are_gutter_marked_and_dimmed() {
        let lines = render("> quoted thought", 40, "");
        let rendered = plain(&lines);
        assert!(rendered[0].starts_with("│ "), "{rendered:?}");
        assert!(
            lines[0]
                .spans
                .iter()
                .any(|s| s.style.fg == Some(theme::DIM))
        );
    }

    #[test]
    fn blank_lines_survive_as_paragraph_breaks() {
        let rendered = plain(&render("one\n\ntwo", 40, ""));
        assert_eq!(
            rendered,
            vec!["one".to_string(), String::new(), "two".to_string()]
        );
    }

    #[test]
    fn a_very_long_unbreakable_token_does_not_hang_or_vanish() {
        let token = "x".repeat(60);
        let rendered = plain(&render(&token, 20, "  "));
        let joined: String = rendered.join("");
        assert!(
            joined.contains(&"x".repeat(20)),
            "it is still there: {rendered:?}"
        );
    }
}
