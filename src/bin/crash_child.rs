//! A process that dies between intent and effect, on purpose.
//!
//! Used by `tests/crash.rs`. It opens a JSONL session, starts a run whose tool
//! blocks forever, and waits to be SIGKILLed — so the session on disk ends
//! with a committed tool intent whose result never arrived, and quite possibly
//! a torn last line. That is the exact state recovery has to reduce, and the
//! only honest way to produce it is to really kill a real process.

use std::path::PathBuf;
use std::sync::Arc;

use reve::entry::MAIN_LANE;
use reve::harness::{Harness, HarnessConfig};
use reve::hooks::Hooks;
use reve::model::{Assistant, BoxFuture, ScriptedModel, ToolSchema};
use reve::sandbox::tokio_util_lite::CancelRx;
use reve::session::Session;
use reve::state::{LaneConfiguration, ModelRef, Replay, RetryPolicy, RunSettings};
use reve::tools::Tools;
use serde_json::{Map, Value, json};

/// Signals readiness, then never returns. The parent kills us here.
struct HangingTool {
    ready: PathBuf,
    replay: Replay,
}

impl Tools for HangingTool {
    fn replay(&self, _name: &str) -> Option<Replay> {
        Some(self.replay)
    }

    fn schemas(&self) -> Vec<ToolSchema> {
        vec![ToolSchema {
            name: "hang".into(),
            description: "blocks forever".into(),
            schema: json!({"type": "object", "properties": {}}),
        }]
    }

    fn invoke<'a>(
        &'a self,
        _name: &'a str,
        _arguments: Map<String, Value>,
        _cancel: Option<CancelRx>,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            // The intent is already committed and flushed by now, so the file
            // on disk says "this tool is running" the moment we signal.
            std::fs::write(&self.ready, "ready").expect("signal readiness");
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
            }
        })
    }
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let path: PathBuf = args.next().expect("session path").into();
    let ready: PathBuf = args.next().expect("ready path").into();
    let replay = match args.next().as_deref() {
        Some("safe") => Replay::Safe,
        _ => Replay::Never,
    };
    let cursor = path.with_extension("cursor");

    let storage = reve::storage::Storage::open(&path, "crash", None).expect("open the session");
    let session = Session::spawn(storage);
    let harness = Harness::new(
        session,
        HarnessConfig {
            model: Arc::new(ScriptedModel::new(
                vec![
                    Assistant::call("hang", json!({"marker": "persisted"})),
                    Assistant::text("unreachable"),
                ],
                cursor,
            )),
            tools: Arc::new(HangingTool { ready, replay }),
            hooks: Hooks::new(),
            system_prompt: Arc::new(|| "you are a crash test".to_string()),
            settings: RunSettings::default(),
            retry: RetryPolicy::default(),
            configuration: LaneConfiguration {
                model: ModelRef {
                    provider: "test".into(),
                    model_id: "scripted".into(),
                },
                thinking_level: "off".into(),
                active_tool_names: vec!["hang".into()],
            },
            event_capacity: 16,
        },
    );

    let _ = harness
        .prompt(MAIN_LANE, "start something interruptible")
        .await;
    unreachable!("the parent kills this process while the tool hangs");
}
