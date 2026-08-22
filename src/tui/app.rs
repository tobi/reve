//! The terminal.
//!
//! Rendered **inline**, not in the alternate screen. Finished transcript items
//! are pushed into the terminal's own scrollback with `insert_before`, so
//! scrolling, selection, and copy/paste are the terminal's job and keep working
//! exactly as they do everywhere else. Only the live region — what is running,
//! what is waiting on you, and the input line — is redrawn.
//!
//! The live region is deliberately small and stable, so the transcript above it
//! does not jump while you read.

use std::io::Stdout;
use std::time::{Duration, Instant};

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget};
use unicode_width::UnicodeWidthStr;

use super::complete::{Candidate, Command, Completion, accept, complete};
use super::item::{Item, Status, Subagent};
use super::stream::Stream;
use super::theme;

/// What the app wants the caller to do.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// Submit a new prompt.
    Prompt(String),
    /// Guidance for the run already in flight.
    Steer(String),
    /// Work to pick up after this run.
    FollowUp(String),
    /// A message delivered by a configured channel.
    ChannelMessage(crate::channels::Message),
    /// Abort the current operation.
    Interrupt,
    Quit,
}

/// What the engine tells the app.
#[derive(Debug, Clone)]
pub enum Update {
    Item(Item),
    /// `Some(label)` while a run is in flight.
    Working(Option<String>),
    Subagents(Vec<Subagent>),
    /// Current workspace-relative file candidates.
    Files(Vec<Candidate>),
    Received(crate::channels::Message),
    /// A chunk of assistant text. Settled blocks go to scrollback as they
    /// complete; the rest is shown live until it settles.
    Delta(String),
    /// The assistant turn ended.
    EndMessage,
}

/// A single-line editor. Small on purpose: history and completion belong to the
/// dispatcher, not to the text field.
#[derive(Debug, Default)]
pub struct Input {
    text: String,
    cursor: usize,
}

impl Input {
    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn is_empty(&self) -> bool {
        self.text.trim().is_empty()
    }

    pub fn take(&mut self) -> String {
        self.cursor = 0;
        std::mem::take(&mut self.text)
    }

    /// Replace the whole line, cursor to the end.
    pub fn set(&mut self, text: String) {
        self.cursor = text.chars().count();
        self.text = text;
    }

    pub fn insert(&mut self, c: char) {
        let at = self.byte_at(self.cursor);
        self.text.insert(at, c);
        self.cursor += 1;
    }

    pub fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let at = self.byte_at(self.cursor - 1);
        self.text.remove(at);
        self.cursor -= 1;
    }

    /// Delete the word before the cursor — the edit you actually make most.
    pub fn delete_word(&mut self) {
        let mut end = self.cursor;
        while end > 0 && self.char_at(end - 1).is_whitespace() {
            end -= 1;
        }
        while end > 0 && !self.char_at(end - 1).is_whitespace() {
            end -= 1;
        }
        let from = self.byte_at(end);
        let to = self.byte_at(self.cursor);
        self.text.replace_range(from..to, "");
        self.cursor = end;
    }

    pub fn left(&mut self) {
        self.cursor = self.cursor.saturating_sub(1);
    }

    pub fn right(&mut self) {
        self.cursor = (self.cursor + 1).min(self.text.chars().count());
    }

    pub fn home(&mut self) {
        self.cursor = 0;
    }

    pub fn end(&mut self) {
        self.cursor = self.text.chars().count();
    }

    fn char_at(&self, index: usize) -> char {
        self.text.chars().nth(index).unwrap_or(' ')
    }

    fn byte_at(&self, index: usize) -> usize {
        self.text
            .char_indices()
            .nth(index)
            .map(|(i, _)| i)
            .unwrap_or(self.text.len())
    }

    /// Display column of the cursor.
    pub fn column(&self) -> u16 {
        self.text
            .chars()
            .take(self.cursor)
            .collect::<String>()
            .width() as u16
    }
}

pub struct App {
    pub input: Input,
    pub subagents: Vec<Subagent>,
    /// Model, effort, and where we are — the three things worth a permanent line.
    pub model: String,
    pub effort: String,
    pub location: String,
    working: Option<(String, Instant)>,
    stream: Stream,
    /// Whether this message has already printed its first line, which is the
    /// one that carries the `◆`.
    stream_opened: bool,
    tail_height: u16,
    /// Slash commands, including this agent's own Lua tools.
    commands: Vec<Command>,
    /// Workspace-relative `@file` candidates.
    files: Vec<Candidate>,
    completion: Completion,
    /// Which candidate is highlighted. The first, until the user moves.
    selected: usize,
    scrollback: Vec<Item>,
    interrupt_armed: bool,
    frame: usize,
}

