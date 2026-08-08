//! A scripted session that walks the terminal through every state it has.
//!
//! The engine that will drive this for real — providers, lanes, channels — is
//! still pending, so this exists to make the terminal reviewable now: it is the
//! same `App`, the same `Update` stream, and the same rendering the engine will
//! use. Run it with `cargo run --bin tui_demo`.

use std::time::Duration;

use leve::tui::app::{Action, App, Update};
use leve::tui::item::{Inbox, Item, Status, Subagent};
use tokio::sync::mpsc;

#[tokio::main]
async fn main() -> std::io::Result<()> {
    let (tx, rx) = mpsc::channel(64);
    let (action_tx, mut action_rx) = mpsc::channel(64);

    tokio::spawn(async move {
        // Echo whatever the user does back into the transcript, so typing,
        // steering, and interrupting are all visible while reviewing.
        while let Some(action) = action_rx.recv().await {
            let item = match action {
                Action::Prompt(text) => Item::User(text),
                Action::Steer(text) => Item::Steer(text),
                Action::FollowUp(text) => Item::FollowUp(text),
                Action::Interrupt => Item::Notice("Interrupted".into()),
                Action::Quit => break,
            };
            let _ = tx.send(Update::Item(item)).await;
        }
    });

    let feed = script();
    let (tx2, rx2) = mpsc::channel(64);
    tokio::spawn(async move {
        for (delay, update) in feed {
            tokio::time::sleep(delay).await;
            if tx2.send(update).await.is_err() {
                return;
            }
        }
    });

    // Merge the scripted feed with the echo stream.
    let (merged_tx, merged_rx) = mpsc::channel(64);
    let echo = merged_tx.clone();
    tokio::spawn(async move {
        let mut rx = rx;
        while let Some(update) = rx.recv().await {
            if echo.send(update).await.is_err() {
                return;
            }
        }
    });
    tokio::spawn(async move {
        let mut rx = rx2;
        while let Some(update) = rx.recv().await {
            if merged_tx.send(update).await.is_err() {
                return;
            }
        }
    });

    let app = App::new("leve-spark-1.2", "high", "…/my-agent");
    leve::tui::run::run(app, merged_rx, action_tx).await
}

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

fn script() -> Vec<(Duration, Update)> {
    let agents = |a: Status, b: Status, secs: u64| {
        Update::Subagents(vec![
            Subagent {
                name: "audit-storage".into(),
                id: "019fe2d7-6106-77e1".into(),
                status: a,
                note: if a == Status::Failed {
                    "exit 125".into()
                } else {
                    String::new()
                },
                elapsed: Duration::from_secs(secs),
            },
            Subagent {
                name: "audit-sandbox".into(),
                id: "019fe2d7-66d7-70b2".into(),
                status: b,
                note: String::new(),
                elapsed: Duration::from_secs(secs),
            },
        ])
    };

    vec![
        (
            ms(300),
            Update::Item(Item::Assistant("Hi! What can I do for you?".into())),
        ),
        (
            ms(900),
            Update::Item(Item::User("audit the durable layer".into())),
        ),
        (ms(400), Update::Working(Some("Working".into()))),
        (
            ms(1200),
            Update::Item(Item::Tool {
                verb: "Ran command".into(),
                description: "List the storage module".into(),
                status: Status::Ok,
                duration: Some(ms(120)),
                detail: Some("ls -la src/storage".into()),
                outcome: None,
            }),
        ),
        (
            ms(900),
            Update::Item(Item::Tool {
                verb: "Ran command".into(),
                description: "Check the torn-tail path".into(),
                status: Status::Failed,
                duration: Some(ms(2400)),
                detail: Some("cargo test --lib storage::jsonl -- --nocapture".into()),
                outcome: Some("1 test failed: a_torn_tail_is_truncated".into()),
            }),
        ),
        (
            ms(700),
            Update::Item(Item::Skill {
                name: "review".into(),
                meta: "workspace · 4 KB".into(),
            }),
        ),
        (
            ms(800),
            Update::Item(Item::Spawned {
                count: 2,
                names: vec!["audit-storage".into(), "audit-sandbox".into()],
            }),
        ),
        (ms(100), agents(Status::Running, Status::Running, 0)),
        (ms(1500), agents(Status::Running, Status::Running, 2)),
        (
            ms(1200),
            Update::Received(Inbox {
                channel: "telegram".into(),
                text: "any update? I need this before the demo".into(),
                read: false,
            }),
        ),
        (ms(1800), agents(Status::Ok, Status::Running, 5)),
        (
            ms(1200),
            Update::Item(Item::Assistant(
                "## Findings\n\nThe durable layer holds up, with one gap:\n\n\
                 - `append_entry_if_missing` makes provisioned ids **idempotent**, so \
                 recovery can re-run freely.\n\
                 - A torn tail truncates; a malformed line *elsewhere* is refused as \
                 corruption.\n\
                 - Single writer is still a convention — `Lane` borrows `Storage` rather \
                 than owning it.\n\n\
                 ```rust\n\
                 pub fn append_entry_if_missing(&mut self, entry: Entry) -> Result<EntryId>\n\
                 ```\n\n\
                 > The gap closes when lane execution moves into an owning task."
                    .into(),
            )),
        ),
        (ms(1500), agents(Status::Ok, Status::Failed, 9)),
        (
            ms(200),
            Update::Item(Item::Finished {
                results: vec![
                    ("audit-storage".into(), Status::Ok),
                    ("audit-sandbox".into(), Status::Failed),
                ],
            }),
        ),
        (ms(600), Update::Working(None)),
    ]
}
