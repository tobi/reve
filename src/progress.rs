//! Startup progress.
//!
//! Booting a microVM for the first time pulls an image and installs a
//! toolchain, which is around half a minute of the program apparently doing
//! nothing. So it says what it is doing, keeps moving, and leaves each finished
//! stage on screen with what it cost:
//!
//! ```text
//!   ✓ built microVM leve-my-agent-4cc1857b63       4.1s
//!   ⠹ provisioning APT packages and node@lts       12s
//! ```
//!
//! Finished stages are printed once and never redrawn; only the last line
//! animates. That way the output is still readable after the fact, and piping
//! it somewhere does not produce a screenful of spinner frames.

use std::io::{IsTerminal, Write, stderr};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use parking_lot::Mutex;

use crate::sandbox::Progress;
use crate::theme;
use unicode_width::UnicodeWidthStr;

const FRAMES: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const TICK: Duration = Duration::from_millis(80);

struct Stage {
    label: String,
    started: Instant,
}

struct State {
    stage: Option<Stage>,
    frame: usize,
    /// Set once anything has been drawn, so we know whether a line needs
    /// clearing before the next write.
    dirty: bool,
}

/// An animated, multi-stage progress line.
pub struct Spinner {
    state: Arc<Mutex<State>>,
    stop: Arc<AtomicBool>,
    thread: Mutex<Option<JoinHandle<()>>>,
    animate: bool,
    started: Instant,
}

impl Default for Spinner {
    fn default() -> Self {
        Self::new()
    }
}

impl Spinner {
    pub fn new() -> Self {
        // Without a terminal there is nobody to animate for, and the frames
        // would just be noise in a log.
        Self::with_animation(stderr().is_terminal())
    }

    pub fn with_animation(animate: bool) -> Self {
        Self {
            state: Arc::new(Mutex::new(State {
                stage: None,
                frame: 0,
                dirty: false,
            })),
            stop: Arc::new(AtomicBool::new(false)),
            thread: Mutex::new(None),
            animate,
            started: Instant::now(),
        }
    }

    fn spawn(&self) {
        let mut thread = self.thread.lock();
        if thread.is_some() {
            return;
        }
        let state = self.state.clone();
        let stop = self.stop.clone();
        *thread = Some(std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                {
                    let mut state = state.lock();
                    state.frame = state.frame.wrapping_add(1);
                    if let Some(stage) = &state.stage {
                        let frame = FRAMES[state.frame % FRAMES.len()];
                        let line = render(
                            frame,
                            theme::RGB_ALERT,
                            &stage.label,
                            stage.started.elapsed(),
                        );
                        let mut err = stderr();
                        let _ = write!(err, "\r\x1b[2K{line}");
                        let _ = err.flush();
                        state.dirty = true;
                    }
                }
                std::thread::sleep(TICK);
            }
        }));
    }

    /// Settle the current stage onto its own line.
    ///
    /// Without a terminal there is no width to align against and no spinner
    /// line to erase, so a log gets one plain line per stage with its cost.
    fn settle(&self, mark: &str, colour: (u8, u8, u8), label: &str, elapsed: Duration) {
        let mut err = stderr();
        if !self.animate {
            let _ = writeln!(err, "  {mark} {label} ({})", human(elapsed));
            let _ = err.flush();
            return;
        }
        let mut state = self.state.lock();
        if state.dirty {
            let _ = write!(err, "\r\x1b[2K");
            state.dirty = false;
        }
        let _ = writeln!(err, "{}", render(mark, colour, label, elapsed));
        let _ = err.flush();
    }
}

impl Progress for Spinner {
    fn stage(&self, label: &str) {
        let previous = {
            let mut state = self.state.lock();
            state.stage.replace(Stage {
                label: label.to_string(),
                started: Instant::now(),
            })
        };
        // Each new stage finalises the one before it, so the log reads as a
        // list of what happened and what each part cost.
        if let Some(previous) = previous {
            self.settle(
                "✓",
                theme::RGB_GOOD,
                &previous.label,
                previous.started.elapsed(),
            );
        }
        // Only the animated path announces a stage before it finishes; a log
        // wants the record, one line each, not a start and an end for both.
        if self.animate {
            self.spawn();
        }
    }

    fn finish(&self, label: &str) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.lock().take() {
            let _ = thread.join();
        }
        let last = self.state.lock().stage.take();
        if let Some(last) = last {
            self.settle("✓", theme::RGB_GOOD, &last.label, last.started.elapsed());
        }
        self.settle("✓", theme::RGB_GOOD, label, self.started.elapsed());
    }
}

impl Drop for Spinner {
    fn drop(&mut self) {
        // A panic or an early return must not leave a spinner thread writing
        // over whatever is printed next.
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.lock().take() {
            let _ = thread.join();
        }
        if self.state.lock().dirty {
            let _ = write!(stderr(), "\r\x1b[2K");
            let _ = stderr().flush();
        }
    }
}