impl App {
    pub fn new(
        model: impl Into<String>,
        effort: impl Into<String>,
        location: impl Into<String>,
    ) -> Self {
        Self {
            input: Input::default(),
            subagents: Vec::new(),
            model: model.into(),
            effort: effort.into(),
            location: location.into(),
            working: None,
            stream: Stream::new(),
            stream_opened: false,
            tail_height: 0,
            commands: Vec::new(),
            completion: Completion::default(),
            selected: 0,
            files: Vec::new(),
            scrollback: Vec::new(),
            interrupt_armed: false,
            frame: 0,
        }
    }

    /// Install the slash commands. Called once the agent is loaded, because
    /// the list includes its Lua tools and its configured models.
    pub fn set_commands(&mut self, commands: Vec<Command>) {
        self.commands = commands;
    }

    pub fn set_files(&mut self, files: Vec<Candidate>) {
        self.files = files;
        self.refresh_completion();
    }
    pub fn commands(&self) -> &[Command] {
        &self.commands
    }

    pub fn completion(&self) -> &Completion {
        &self.completion
    }

    pub fn selected(&self) -> usize {
        self.selected
    }

    /// Recompute after every edit, so the list tracks what is typed.
    fn refresh_completion(&mut self) {
        let previous = self
            .completion
            .candidates
            .get(self.selected)
            .map(|c| c.value.clone());
        self.completion = complete(self.input.text(), &self.commands, &self.files);
        // Keep the highlight on the same entry when it survives the edit.
        self.selected = previous
            .and_then(|value| {
                self.completion
                    .candidates
                    .iter()
                    .position(|c| c.value == value)
            })
            .unwrap_or(0);
    }

    pub fn busy(&self) -> bool {
        self.working.is_some()
    }

    pub fn apply(&mut self, update: Update) {
        match update {
            Update::Item(item) => self.scrollback.push(item),
            Update::Working(label) => {
                self.working = label.map(|l| (l, Instant::now()));
                if self.working.is_none() {
                    self.interrupt_armed = false;
                }
            }
            Update::Subagents(agents) => self.subagents = agents,
            Update::Files(files) => self.set_files(files),
            Update::Delta(text) => {
                self.stream.push(&text);
                self.flush_frozen();
            }
            Update::EndMessage => {
                self.stream.finish();
                self.flush_frozen();
                self.stream = Stream::new();
                self.stream_opened = false;
            }
            Update::Received(message) => {
                self.scrollback.push(Item::Received {
                    channel: message.channel,
                    text: message.text,
                });
            }
        }
    }

    /// Move settled markdown out of the stream and into the transcript.
    ///
    /// Only the first chunk of a message carries the `◆`; the rest continues
    /// it, so a long reply reads as one block rather than a list of them.
    fn flush_frozen(&mut self) {
        let Some(text) = self.stream.take_frozen() else {
            return;
        };
        // `take_frozen` is byte-exact so the durable record keeps every
        // separator; the transcript spaces its own items, so drop them here.
        let text = text.trim_end_matches('\n').to_string();
        if text.is_empty() {
            return;
        }
        let item = if self.stream_opened {
            Item::AssistantContinued(text)
        } else {
            self.stream_opened = true;
            Item::Assistant(text)
        };
        self.scrollback.push(item);
    }

