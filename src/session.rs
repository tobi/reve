//! The owning task for one durable session.
//!
//! `Storage` never leaves this task. Callers get a channel and a oneshot reply,
//! not `&mut Storage`; this is the structural single-writer guarantee that the
//! previous inline terminal path did not have.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc, oneshot};

use crate::lane::{Lane, Result as LaneResult, RunEvent, Tools, recover};
use crate::model::{Model, ToolSchema};
use crate::records::Outcome;
use crate::storage::{Order, Storage, StorageError};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub seq: u64,
    pub lane: String,
    pub leaf: Option<String>,
    pub entries: usize,
    pub records: usize,
}

#[derive(Debug, Clone)]
pub enum Event {
    Snapshot(Snapshot),
    Run(RunEvent),
    Finished { outcome: Outcome },
}

pub enum Command {
    Prompt {
        text: String,
        cancel: Option<crate::sandbox::tokio_util_lite::CancelRx>,
        reply: oneshot::Sender<LaneResult<crate::lane::RunReport>>,
    },
    Recover {
        reply: oneshot::Sender<LaneResult<Vec<crate::lane::Recovered>>>,
    },
    Snapshot {
        reply: oneshot::Sender<Snapshot>,
    },
    Close,
}

#[derive(Clone)]
pub struct SessionHandle {
    tx: mpsc::Sender<Command>,
    events: broadcast::Sender<Event>,
}

impl SessionHandle {
    pub async fn prompt(
        &self,
        text: impl Into<String>,
        cancel: Option<crate::sandbox::tokio_util_lite::CancelRx>,
    ) -> LaneResult<crate::lane::RunReport> {
        let (reply, result) = oneshot::channel();
        self.tx
            .send(Command::Prompt {
                text: text.into(),
                cancel,
                reply,
            })
            .await
            .map_err(|_| {
                crate::lane::LaneError::Storage(StorageError::Io(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "session task closed",
                )))
            })?;
        result.await.map_err(|_| {
            crate::lane::LaneError::Storage(StorageError::Io(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "session task dropped reply",
            )))
        })?
    }

    pub async fn recover(&self) -> LaneResult<Vec<crate::lane::Recovered>> {
        let (reply, result) = oneshot::channel();
        self.tx
            .send(Command::Recover { reply })
            .await
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }

    pub async fn snapshot(&self) -> Snapshot {
        let (reply, result) = oneshot::channel();
        if self.tx.send(Command::Snapshot { reply }).await.is_err() {
            return Snapshot {
                seq: 0,
                lane: "main".into(),
                leaf: None,
                entries: 0,
                records: 0,
            };
        }
        result.await.unwrap_or(Snapshot {
            seq: 0,
            lane: "main".into(),
            leaf: None,
            entries: 0,
            records: 0,
        })
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    pub async fn close(&self) {
        let _ = self.tx.send(Command::Close).await;
    }
}

fn closed() -> crate::lane::LaneError {
    crate::lane::LaneError::Storage(StorageError::Io(std::io::Error::new(
        std::io::ErrorKind::BrokenPipe,
        "session task closed",
    )))
}

pub struct SessionTask;

impl SessionTask {
    pub fn spawn(
        storage: Storage,
        model: Arc<dyn Model>,
        tools: Arc<dyn Tools>,
        lane: impl Into<String>,
        system: String,
        schemas: Vec<ToolSchema>,
    ) -> SessionHandle {
        let (tx, mut rx) = mpsc::channel(32);
        let (events, _) = broadcast::channel(256);
        let handle = SessionHandle {
            tx,
            events: events.clone(),
        };
        let lane = lane.into();
        tokio::spawn(async move {
            let mut storage = storage;
            while let Some(command) = rx.recv().await {
                match command {
                    Command::Prompt {
                        text,
                        cancel,
                        reply,
                    } => {
                        let event_sink = events.clone();
                        let model = model.clone();
                        let tools = tools.clone();
                        let system = system.clone();
                        let schemas = schemas.clone();
                        let name = lane.clone();
                        let result = {
                            let mut runner = Lane {
                                name,
                                storage: &mut storage,
                                model: model.as_ref(),
                                tools: tools.as_ref(),
                            };
                            runner
                                .run_with(&text, cancel, &system, &schemas, &|event| {
                                    let _ = event_sink.send(Event::Run(event));
                                })
                                .await
                        };
                        if let Ok(report) = &result {
                            let _ = events.send(Event::Finished {
                                outcome: report.outcome,
                            });
                        }
                        let _ = events.send(Event::Snapshot(snapshot(&storage, &lane)));
                        let _ = reply.send(result);
                    }
                    Command::Recover { reply } => {
                        let result = recover(&mut storage, &lane, tools.as_ref()).await;
                        let _ = events.send(Event::Snapshot(snapshot(&storage, &lane)));
                        let _ = reply.send(result);
                    }
                    Command::Snapshot { reply } => {
                        let _ = reply.send(snapshot(&storage, &lane));
                    }
                    Command::Close => break,
                }
            }
        });
        handle
    }
}

