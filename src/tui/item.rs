//! What the transcript is made of.
//!
//! One grammar for every event, so the eye learns it once:
//!
//! ```text
//! ◆ Title · description · meta · meta
//!   │ continuation, when the title had to be cut
//!   └ outcome
//! ```
//!
//! The leading glyph carries the kind (and its colour), the bold title carries
//! the verb, the accent carries the thing the user chose, and everything the
//! user reads *second* — timings, sizes, key hints — is faint. A user message
//! breaks the pattern deliberately: `⟩` in the accent colour, because finding
//! your own last message in a long transcript is the most common thing you do.

use ratatui::text::{Line, Span};

use super::markdown;
use super::theme;

/// How a piece of work ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Running,
    Ok,
    Failed,
}

impl Status {
    pub fn glyph(self) -> &'static str {
        match self {
            Status::Running => "⋯",
            Status::Ok => "✓",
            Status::Failed => "✗",
        }
    }
}

/// A subagent, as the panel shows it.
#[derive(Debug, Clone)]
pub struct Subagent {
    pub name: String,
    pub id: String,
    pub status: Status,
    pub note: String,
    pub elapsed: std::time::Duration,
}

/// Something a channel delivered while the agent was busy.
#[derive(Debug, Clone)]
pub struct Inbox {
    pub channel: String,
    pub text: String,
    pub read: bool,
}

#[derive(Debug, Clone)]
pub enum Item {
    /// What the user typed.
    User(String),
    /// What the model said. Markdown.
    Assistant(String),
    /// A tool call.
    Tool {
        verb: String,
        description: String,
        status: Status,
        duration: Option<std::time::Duration>,
        /// The command or path, shown under the title when it wraps.
        detail: Option<String>,
        /// One line of outcome — an error, a summary.
        outcome: Option<String>,
    },
    /// A skill entering the conversation.
    Skill { name: String, meta: String },
    /// Subagents were dispatched.
    Spawned { count: usize, names: Vec<String> },
    /// Subagents came back.
    Finished { results: Vec<(String, Status)> },
    /// A message arrived from a channel while work was in flight.
    Received { channel: String, text: String },
    /// Guidance queued for the next checkpoint.
    Steer(String),
    /// Work queued for after this run.
    FollowUp(String),
    /// A snapshot of every subagent, printed on demand so it can be as long as
    /// it needs to be and can be scrolled back to.
    SubagentDetail(Vec<Subagent>),
    /// Aborted, failed, or otherwise worth interrupting the flow for.
    Notice(String),
}

impl Item {
    /// Render to lines at `width`.
    pub fn render(&self, width: usize) -> Vec<Line<'static>> {
        match self {
            Item::User(text) => {
                let spans = markdown::inline(text, theme::fg());
                let mut all = vec![Span::styled("⟩ ", theme::accent())];
                all.extend(spans);
                markdown::wrap(&all, width, "", "  ")
            }

            Item::Assistant(text) => {
                let body = markdown::render(text, width, "  ");
                let mut lines = Vec::with_capacity(body.len());
                for (index, line) in body.into_iter().enumerate() {
                    if index == 0 {
                        // Replace the first line's indent with the glyph, so the
                        // paragraph text still aligns at column 2.
                        let mut spans = vec![Span::styled("◆ ", theme::bold())];
                        spans.extend(line.spans.into_iter().skip(1));
                        lines.push(Line::from(spans));
                    } else {
                        lines.push(line);
                    }
                }
                lines
            }

            Item::Tool {
                verb,
                description,
                status,
                duration,
                detail,
                outcome,
            } => {
                let mut meta = vec![status.glyph().to_string()];
                if let Some(d) = duration {
                    meta.push(format!("{:.1}s", d.as_secs_f32()));
                }
                let mut head = vec![
                    Span::styled("◆ ", theme::danger()),
                    Span::styled(verb.clone(), theme::bold()),
                ];
                if !description.is_empty() {
                    head.push(Span::styled(format!(" · {description}"), theme::accent()));
                }
                head.push(Span::styled(
                    format!(" · {}", meta.join(" · ")),
                    theme::faint(),
                ));

                let mut lines = markdown::wrap(&head, width, "", "  │ ");
                if let Some(detail) = detail {
                    let spans = vec![Span::styled(detail.clone(), theme::code())];
                    lines.extend(markdown::wrap(&spans, width, "  │ ", "  │ "));
                }
                if let Some(outcome) = outcome {
                    let spans = vec![Span::styled(outcome.clone(), theme::dim())];
                    lines.extend(markdown::wrap(&spans, width, "  └ ", "    "));
                }
                lines
            }

            Item::Skill { name, meta } => {
                let head = vec![
                    Span::styled("◆ ", theme::good()),
                    Span::styled("Loaded skill", theme::bold()),
                    Span::styled(format!(" {name}"), theme::accent()),
                    Span::styled(format!(" · {meta}"), theme::faint()),
                ];
                markdown::wrap(&head, width, "", "  ")
            }

            Item::Spawned { count, names } => {
                let head = vec![
                    Span::styled("◆ ", theme::good()),
                    Span::styled(
                        if *count == 1 {
                            "Spawned subagent".to_string()
                        } else {
                            format!("Spawned {count} subagents")
                        },
                        theme::bold(),
                    ),
                    Span::styled(format!(" · {}", names.join(", ")), theme::accent()),
                ];
                let mut lines = markdown::wrap(&head, width, "", "  ");
                lines.push(Line::from(Span::styled(
                    "  (↓ to view subagents)".to_string(),
                    theme::dim(),
                )));
                lines
            }

            Item::Finished { results } => {
                let mut head = vec![
                    Span::styled("◆ ", theme::good()),
                    Span::styled("Finished", theme::bold()),
                ];
                for (name, status) in results {
                    head.push(Span::styled(
                        format!(" · {name} {}", status.glyph()),
                        if *status == Status::Failed {
                            theme::danger()
                        } else {
                            theme::accent()
                        },
                    ));
                }
                markdown::wrap(&head, width, "", "  ")
            }

            // The one item that arrives unbidden, so it is the one that gets a
            // colour of its own.
            Item::Received { channel, text } => {
                let mut head = vec![
                    Span::styled("✉ ", theme::alert()),
                    Span::styled(format!("From {channel}"), theme::bold()),
                    Span::styled(" · ", theme::faint()),
                ];
                head.extend(markdown::inline(text, theme::fg()));
                markdown::wrap(&head, width, "", "  ")
            }

            Item::Steer(text) => queued("Steer", text, width),
            Item::FollowUp(text) => queued("Follow-up", text, width),

            Item::SubagentDetail(agents) => subagent_panel(agents, width),

            Item::Notice(text) => {
                let head = vec![
                    Span::styled("◆ ", theme::danger()),
                    Span::styled(text.clone(), theme::danger()),
                ];
                markdown::wrap(&head, width, "", "  ")
            }
        }
    }
}

