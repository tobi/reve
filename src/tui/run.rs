//! The event loop.

use std::io::stdout;
use std::time::Duration;

use crossterm::event::{self, Event as TermEvent};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use ratatui::backend::CrosstermBackend;
use ratatui::{Terminal, TerminalOptions, Viewport};
use tokio::sync::mpsc;

use super::app::{Action, App, TICK, Update, flush};

/// Run the terminal until the user leaves.
///
/// `updates` carries what the engine is doing; `actions` carries what the user
/// asked for. Neither side blocks the other: a slow run still redraws, and a
/// keystroke is never dropped waiting for one.
pub async fn run(
    mut app: App,
    mut updates: mpsc::Receiver<Update>,
    actions: mpsc::Sender<Action>,
) -> std::io::Result<()> {
    enable_raw_mode()?;
    let mut terminal = Terminal::with_options(
        CrosstermBackend::new(stdout()),
        TerminalOptions {
            viewport: Viewport::Inline(app.live_height()),
        },
    )?;

    let result = event_loop(&mut app, &mut terminal, &mut updates, &actions).await;

    // Leave the transcript on screen: clear only our own region and put the
    // cursor below it, the way a well-behaved inline program should.
    let _ = terminal.clear();
    disable_raw_mode()?;
    let _ = terminal.show_cursor();
    println!();
    result
}

async fn event_loop(
    app: &mut App,
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    updates: &mut mpsc::Receiver<Update>,
    actions: &mpsc::Sender<Action>,
) -> std::io::Result<()> {
    let mut ticker = tokio::time::interval(TICK);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        // Anything finished goes to real scrollback before we draw, so the live
        // region never has to scroll.
        let width = terminal.size()?.width as usize;
        let finished = app.drain_scrollback();
        if !finished.is_empty() {
            flush(terminal, &finished, width)?;
        }

        terminal.draw(|frame| {
            let area = frame.area();
            app.render_live(area, frame.buffer_mut());
            let (x, y) = app.cursor(area);
            frame.set_cursor_position((x, y));
        })?;

        tokio::select! {
            _ = ticker.tick() => {
                // Drain keyboard input without blocking the runtime.
                while event::poll(Duration::from_millis(0))? {
                    if let TermEvent::Key(key) = event::read()?
                        && key.kind == event::KeyEventKind::Press
                        && let Some(action) = app.handle_key(key)
                    {
                        if action == Action::Quit {
                            return Ok(());
                        }
                        if actions.send(action).await.is_err() {
                            return Ok(());
                        }
                    }
                }
            }
            update = updates.recv() => {
                match update {
                    Some(update) => {
                        if !apply_update(app, actions, update).await {
                            return Ok(());
                        }
                    }
                    None => return Ok(()),
                }
            }
        }
    }
}

async fn apply_update(app: &mut App, actions: &mpsc::Sender<Action>, update: Update) -> bool {
    match update {
        Update::Received(message) => {
            app.apply(Update::Received(message.clone()));
            actions.send(Action::ChannelMessage(message)).await.is_ok()
        }
        update => {
            app.apply(update);
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channels::Message;
    use crate::tui::item::Item;

    #[tokio::test]
    async fn a_channel_update_is_forwarded_to_the_agent() {
        let mut app = App::new("model", "low", "workspace");
        let (actions, mut received) = mpsc::channel(1);
        let message = Message {
            channel: "telegram".into(),
            text: "ship it".into(),
            timestamp: 13,
        };

        assert!(apply_update(&mut app, &actions, Update::Received(message.clone())).await);
        assert_eq!(received.recv().await, Some(Action::ChannelMessage(message)));
        assert!(matches!(
            app.drain_scrollback().as_slice(),
            [Item::Received { channel, text }]
                if channel == "telegram" && text == "ship it"
        ));
    }
}