fn snapshot(storage: &Storage, lane: &str) -> Snapshot {
    Snapshot {
        seq: storage.seq(),
        lane: lane.to_string(),
        leaf: storage.leaf(lane).map(|id| id.to_string()),
        entries: storage.find_entries(None, Order::OldestFirst).len(),
        records: storage.find_records(None).len(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lane::Tools;
    use crate::model::{Assistant, ScriptedModel};
    use crate::records::Replay;
    use parking_lot::Mutex;
    use serde_json::Value;

    struct TestTools(Mutex<Vec<String>>);
    impl Tools for TestTools {
        fn replay(&self, _: &str) -> Replay {
            Replay::Safe
        }
        fn invoke<'a>(
            &'a self,
            name: &'a str,
            _: serde_json::Map<String, Value>,
        ) -> crate::model::BoxFuture<'a, Result<String, String>> {
            self.0.lock().push(name.into());
            Box::pin(async move { Ok(format!("{name} result")) })
        }
    }

    #[tokio::test]
    async fn storage_never_leaves_the_owner_task() {
        let dir = tempfile::tempdir().unwrap();
        let storage = Storage::open(dir.path().join("s.jsonl"), "s", None).unwrap();
        let model: Arc<dyn Model> = Arc::new(ScriptedModel::new(
            vec![Assistant::text("hello")],
            dir.path().join("cursor"),
        ));
        let tools: Arc<dyn Tools> = Arc::new(TestTools(Mutex::new(Vec::new())));
        let session = SessionTask::spawn(storage, model, tools, "main", "system".into(), vec![]);
        let report = session.prompt("hi", None).await.unwrap();
        assert_eq!(report.outcome, Outcome::Completed);
        let snapshot = session.snapshot().await;
        assert_eq!(
            snapshot.entries, 2,
            "user and assistant were persisted by the owner"
        );
        assert!(snapshot.records >= 3);
        session.close().await;
    }

    #[tokio::test]
    async fn reopening_the_same_session_keeps_context_and_seq() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.jsonl");
        let model: Arc<dyn Model> = Arc::new(ScriptedModel::new(
            vec![Assistant::text("first")],
            dir.path().join("cursor-a"),
        ));
        let tools: Arc<dyn Tools> = Arc::new(TestTools(Mutex::new(Vec::new())));
        let first = SessionTask::spawn(
            Storage::open(&path, "s", None).unwrap(),
            model,
            tools.clone(),
            "main",
            "system".into(),
            vec![],
        );
        first.prompt("one", None).await.unwrap();
        let before = first.snapshot().await;
        first.close().await;

        let second_model: Arc<dyn Model> = Arc::new(ScriptedModel::new(
            vec![Assistant::text("second")],
            dir.path().join("cursor-b"),
        ));
        let second = SessionTask::spawn(
            Storage::open(&path, "s", None).unwrap(),
            second_model,
            tools,
            "main",
            "system".into(),
            vec![],
        );
        second.prompt("two", None).await.unwrap();
        let after = second.snapshot().await;
        assert!(
            after.seq > before.seq,
            "reopened storage continues the sequence"
        );
        assert!(after.entries >= 4, "both prompts and both answers remain");
        second.close().await;
    }

    #[tokio::test]
    async fn observers_receive_finished_and_snapshot_events() {
        let dir = tempfile::tempdir().unwrap();
        let storage = Storage::open(dir.path().join("s.jsonl"), "s", None).unwrap();
        let model: Arc<dyn Model> = Arc::new(ScriptedModel::new(
            vec![Assistant::text("ok")],
            dir.path().join("c"),
        ));
        let tools: Arc<dyn Tools> = Arc::new(TestTools(Mutex::new(Vec::new())));
        let session = SessionTask::spawn(storage, model, tools, "main", String::new(), vec![]);
        let mut events = session.subscribe();
        session.prompt("hi", None).await.unwrap();
        let mut saw_finished = false;
        let mut saw_snapshot = false;
        for _ in 0..4 {
            match events.recv().await.unwrap() {
                Event::Finished { .. } => saw_finished = true,
                Event::Snapshot(snapshot) => {
                    saw_snapshot = snapshot.seq > 0;
                }
                Event::Run(_) => {}
            }
        }
        assert!(saw_finished);
        assert!(saw_snapshot);
        session.close().await;
    }
}