fn queued(label: &str, text: &str, width: usize) -> Vec<Line<'static>> {
    let mut head = vec![
        Span::styled("⤷ ", theme::accent()),
        Span::styled(label.to_string(), theme::bold()),
        Span::styled(" · ", theme::faint()),
    ];
    head.extend(markdown::inline(text, theme::fg()));
    markdown::wrap(&head, width, "", "  ")
}

/// The panel that opens under `↓` while subagents are alive.
pub fn subagent_panel(agents: &[Subagent], width: usize) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(vec![
        Span::styled("── ", theme::faint()),
        Span::styled(
            format!(
                "Subagents ({} running)",
                agents
                    .iter()
                    .filter(|a| a.status == Status::Running)
                    .count()
            ),
            theme::dim(),
        ),
        Span::styled(" ".to_string(), theme::faint()),
        Span::styled("─".repeat(width.saturating_sub(24)), theme::faint()),
    ])];

    for agent in agents {
        let style = match agent.status {
            Status::Running => theme::alert(),
            Status::Ok => theme::good(),
            Status::Failed => theme::danger(),
        };
        let mut spans = vec![
            Span::styled("  ", theme::faint()),
            Span::styled(format!("{} ", agent.status.glyph()), style),
            Span::styled(agent.name.clone(), theme::code()),
        ];
        if !agent.id.is_empty() {
            // Enough of the id to disambiguate, not enough to eat the line.
            let short: String = agent.id.chars().take(8).collect();
            spans.push(Span::styled(format!(" {short}"), theme::faint()));
        }
        spans.push(Span::styled(
            format!(" · {:.0}s", agent.elapsed.as_secs_f32()),
            theme::faint(),
        ));
        if !agent.note.is_empty() {
            spans.push(Span::styled(format!(" · {}", agent.note), theme::dim()));
        }
        lines.extend(markdown::wrap(&spans, width, "", "     "));
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;
    use unicode_width::UnicodeWidthStr;

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

    fn first_style(line: &Line<'_>) -> ratatui::style::Style {
        line.spans[0].style
    }

    #[test]
    fn a_user_message_is_marked_so_you_can_find_it() {
        let lines = Item::User("run some commands".into()).render(60);
        assert_eq!(plain(&lines), vec!["⟩ run some commands".to_string()]);
        assert_eq!(first_style(&lines[0]).fg, Some(theme::ACCENT));
    }

    #[test]
    fn a_tool_call_reads_as_verb_description_then_metadata() {
        let lines = Item::Tool {
            verb: "Ran command".into(),
            description: "List workspace contents".into(),
            status: Status::Failed,
            duration: Some(std::time::Duration::from_millis(120)),
            detail: None,
            outcome: None,
        }
        .render(70);
        assert_eq!(
            plain(&lines),
            vec!["◆ Ran command · List workspace contents · ✗ · 0.1s".to_string()]
        );
        assert_eq!(first_style(&lines[0]).fg, Some(theme::DANGER));
    }

    #[test]
    fn a_tool_detail_and_outcome_get_their_own_gutters() {
        let lines = Item::Tool {
            verb: "Ran".into(),
            description: String::new(),
            status: Status::Failed,
            duration: None,
            detail: Some("ls -la /tmp".into()),
            outcome: Some("workdir escapes workspace".into()),
        }
        .render(60);
        let rendered = plain(&lines);
        assert!(
            rendered.iter().any(|l| l.starts_with("  │ ls -la")),
            "{rendered:?}"
        );
        assert!(
            rendered
                .iter()
                .any(|l| l.starts_with("  └ workdir escapes")),
            "{rendered:?}"
        );
    }

    #[test]
    fn an_assistant_reply_keeps_its_markdown_and_aligns_under_the_glyph() {
        let lines = Item::Assistant("**Done** — see `notes.md`\n\n- one\n- two".into()).render(60);
        let rendered = plain(&lines);
        assert!(rendered[0].starts_with("◆ Done"), "{rendered:?}");
        assert!(
            rendered.iter().any(|l| l.starts_with("  • one")),
            "{rendered:?}"
        );
        assert!(
            rendered.iter().any(|l| l.starts_with("  • two")),
            "{rendered:?}"
        );
    }

    #[test]
    fn spawning_subagents_advertises_the_panel() {
        let lines = Item::Spawned {
            count: 2,
            names: vec!["sleep-20-a".into(), "sleep-20-b".into()],
        }
        .render(70);
        let rendered = plain(&lines);
        assert!(
            rendered[0].starts_with("◆ Spawned 2 subagents · sleep-20-a"),
            "{rendered:?}"
        );
        assert!(
            rendered.iter().any(|l| l.contains("↓ to view subagents")),
            "the panel is discoverable: {rendered:?}"
        );
    }

    #[test]
    fn one_subagent_is_singular() {
        let lines = Item::Spawned {
            count: 1,
            names: vec!["worker".into()],
        }
        .render(70);
        assert!(plain(&lines)[0].contains("Spawned subagent · worker"));
    }

    #[test]
    fn an_inbox_message_is_visually_distinct_from_everything_else() {
        let lines = Item::Received {
            channel: "telegram".into(),
            text: "ship it".into(),
        }
        .render(60);
        let rendered = plain(&lines);
        assert!(
            rendered[0].starts_with("✉ From telegram · ship it"),
            "{rendered:?}"
        );
        assert_eq!(
            first_style(&lines[0]).fg,
            Some(theme::ALERT),
            "arriving unbidden earns its own colour"
        );
    }

    #[test]
    fn steer_and_follow_up_are_told_apart() {
        let steer = plain(&Item::Steer("prefer the small fix".into()).render(60));
        let follow = plain(&Item::FollowUp("then run the suite".into()).render(60));
        assert!(steer[0].starts_with("⤷ Steer · prefer"), "{steer:?}");
        assert!(
            follow[0].starts_with("⤷ Follow-up · then run"),
            "{follow:?}"
        );
    }

    #[test]
    fn the_subagent_panel_shows_state_and_age() {
        let agents = vec![
            Subagent {
                name: "sleep-20-a".into(),
                id: "019fe2d7-6106-77e1".into(),
                status: Status::Running,
                note: String::new(),
                elapsed: std::time::Duration::from_secs(4),
            },
            Subagent {
                name: "sleep-20-b".into(),
                id: String::new(),
                status: Status::Failed,
                note: "exit 125".into(),
                elapsed: std::time::Duration::from_secs(9),
            },
        ];
        let rendered = plain(&subagent_panel(&agents, 70));
        assert!(
            rendered[0].contains("Subagents (1 running)"),
            "{rendered:?}"
        );
        assert!(
            rendered[1].contains("⋯ sleep-20-a 019fe2d7 · 4s"),
            "{rendered:?}"
        );
        assert!(
            rendered[2].contains("✗ sleep-20-b · 9s · exit 125"),
            "{rendered:?}"
        );
    }

    #[test]
    fn everything_respects_the_width() {
        let long = "a ".repeat(80);
        let items = [
            Item::User(long.clone()),
            Item::Assistant(long.clone()),
            Item::Received {
                channel: "telegram".into(),
                text: long.clone(),
            },
            Item::Steer(long.clone()),
            Item::Notice(long.clone()),
            Item::Tool {
                verb: "Ran".into(),
                description: long.clone(),
                status: Status::Ok,
                duration: None,
                detail: Some(long.clone()),
                outcome: Some(long.clone()),
            },
        ];
        for item in &items {
            for line in plain(&item.render(40)) {
                assert!(
                    line.width() <= 40,
                    "{:?} overflowed: {line:?}",
                    std::mem::discriminant(item)
                );
            }
        }
    }
}
