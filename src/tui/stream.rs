//! Streaming markdown, rendered without ever re-printing.
//!
//! The idea is borrowed from grok-build's incremental renderer: find
//! **checkpoints** — points where no amount of appended text can change what
//! came before — freeze everything up to the last one, and re-render only the
//! tail.
//!
//! For leve that is not merely an optimisation, it is what makes streaming
//! possible at all. Finished transcript goes into the terminal's own scrollback
//! with `insert_before`, and printed lines cannot be taken back. So a line may
//! only be printed once it is known to be final. Without checkpoints the choice
//! would be re-flowing the whole message on every token (which `insert_before`
//! cannot do) or buffering the entire reply and showing nothing until it ends.
//!
//! Being wrong in one direction is cheap and in the other is a bug: freezing
//! **too little** just means a longer live tail, while freezing too much means
//! printing a line that later needed to change. So the rule is deliberately
//! conservative.
//!
//! The rule: a blank line that is not inside a fenced code block ends a
//! top-level block. Everything up to it is final.
//!
//! Two things make that safe here that would not be safe for a full CommonMark
//! renderer:
//!
//! * The renderer is line-based, so a later line never restyles an earlier one.
//!   A loose list (`- a`, blank, `- b`) is one list to CommonMark, but two
//!   independently rendered bullets here, so freezing after the blank is fine.
//! * Setext headings (`text` then `===`, where a later line changes the line
//!   above) are not supported, so that hazard does not exist.

use ratatui::text::Line;

use super::markdown;

/// How many lines of in-progress text to show. A tail is normally a sentence
/// or two; the cap stops a pathological unbroken block from taking the screen.
pub const TAIL_MAX: usize = 6;

#[derive(Debug, Default)]
pub struct Stream {
    /// Everything received.
    source: String,
    /// Byte offset of the end of the frozen prefix.
    frozen: usize,
    /// Frozen source not yet handed to the caller.
    pending: String,
}

impl Stream {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.source.is_empty()
    }

    /// The whole message so far, for the durable record.
    pub fn text(&self) -> &str {
        &self.source
    }

    /// Take a chunk. Anything that becomes final moves to the pending queue.
    pub fn push(&mut self, delta: &str) {
        self.source.push_str(delta);
        self.advance();
    }

    /// The stream ended: everything is final.
    pub fn finish(&mut self) {
        self.pending.push_str(&self.source[self.frozen..]);
        self.frozen = self.source.len();
    }

    fn advance(&mut self) {
        let Some(boundary) = last_checkpoint(&self.source) else {
            return;
        };
        if boundary > self.frozen {
            self.pending.push_str(&self.source[self.frozen..boundary]);
            self.frozen = boundary;
        }
    }

    /// Newly-final markdown, ready to be printed once and never redrawn.
    ///
    /// Returns the source rather than lines, because the caller knows the width
    /// and whether this is the first chunk (which needs the `◆` glyph).
    pub fn take_frozen(&mut self) -> Option<String> {
        let text = std::mem::take(&mut self.pending);
        (!text.trim().is_empty()).then_some(text)
    }

    /// The part still in flight, to be drawn in the live region.
    pub fn tail(&self, width: usize) -> Vec<Line<'static>> {
        // A trailing newline is a separator, not content: rendering it would
        // put a blank line between the text and the input box.
        let tail = self.source[self.frozen..]
            .trim_start_matches('\n')
            .trim_end_matches('\n');
        if tail.is_empty() {
            return Vec::new();
        }
        let mut lines = markdown::render(tail, width, "  ");
        // Keep the newest text: an over-long block scrolls its own head away
        // rather than pushing the input line around.
        if lines.len() > TAIL_MAX {
            lines.drain(..lines.len() - TAIL_MAX);
        }
        lines
    }
}