    /// The in-flight text, drawn above the chrome while it streams.
    pub fn stream_tail(&self, width: usize) -> Vec<Line<'static>> {
        self.stream.tail(width)
    }

    /// Items that are finished with, to be pushed into terminal scrollback.
    pub fn drain_scrollback(&mut self) -> Vec<Item> {
        std::mem::take(&mut self.scrollback)
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<Action> {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Char('c') if ctrl => {
                // While work is in flight, the first ctrl-c aborts it; only a
                // second one, with nothing running, leaves.
                if self.busy() {
                    self.interrupt_armed = true;
                    return Some(Action::Interrupt);
                }
                return Some(Action::Quit);
            }
            KeyCode::Char('d') if ctrl && self.input.is_empty() => return Some(Action::Quit),
            KeyCode::Char('w') if ctrl => {
                self.input.delete_word();
                self.refresh_completion();
            }
            KeyCode::Char('u') if ctrl => {
                self.input.take();
                self.refresh_completion();
            }
            KeyCode::Char(c) => {
                self.input.insert(c);
                self.refresh_completion();
            }
            KeyCode::Backspace => {
                self.input.backspace();
                self.refresh_completion();
            }
            KeyCode::Left => self.input.left(),
            KeyCode::Right => self.input.right(),
            KeyCode::Home => self.input.home(),
            KeyCode::End => self.input.end(),
            KeyCode::Tab => {
                // Tab accepts; the first candidate is highlighted already, so
                // the common case is one keystroke.
                if self.completion.is_open() {
                    let text = accept(
                        self.input.text(),
                        &self.completion,
                        self.selected,
                        &self.commands,
                    );
                    self.input.set(text);
                    self.refresh_completion();
                }
            }
            KeyCode::Esc => {
                // While work is visible, Escape must always mean what the
                // status line promises. Completion can be reopened after the
                // run; requiring a hidden first press made interruption feel
                // intermittent.
                if self.busy() {
                    self.interrupt_armed = true;
                    return Some(Action::Interrupt);
                }
                if self.completion.is_open() {
                    self.completion = Completion::default();
                }
            }
            KeyCode::Down => {
                if self.completion.is_open() {
                    self.selected = (self.selected + 1) % self.completion.candidates.len();
                } else if !self.subagents.is_empty() {
                    let agents = self.subagents.clone();
                    self.scrollback.push(Item::SubagentDetail(agents));
                }
            }
            KeyCode::Up => {
                if self.completion.is_open() {
                    let len = self.completion.candidates.len();
                    self.selected = (self.selected + len - 1) % len;
                }
            }
            KeyCode::Enter => {
                if self.input.is_empty() {
                    return None;
                }
                let text = self.input.take();
                self.completion = Completion::default();
                if text == "/queue" {
                    self.scrollback
                        .push(Item::Notice("usage: /queue <message>".into()));
                    return None;
                }
                if let Some(message) = text.strip_prefix("/queue ") {
                    let message = message.trim().to_string();
                    if message.is_empty() {
                        self.scrollback
                            .push(Item::Notice("usage: /queue <message>".into()));
                        return None;
                    }
                    self.scrollback.push(Item::FollowUp(message.clone()));
                    return Some(Action::FollowUp(message));
                }
                // The same keystroke means different things depending on
                // whether the agent is working, which is the distinction the
                // status line above the input is there to make obvious.
                return Some(if self.busy() {
                    if let Some(rest) = text.strip_prefix('&') {
                        let message = rest.trim().to_string();
                        self.scrollback.push(Item::FollowUp(message.clone()));
                        Action::FollowUp(message)
                    } else {
                        Action::Steer(text)
                    }
                } else {
                    Action::Prompt(text)
                });
            }
            _ => {}
        }
        None
    }

    /// The live region is a fixed size.
    ///
    /// A region that grew and shrank would move the input line under the
    /// user's hands every time a tool started, and would make the transcript
    /// above it jump while being read. Six rows, bottom-aligned, always:
    /// subagent strip, working line, rule, input, rule, status.
    pub const HEIGHT: u16 = 6;

    /// Six rows of chrome, plus the in-flight text while a reply streams.
    ///
    /// The tail is the one thing allowed to change the height, because it only
    /// does so as whole blocks settle into scrollback — not per token — and
    /// because the alternative is showing nothing until a reply finishes.
    pub fn live_height(&self) -> u16 {
        Self::HEIGHT
    }

    /// Rows shared by whatever needs them: the candidate list while choosing a
    /// command, the in-flight reply while one streams, otherwise the subagent
    /// strip and the working line.
    ///
    /// A fixed budget rather than a growing region. Resizing an inline
    /// viewport blanks the screen, and even when it does not, a region that
    /// grew would shove the input line under the user's hands.
    pub const OVERFLOW: u16 = 3;
    pub const MAX_CANDIDATES: u16 = Self::OVERFLOW;

    pub fn completion_height(&self) -> u16 {
        (self.completion.candidates.len() as u16).min(Self::MAX_CANDIDATES)
    }

    /// The live region: the in-flight text, then six fixed rows of chrome.
    pub fn render_live(&mut self, area: Rect, buf: &mut ratatui::buffer::Buffer) {
        self.frame = self.frame.wrapping_add(1);
        let width = area.width as usize;
        self.tail_height = 0;
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(1); 6])
            .split(area);

        // The three shared rows, in priority order: choosing a command beats
        // watching a reply arrive, which beats idle status. Menus and status
        // hug the input; a reply starts directly below the transcript and grows
        // downward, instead of appearing at the bottom and expanding backward.
        let (overflow, bottom_aligned): (Vec<Line<'static>>, bool) = if self.completion.is_open() {
            (self.candidate_lines(width), true)
        } else {
            let mut tail = self.stream_tail(width);
            if tail.len() > Self::OVERFLOW as usize {
                tail.drain(..tail.len() - Self::OVERFLOW as usize);
            }
            if tail.is_empty() {
                let mut rows = Vec::new();
                if !self.subagents.is_empty() {
                    rows.push(self.subagent_strip(width));
                }
                if self.busy() {
                    rows.push(self.working_line());
                }
                (rows, true)
            } else {
                (tail, false)
            }
        };
        let offset = if bottom_aligned {
            Self::OVERFLOW as usize - overflow.len().min(Self::OVERFLOW as usize)
        } else {
            0
        };
        for (index, line) in overflow
            .into_iter()
            .take(Self::OVERFLOW as usize)
            .enumerate()
        {
            Paragraph::new(line).render(chunks[offset + index], buf);
        }

        Paragraph::new(self.top_rule(width)).render(chunks[3], buf);
        Paragraph::new(self.input_line()).render(chunks[4], buf);
        Paragraph::new(self.status_line(width)).render(chunks[5], buf);
    }

    /// One live row for every subagent at once: state, name, age.
    ///
    /// A row rather than a panel because this has to stay current without ever
    /// changing height. `↓` prints the full detail into the transcript, where
    /// it can be as long as it likes and can be scrolled back to.
    fn subagent_strip(&self, width: usize) -> Line<'static> {
        let mut spans = vec![Span::styled("  ", theme::faint())];
        for (i, agent) in self.subagents.iter().enumerate() {
            if i > 0 {
                spans.push(Span::styled(" · ", theme::faint()));
            }
            let style = match agent.status {
                Status::Running => theme::alert(),
                Status::Ok => theme::good(),
                Status::Failed => theme::danger(),
            };
            spans.push(Span::styled(format!("{} ", agent.status.glyph()), style));
            spans.push(Span::styled(agent.name.clone(), theme::code()));
            spans.push(Span::styled(
                format!(" {:.0}s", agent.elapsed.as_secs_f32()),
                theme::faint(),
            ));
        }
        // Too many to name: collapse to counts rather than letting the row be
        // clipped mid-name, which would misreport which agents exist.
        let hint = "↓ detail";
        let mut used: usize = spans.iter().map(|s| s.content.width()).sum();
        if used + hint.width() + 2 > width {
            let running = self
                .subagents
                .iter()
                .filter(|a| a.status == Status::Running)
                .count();
            let failed = self
                .subagents
                .iter()
                .filter(|a| a.status == Status::Failed)
                .count();
            let done = self.subagents.len() - running - failed;
            spans = vec![Span::styled("  ", theme::faint())];
            if running > 0 {
                spans.push(Span::styled(format!("⋯ {running} running"), theme::alert()));
            }
            if done > 0 {
                spans.push(Span::styled(format!(" ✓ {done}"), theme::good()));
            }
            if failed > 0 {
                spans.push(Span::styled(format!(" ✗ {failed}"), theme::danger()));
            }
            used = spans.iter().map(|s| s.content.width()).sum();
        }
        if used + hint.width() + 2 <= width {
            spans.push(Span::styled(
                " ".repeat(width - used - hint.width() - 1),
                theme::faint(),
            ));
            spans.push(Span::styled(hint.to_string(), theme::dim()));
        }
        Line::from(spans)
    }

    /// The candidate list, with the selection always kept in view.
    fn candidate_lines(&self, width: usize) -> Vec<Line<'static>> {
        let max = Self::MAX_CANDIDATES as usize;
        let start = self.selected.saturating_sub(max - 1);
        let name_width = self
            .completion
            .candidates
            .iter()
            .map(|c| c.value.width())
            .max()
            .unwrap_or(0)
            .min(28);

        self.completion
            .candidates
            .iter()
            .enumerate()
            .skip(start)
            .take(max)
            .map(|(index, candidate)| {
                let picked = index == self.selected;
                let mut spans = vec![
                    Span::styled(if picked { "▸ " } else { "  " }, theme::accent()),
                    Span::styled(
                        format!("{:<name_width$}", candidate.value),
                        if picked { theme::bold() } else { theme::fg() },
                    ),
                ];
                if !candidate.detail.is_empty() {
                    let room = width.saturating_sub(4 + name_width);
                    let detail: String = candidate.detail.chars().take(room).collect();
                    spans.push(Span::styled(format!("  {detail}"), theme::dim()));
                }
                Line::from(spans)
            })
            .collect()
    }

    /// Where the cursor should sit, given the live region's origin.
    pub fn cursor(&self, area: Rect) -> (u16, u16) {
        (area.x + 2 + self.input.column(), area.y + 4)
    }

    /// The shimmer that tells you it is alive without redrawing the world.
    fn working_line(&self) -> Line<'static> {
        let (label, since) = self.working.as_ref().expect("busy");
        let elapsed = since.elapsed().as_secs();
        let mut spans = vec![Span::styled("◇ ", theme::dim())];
        let period = theme::SHIMMER.len() * 2;
        for (i, ch) in label.chars().enumerate() {
            let shade = (i + period - (self.frame / 2) % period) % period;
            let shade = if shade >= theme::SHIMMER.len() {
                theme::SHIMMER.len() - 1
            } else {
                shade
            };
            spans.push(Span::styled(
                ch.to_string(),
                ratatui::style::Style::default().fg(theme::SHIMMER[shade]),
            ));
        }
        let hint = if self.interrupt_armed {
            "interrupting…"
        } else {
            "esc to interrupt"
        };
        spans.push(Span::styled(
            format!(" ({elapsed}s · {hint})"),
            theme::faint(),
        ));
        Line::from(spans)
    }

    /// The rule above the input doubles as the place to say what Enter will do.
    fn top_rule(&self, width: usize) -> Line<'static> {
        let (label, style) = if self.completion.is_open() {
            (
                format!(
                    "{} match{} · tab to accept · ↑↓ to choose",
                    self.completion.candidates.len(),
                    if self.completion.candidates.len() == 1 {
                        ""
                    } else {
                        "es"
                    }
                ),
                theme::dim(),
            )
        } else if self.busy() {
            (
                "Enter steers · /queue text follows up".to_string(),
                theme::dim(),
            )
        } else if !self.subagents.is_empty() {
            (
                format!(
                    "↓ {} subagents",
                    self.subagents
                        .iter()
                        .filter(|a| a.status == Status::Running)
                        .count()
                ),
                theme::dim(),
            )
        } else {
            ("Enter to send".to_string(), theme::dim())
        };
        let used = label.width() + 4;
        Line::from(vec![
            Span::styled("── ", theme::faint()),
            Span::styled(label, style),
            Span::styled(" ", theme::faint()),
            Span::styled("─".repeat(width.saturating_sub(used)), theme::faint()),
        ])
    }

    fn input_line(&self) -> Line<'static> {
        Line::from(vec![
            Span::styled("⟩ ", theme::accent()),
            Span::styled(self.input.text().to_string(), theme::fg()),
        ])
    }

    /// Model, effort, and where we are.
    ///
    /// The location is the part that gives way: it is the least surprising
    /// thing on the line, and eliding it from the left keeps the end that
    /// identifies it.
    fn status_line(&self, width: usize) -> Line<'static> {
        let running = self
            .subagents
            .iter()
            .filter(|a| a.status == Status::Running)
            .count();
        let suffix = if running > 0 {
            format!(" · {running} running")
        } else {
            String::new()
        };
        let fixed = 2 + self.model.width() + 3 + self.effort.width() + 3 + suffix.width();
        let location = elide_left(&self.location, width.saturating_sub(fixed));

        let mut spans = vec![
            Span::styled("  ", theme::faint()),
            Span::styled(self.model.clone(), theme::accent()),
            Span::styled(" · ", theme::dim()),
            Span::styled(self.effort.clone(), theme::accent()),
        ];
        if !location.is_empty() {
            spans.push(Span::styled(" · ", theme::dim()));
            spans.push(Span::styled(location, theme::dim()));
        }
        if !suffix.is_empty() {
            spans.push(Span::styled(suffix, theme::alert()));
        }
        Line::from(spans)
    }
}

