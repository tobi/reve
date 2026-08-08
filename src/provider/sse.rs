//! Server-sent events, the transport both providers stream over.
//!
//! Small on purpose. The spec has more in it than either API uses, so this
//! handles what they actually send: `event:` and `data:` lines, comments,
//! multi-line data joined with newlines, and a blank line terminating an event.
//! Anything else is ignored rather than guessed at.

/// One decoded event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    /// The `event:` field. OpenAI names its events; Anthropic does too.
    pub name: Option<String>,
    /// The `data:` payload, newlines preserved.
    pub data: String,
}

/// Feeds bytes in, gets whole events out.
///
/// A chunk boundary can fall anywhere, including mid-line, so the decoder keeps
/// a buffer and only emits an event once its terminating blank line arrives.
#[derive(Debug, Default)]
pub struct Decoder {
    buffer: String,
    name: Option<String>,
    data: Vec<String>,
}

impl Decoder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Push a chunk; get back whatever events completed.
    pub fn push(&mut self, chunk: &str) -> Vec<Event> {
        self.buffer.push_str(chunk);
        let mut events = Vec::new();
        while let Some(index) = self.buffer.find('\n') {
            let line = self.buffer[..index].trim_end_matches('\r').to_string();
            self.buffer.drain(..=index);
            if let Some(event) = self.line(&line) {
                events.push(event);
            }
        }
        events
    }

    fn line(&mut self, line: &str) -> Option<Event> {
        if line.is_empty() {
            // Blank line: dispatch, unless there was nothing to dispatch.
            if self.data.is_empty() && self.name.is_none() {
                return None;
            }
            return Some(Event {
                name: self.name.take(),
                data: std::mem::take(&mut self.data).join("\n"),
            });
        }
        if line.starts_with(':') {
            return None; // comment, often a keep-alive
        }
        let (field, value) = match line.split_once(':') {
            Some((field, value)) => (field, value.strip_prefix(' ').unwrap_or(value)),
            None => (line, ""),
        };
        match field {
            "event" => self.name = Some(value.to_string()),
            "data" => self.data.push(value.to_string()),
            _ => {}
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all(chunks: &[&str]) -> Vec<Event> {
        let mut decoder = Decoder::new();
        chunks.iter().flat_map(|c| decoder.push(c)).collect()
    }

    #[test]
    fn an_event_needs_its_blank_line() {
        let mut decoder = Decoder::new();
        assert!(
            decoder.push("event: delta\ndata: {\"x\":1}\n").is_empty(),
            "not yet complete"
        );
        let events = decoder.push("\n");
        assert_eq!(
            events,
            vec![Event {
                name: Some("delta".into()),
                data: "{\"x\":1}".into()
            }]
        );
    }

    #[test]
    fn a_chunk_may_split_anywhere_including_mid_line() {
        let whole = "event: delta\ndata: {\"text\":\"hi\"}\n\nevent: done\ndata: {}\n\n";
        for size in [1usize, 3, 7, 40] {
            let chunks: Vec<String> = whole
                .as_bytes()
                .chunks(size)
                .map(|c| String::from_utf8_lossy(c).into_owned())
                .collect();
            let refs: Vec<&str> = chunks.iter().map(String::as_str).collect();
            let events = all(&refs);
            assert_eq!(events.len(), 2, "chunk size {size}: {events:?}");
            assert_eq!(events[0].name.as_deref(), Some("delta"));
            assert_eq!(events[1].data, "{}");
        }
    }

    #[test]
    fn multi_line_data_is_joined_with_newlines() {
        let events = all(&["data: one\ndata: two\n\n"]);
        assert_eq!(events[0].data, "one\ntwo");
    }

    #[test]
    fn comments_and_keepalives_are_ignored() {
        let events = all(&[": keep-alive\n\ndata: real\n\n"]);
        assert_eq!(events.len(), 1, "{events:?}");
        assert_eq!(events[0].data, "real");
    }

    #[test]
    fn a_field_with_no_space_after_the_colon_still_parses() {
        let events = all(&["data:{\"a\":1}\n\n"]);
        assert_eq!(events[0].data, "{\"a\":1}");
    }

    #[test]
    fn carriage_returns_are_tolerated() {
        let events = all(&["event: delta\r\ndata: x\r\n\r\n"]);
        assert_eq!(events[0].name.as_deref(), Some("delta"));
        assert_eq!(events[0].data, "x");
    }

    #[test]
    fn unknown_fields_are_ignored_rather_than_guessed_at() {
        let events = all(&["id: 7\nretry: 100\ndata: x\n\n"]);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "x");
    }
}