/// Byte offset just past the last point where the text is settled.
///
/// Scans lines, tracking fenced code blocks, and returns the offset after the
/// last blank line that sits outside a fence.
fn last_checkpoint(text: &str) -> Option<usize> {
    let mut offset = 0;
    let mut in_fence = false;
    let mut checkpoint = None;

    for line in text.split_inclusive('\n') {
        let trimmed = line.trim();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_fence = !in_fence;
        } else if trimmed.is_empty() && !in_fence {
            // Only a *completed* blank line settles the block above it; a
            // final "\n" with no text after could still be mid-token.
            if line.ends_with('\n') {
                checkpoint = Some(offset + line.len());
            }
        }
        offset += line.len();
    }
    checkpoint
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
    fn nothing_freezes_until_a_block_is_complete() {
        let mut s = Stream::new();
        s.push("The durable layer holds up");
        assert!(
            s.take_frozen().is_none(),
            "a paragraph in progress is not final"
        );
        assert!(!s.tail(60).is_empty(), "but it is visible while it streams");
    }

    #[test]
    fn a_finished_paragraph_freezes_and_leaves_the_tail_behind() {
        let mut s = Stream::new();
        s.push("First paragraph.\n\nSecond para");
        let frozen = s.take_frozen().expect("the first paragraph is settled");
        assert!(frozen.contains("First paragraph."), "{frozen:?}");
        assert!(
            !frozen.contains("Second"),
            "the in-flight block stays out: {frozen:?}"
        );
        assert_eq!(plain(&s.tail(60)), vec!["  Second para".to_string()]);
    }

    #[test]
    fn frozen_text_is_handed_over_exactly_once() {
        let mut s = Stream::new();
        s.push("Done.\n\nmore");
        assert!(s.take_frozen().is_some());
        assert!(
            s.take_frozen().is_none(),
            "printing twice would duplicate it"
        );
    }

    #[test]
    fn a_fence_holds_the_boundary_until_it_closes() {
        let mut s = Stream::new();
        s.push("```rust\nfn a() {}\n\nfn b() {}\n");
        assert!(
            s.take_frozen().is_none(),
            "a blank line inside code is not a block boundary"
        );
        s.push("```\n\n");
        let frozen = s.take_frozen().expect("closing the fence settles it");
        assert!(frozen.contains("fn b()"), "{frozen:?}");
    }

    #[test]
    fn finishing_settles_whatever_is_left() {
        let mut s = Stream::new();
        s.push("A trailing sentence with no blank line after it");
        assert!(s.take_frozen().is_none());
        s.finish();
        let frozen = s
            .take_frozen()
            .expect("the end of the stream is a boundary");
        assert!(frozen.contains("trailing sentence"), "{frozen:?}");
        assert!(s.tail(60).is_empty(), "and nothing is left in flight");
    }

    /// The property that matters: however the text is chopped up, the frozen
    /// output plus the tail is exactly the message, and every byte is emitted
    /// once.
    #[test]
    fn any_chunking_produces_the_same_message() {
        let message =
            "# Findings\n\nIt holds up.\n\n- one\n- two\n\n```rust\nfn f() {}\n```\n\nDone.";
        for chunk in [1usize, 3, 7, 50] {
            let mut s = Stream::new();
            let mut frozen = String::new();
            let bytes: Vec<char> = message.chars().collect();
            for piece in bytes.chunks(chunk) {
                s.push(&piece.iter().collect::<String>());
                if let Some(text) = s.take_frozen() {
                    frozen.push_str(&text);
                }
            }
            s.finish();
            if let Some(text) = s.take_frozen() {
                frozen.push_str(&text);
            }
            assert_eq!(
                frozen, message,
                "chunk size {chunk} lost or duplicated text"
            );
        }
    }

    #[test]
    fn the_tail_never_grows_past_its_cap() {
        let mut s = Stream::new();
        for i in 0..40 {
            s.push(&format!(
                "line {i} of an unbroken block that keeps going and going\n"
            ));
        }
        assert!(
            s.tail(60).len() <= TAIL_MAX,
            "the input line must not be pushed around"
        );
    }

    #[test]
    fn the_tail_shows_the_newest_text_not_the_oldest() {
        let mut s = Stream::new();
        for i in 0..20 {
            s.push(&format!("line {i}\n"));
        }
        let tail = plain(&s.tail(60));
        assert!(tail.last().unwrap().contains("line 19"), "{tail:?}");
        assert!(!tail.iter().any(|l| l.contains("line 0")), "{tail:?}");
    }

    #[test]
    fn the_full_text_is_always_available_for_the_record() {
        let mut s = Stream::new();
        s.push("half ");
        s.push("a message");
        assert_eq!(
            s.text(),
            "half a message",
            "the durable entry gets all of it"
        );
    }
}