/// Keep the tail of a path: that is the part that identifies it.
fn elide_left(text: &str, width: usize) -> String {
    if text.width() <= width {
        return text.to_string();
    }
    if width <= 1 {
        return String::new();
    }
    let mut kept = String::new();
    let mut used = 1; // the ellipsis
    for ch in text.chars().rev() {
        let w = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + w > width {
            break;
        }
        kept.insert(0, ch);
        used += w;
    }
    format!("…{kept}")
}

/// Push finished items into the terminal's real scrollback.
pub fn flush(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    items: &[Item],
    width: usize,
) -> std::io::Result<()> {
    for item in items {
        let mut lines = item.render(width);
        lines.push(Line::from(""));
        let height = lines.len() as u16;
        terminal.insert_before(height, |buf| {
            Paragraph::new(lines).render(buf.area, buf);
        })?;
    }
    Ok(())
}

/// The tick that drives the shimmer and the elapsed counters.
pub const TICK: Duration = Duration::from_millis(90);

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn ctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }

    fn typed(app: &mut App, text: &str) {
        for c in text.chars() {
            app.handle_key(key(KeyCode::Char(c)));
        }
    }

    fn app() -> App {
        App::new("reve-1", "high", "…/my-agent")
    }

    #[test]
    fn the_working_shimmer_moves_forward_through_the_label() {
        let mut a = app();
        a.apply(Update::Working(Some("Running".into())));

        a.frame = 0;
        let first = a.working_line();
        a.frame = 2;
        let second = a.working_line();

        assert_eq!(first.spans[1].style.fg, Some(theme::SHIMMER[0]));
        assert_eq!(
            second.spans[2].style.fg,
            Some(theme::SHIMMER[0]),
            "the brightest cell advances from R to u"
        );
    }

    #[test]
    fn enter_sends_a_prompt_when_idle_and_steers_when_busy() {
        let mut a = app();
        typed(&mut a, "hello");
        assert_eq!(
            a.handle_key(key(KeyCode::Enter)),
            Some(Action::Prompt("hello".into()))
        );

        a.apply(Update::Working(Some("Working".into())));
        typed(&mut a, "actually use the small fix");
        assert_eq!(
            a.handle_key(key(KeyCode::Enter)),
            Some(Action::Steer("actually use the small fix".into())),
            "the same keystroke means steer while work is in flight"
        );
    }

    #[test]
    fn an_ampersand_queues_a_follow_up_instead_of_steering() {
        let mut a = app();
        a.apply(Update::Working(Some("Working".into())));
        typed(&mut a, "& then run the suite");
        assert_eq!(
            a.handle_key(key(KeyCode::Enter)),
            Some(Action::FollowUp("then run the suite".into()))
        );
    }

    #[test]
    fn queue_is_a_discoverable_follow_up_command() {
        let mut a = app();
        typed(&mut a, "/queue run the suite");
        assert_eq!(
            a.handle_key(key(KeyCode::Enter)),
            Some(Action::FollowUp("run the suite".into()))
        );
        assert!(matches!(
            a.drain_scrollback().as_slice(),
            [Item::FollowUp(text)] if text == "run the suite"
        ));
    }

    #[test]
    fn an_empty_line_does_nothing() {
        let mut a = app();
        assert_eq!(a.handle_key(key(KeyCode::Enter)), None);
        typed(&mut a, "   ");
        assert_eq!(a.handle_key(key(KeyCode::Enter)), None);
    }

    #[test]
    fn escape_interrupts_only_while_busy() {
        let mut a = app();
        assert_eq!(
            a.handle_key(key(KeyCode::Esc)),
            None,
            "nothing to interrupt"
        );
        a.apply(Update::Working(Some("Working".into())));
        assert_eq!(a.handle_key(key(KeyCode::Esc)), Some(Action::Interrupt));
        assert!(a.interrupt_armed);
    }

    #[test]
    fn escape_interrupts_busy_work_even_when_completion_is_open() {
        let mut a = app();
        a.set_commands(vec![Command::new("help", "show help")]);
        typed(&mut a, "/h");
        assert!(a.completion.is_open());
        a.apply(Update::Working(Some("Working".into())));

        assert_eq!(a.handle_key(key(KeyCode::Esc)), Some(Action::Interrupt));
        assert!(
            a.completion.is_open(),
            "the key was not consumed by the menu"
        );
    }

    #[test]
    fn ctrl_c_interrupts_while_busy_and_quits_when_idle() {
        let mut a = app();
        a.apply(Update::Working(Some("Working".into())));
        assert_eq!(a.handle_key(ctrl('c')), Some(Action::Interrupt));
        a.apply(Update::Working(None));
        assert_eq!(a.handle_key(ctrl('c')), Some(Action::Quit));
    }

    #[test]
    fn the_input_editor_handles_the_edits_people_actually_make() {
        let mut a = app();
        typed(&mut a, "cargo test --lib");
        a.handle_key(ctrl('w'));
        assert_eq!(a.input.text(), "cargo test ");
        a.handle_key(key(KeyCode::Backspace));
        assert_eq!(a.input.text(), "cargo test");
        a.handle_key(ctrl('u'));
        assert!(a.input.is_empty());
    }

    #[test]
    fn the_cursor_tracks_wide_characters() {
        let mut a = app();
        typed(&mut a, "日本");
        assert_eq!(
            a.input.column(),
            4,
            "two double-width chars are four columns"
        );
        a.handle_key(key(KeyCode::Left));
        assert_eq!(a.input.column(), 2);
    }

    #[test]
    fn a_received_message_becomes_transcript_without_an_unread_mode() {
        let mut a = app();
        a.apply(Update::Received(crate::channels::Message {
            channel: "telegram".into(),
            text: "ship it".into(),
            timestamp: 13,
        }));
        assert!(matches!(
            a.drain_scrollback().as_slice(),
            [Item::Received { channel, text }]
                if channel == "telegram" && text == "ship it"
        ));
    }

    #[test]
    fn the_rule_above_the_input_says_what_enter_will_do() {
        let mut a = app();
        let text = |a: &App| {
            a.top_rule(60)
                .spans
                .iter()
                .map(|s| s.content.to_string())
                .collect::<String>()
        };
        assert!(text(&a).contains("Enter to send"), "{}", text(&a));

        a.apply(Update::Working(Some("Working".into())));
        assert!(text(&a).contains("Enter steers"), "{}", text(&a));

        a.apply(Update::Received(crate::channels::Message {
            channel: "telegram".into(),
            text: "hi".into(),
            timestamp: 13,
        }));
        assert!(
            text(&a).contains("Enter steers"),
            "delivery does not create a separate unread state: {}",
            text(&a)
        );
    }

    #[test]
    fn pressing_down_prints_subagent_detail_into_the_transcript() {
        let mut a = app();
        a.handle_key(key(KeyCode::Down));
        assert!(
            a.drain_scrollback().is_empty(),
            "nothing to show, nothing printed"
        );

        a.apply(Update::Subagents(vec![Subagent {
            name: "worker".into(),
            id: "abc".into(),
            status: Status::Running,
            note: String::new(),
            elapsed: Duration::from_secs(1),
        }]));
        a.handle_key(key(KeyCode::Down));
        let printed = a.drain_scrollback();
        assert!(
            matches!(printed.as_slice(), [Item::SubagentDetail(agents)] if agents.len() == 1),
            "detail goes to scrollback, where it can be long and scrolled back to"
        );
    }

    #[test]
    fn the_live_region_never_changes_height() {
        // A region that grew would move the input line under the user's hands
        // and make the transcript above it jump while being read.
        let mut a = app();
        let height = a.live_height();
        a.apply(Update::Working(Some("Working".into())));
        assert_eq!(
            a.live_height(),
            height,
            "starting work does not move anything"
        );
        a.apply(Update::Subagents(vec![Subagent {
            name: "worker".into(),
            id: String::new(),
            status: Status::Running,
            note: String::new(),
            elapsed: Duration::from_secs(1),
        }]));
        assert_eq!(a.live_height(), height, "nor does a subagent appearing");
    }

    #[test]
    fn every_subagent_stays_visible_on_one_live_row() {
        let mut a = app();
        a.apply(Update::Subagents(vec![
            Subagent {
                name: "alpha".into(),
                id: String::new(),
                status: Status::Running,
                note: String::new(),
                elapsed: Duration::from_secs(3),
            },
            Subagent {
                name: "beta".into(),
                id: String::new(),
                status: Status::Failed,
                note: String::new(),
                elapsed: Duration::from_secs(7),
            },
        ]));
        let strip: String = a
            .subagent_strip(78)
            .spans
            .iter()
            .map(|s| s.content.to_string())
            .collect();
        assert!(strip.contains("⋯ alpha 3s"), "{strip}");
        assert!(strip.contains("✗ beta 7s"), "{strip}");
        assert!(strip.contains("↓ detail"), "{strip}");
        assert!(strip.width() <= 78, "and it fits: {}", strip.width());
    }

    #[test]
    fn a_crowded_strip_collapses_to_counts_instead_of_being_clipped() {
        let mut a = app();
        a.apply(Update::Subagents(
            (0..9)
                .map(|i| Subagent {
                    name: format!("audit-subsystem-{i}"),
                    id: String::new(),
                    status: if i == 0 {
                        Status::Failed
                    } else {
                        Status::Running
                    },
                    note: String::new(),
                    elapsed: Duration::from_secs(3),
                })
                .collect(),
        ));
        let strip: String = a
            .subagent_strip(78)
            .spans
            .iter()
            .map(|s| s.content.to_string())
            .collect();
        assert!(
            strip.width() <= 78,
            "it fits: {} — {strip:?}",
            strip.width()
        );
        assert!(
            strip.contains("8 running"),
            "and still reports the truth: {strip:?}"
        );
        assert!(strip.contains("✗ 1"), "{strip:?}");
        assert!(
            strip.contains("↓ detail"),
            "with detail still reachable: {strip:?}"
        );
    }

    #[test]
    fn a_long_location_is_elided_from_the_left_rather_than_cut_off() {
        let a = App::new(
            "reve-spark-1.2",
            "high",
            "/home/tobi/src/deeply/nested/project/worktree-green-valley-793b",
        );
        let status: String = a
            .status_line(50)
            .spans
            .iter()
            .map(|s| s.content.to_string())
            .collect();
        assert!(
            status.width() <= 50,
            "it fits: {} — {status:?}",
            status.width()
        );
        assert!(
            status.contains("green-valley-793b"),
            "the end survives: {status:?}"
        );
        assert!(status.contains('…'), "and the cut is visible: {status:?}");
    }

    #[test]
    fn a_status_line_with_no_room_for_a_path_still_shows_the_model() {
        let a = App::new("reve-spark-1.2", "high", "/very/long/path/indeed");
        let status: String = a
            .status_line(24)
            .spans
            .iter()
            .map(|s| s.content.to_string())
            .collect();
        assert!(status.width() <= 24, "{status:?}");
        assert!(status.contains("reve-spark-1.2"), "{status:?}");
    }

    /// Render into a buffer and read the rows back, so what is asserted is
    /// what a user would see.
    fn screen(app: &mut App, width: u16) -> String {
        let area = Rect::new(0, 0, width, app.live_height());
        let mut buf = ratatui::buffer::Buffer::empty(area);
        app.render_live(area, &mut buf);
        (0..area.height)
            .map(|y| {
                (0..width)
                    .map(|x| buf[(x, y)].symbol().to_string())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn the_candidate_list_is_actually_drawn() {
        let mut a = app();
        a.set_commands(vec![
            Command::new("help", "what these commands do"),
            Command::new("model", "show or switch the model"),
        ]);
        typed(&mut a, "/");
        assert!(a.completion().is_open());

        let text = screen(&mut a, 60);
        assert!(text.contains("/help"), "candidates are on screen:\n{text}");
        assert!(text.contains("/model"), "{text}");
        assert!(text.contains("▸"), "one is highlighted:\n{text}");
        assert!(
            text.contains("⟩ /"),
            "and the input is still there:\n{text}"
        );
    }

    #[test]
    fn workspace_files_complete_and_render_with_details() {
        let mut a = app();
        a.set_files(vec![Candidate {
            value: "@AGENTS.md".into(),
            detail: "309 B".into(),
        }]);
        typed(&mut a, "inspect @AG");

        let text = screen(&mut a, 60);
        assert!(
            text.contains("@AGENTS.md"),
            "file candidate is visible:\n{text}"
        );
        assert!(text.contains("309 B"), "file detail is visible:\n{text}");

        assert_eq!(a.handle_key(key(KeyCode::Tab)), None);
        assert_eq!(a.input.text(), "inspect @AGENTS.md");
    }

    #[test]
    fn refreshed_workspace_files_complete_without_restarting_the_tui() {
        let mut a = app();
        typed(&mut a, "inspect @new");
        assert!(!a.completion().is_open());

        a.apply(Update::Files(vec![Candidate {
            value: "@new.txt".into(),
            detail: "1 B".into(),
        }]));
        assert!(a.completion().is_open());
    }

    #[test]
    fn the_streaming_tail_is_actually_drawn() {
        let mut a = app();
        a.apply(Update::Delta("a sentence still arriving".into()));
        let text = screen(&mut a, 60);
        assert!(
            text.contains("still arriving"),
            "in-flight text is visible:\n{text}"
        );
    }

    #[test]
    fn consecutive_turns_are_flushed_in_temporal_order() {
        let mut a = app();
        a.apply(Update::Delta("first answer".into()));
        a.apply(Update::EndMessage);
        a.apply(Update::Item(Item::User("next question".into())));
        a.apply(Update::Delta("second answer".into()));
        a.apply(Update::EndMessage);

        assert!(matches!(
            a.drain_scrollback().as_slice(),
            [
                Item::Assistant(first),
                Item::User(question),
                Item::Assistant(second),
            ] if first == "first answer"
                && question == "next question"
                && second == "second answer"
        ));
    }

    #[test]
    fn a_stream_starts_below_the_transcript_and_grows_downward() {
        let mut a = app();
        a.apply(Update::Delta("first words".into()));

        let text = screen(&mut a, 60);
        let rows: Vec<_> = text.lines().collect();
        assert_eq!(
            rows[0], "  first words",
            "new text belongs at the top of the shared rows, not at the bottom"
        );
        assert!(rows[1].is_empty(), "the unused room follows the text");
        assert!(rows[2].is_empty(), "the unused room follows the text");
    }

    #[test]
    fn choosing_a_command_takes_priority_over_watching_a_reply() {
        let mut a = app();
        a.set_commands(vec![Command::new("help", "reference")]);
        a.apply(Update::Delta("streaming text".into()));
        typed(&mut a, "/");
        let text = screen(&mut a, 60);
        assert!(text.contains("/help"), "{text}");
        assert!(
            !text.contains("streaming text"),
            "the menu wins the shared rows:\n{text}"
        );
    }

    #[test]
    fn running_subagents_are_surfaced_in_the_status_line() {
        let mut a = app();
        a.apply(Update::Subagents(vec![Subagent {
            name: "worker".into(),
            id: String::new(),
            status: Status::Running,
            note: String::new(),
            elapsed: Duration::from_secs(1),
        }]));
        let status: String = a
            .status_line(78)
            .spans
            .iter()
            .map(|s| s.content.to_string())
            .collect();
        assert!(status.contains("1 running"), "{status}");
    }
}