/// `  <mark> <label><padding><elapsed>`, timing flush right.
///
/// Right-aligned against the real terminal width so a column of stages is
/// scannable, and the label is elided rather than allowed to push the timing
/// off the edge.
fn render(mark: &str, colour: (u8, u8, u8), label: &str, elapsed: Duration) -> String {
    render_at(mark, colour, label, elapsed, terminal_width())
}

fn render_at(
    mark: &str,
    colour: (u8, u8, u8),
    label: &str,
    elapsed: Duration,
    width: usize,
) -> String {
    let (r, g, b) = colour;
    let (fr, fg, fb) = theme::RGB_FAINT;
    let time = human(elapsed);
    // "  x " + label + at least one space + time
    let room = width.saturating_sub(4 + time.width() + 1);
    let label = if label.width() > room {
        let mut kept: String = String::new();
        for ch in label.chars() {
            if kept.width() + 1 >= room {
                break;
            }
            kept.push(ch);
        }
        format!("{kept}…")
    } else {
        label.to_string()
    };
    let pad = " ".repeat(
        width
            .saturating_sub(4 + label.width() + time.width())
            .max(1),
    );
    format!(
        "  \x1b[38;2;{r};{g};{b}m{mark}\x1b[0m {label}{pad}\x1b[38;2;{fr};{fg};{fb}m{time}\x1b[0m"
    )
}

/// Capped, because a very wide terminal should not fling the timing to the far
/// right where it is no longer next to what it times.
fn terminal_width() -> usize {
    crossterm::terminal::size()
        .map(|(w, _)| w as usize)
        .unwrap_or(80)
        .clamp(24, 88)
}

fn human(elapsed: Duration) -> String {
    let secs = elapsed.as_secs_f32();
    if secs < 10.0 {
        format!("{secs:.1}s")
    } else {
        format!("{:.0}s", secs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timings_read_naturally_at_both_scales() {
        assert_eq!(human(Duration::from_millis(1200)), "1.2s");
        assert_eq!(human(Duration::from_secs(32)), "32s");
    }

    #[test]
    fn a_stage_line_right_aligns_its_timing() {
        let line = render_at(
            "✓",
            theme::RGB_GOOD,
            "provisioning",
            Duration::from_secs(12),
            60,
        );
        let visible = strip_ansi(&line);
        assert!(visible.starts_with("  ✓ provisioning"), "{visible:?}");
        assert!(visible.ends_with("12s"), "{visible:?}");
        assert_eq!(visible.width(), 60, "flush right: {visible:?}");
    }

    #[test]
    fn stages_of_different_lengths_line_their_timings_up() {
        let short = strip_ansi(&render_at(
            "✓",
            theme::RGB_GOOD,
            "building",
            Duration::from_secs(4),
            60,
        ));
        let long = strip_ansi(&render_at(
            "✓",
            theme::RGB_GOOD,
            "provisioning APT packages and node@lts",
            Duration::from_secs(18),
            60,
        ));
        assert_eq!(short.width(), long.width(), "{short:?} vs {long:?}");
    }

    #[test]
    fn a_label_too_long_for_the_line_is_elided_not_allowed_to_shove_the_timing_off() {
        let line = strip_ansi(&render_at(
            "⠋",
            theme::RGB_ALERT,
            "building microVM leve-try2-96d47e5f27 from debian:trixie-slim",
            Duration::from_secs(3),
            40,
        ));
        assert!(line.width() <= 40, "{} — {line:?}", line.width());
        assert!(line.ends_with("3.0s"), "the timing survives: {line:?}");
        assert!(line.contains('…'), "and the cut is visible: {line:?}");
    }

    #[test]
    fn without_a_terminal_it_prints_plain_lines_and_no_frames() {
        // Piping the output somewhere must not fill it with spinner frames.
        let spinner = Spinner::with_animation(false);
        spinner.stage("building");
        spinner.stage("provisioning");
        spinner.finish("ready");
        assert!(
            spinner.thread.lock().is_none(),
            "no animation thread was ever started"
        );
    }

    #[test]
    fn dropping_mid_stage_does_not_leave_a_thread_running() {
        let spinner = Spinner::with_animation(true);
        spinner.stage("building");
        assert!(spinner.thread.lock().is_some());
        let stop = spinner.stop.clone();
        drop(spinner);
        assert!(stop.load(Ordering::Relaxed), "the thread was told to stop");
    }

    fn strip_ansi(text: &str) -> String {
        let mut out = String::new();
        let mut chars = text.chars();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                for c in chars.by_ref() {
                    if c == 'm' {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }
}
