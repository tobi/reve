//! A process that dies between intent and effect, on purpose.
//!
//! Used by `tests/crash.rs`. It opens a JSONL session, starts a run whose tool
//! blocks forever, and waits to be SIGKILLed — so the session on disk ends with
//! a `tool_started` whose result never arrived. That is the exact state
//! recovery has to reduce, and the only honest way to produce it is to really
//! kill a real process.

use std::path::PathBuf;

use leve::lane::{Lane, Tools};
use leve::model::{Assistant, BoxFuture, ScriptedModel};
use leve::records::{MAIN_LANE, Replay};
use serde_json::{Map, Value};

/// Signals readiness, then never returns. The parent kills us here.
struct HangingTool {
    ready: PathBuf,
}

impl Tools for HangingTool {
    fn replay(&self, _name: &str) -> Replay {
        Replay::Never
    }

    fn invoke<'a>(
        &'a self,
        _name: &'a str,
        _arguments: Map<String, Value>,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            // The intent record is already flushed to disk by now.
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
    let session: PathBuf = args.next().expect("session path").into();
    let ready: PathBuf = args.next().expect("ready path").into();
    let cursor = session.with_extension("cursor");

    let mut storage =
        leve::storage::Storage::open(&session, "crash", None).expect("open the session");
    let model = ScriptedModel::new(
        vec![
            Assistant::call("hang", serde_json::json!({})),
            Assistant::text("unreachable"),
        ],
        cursor,
    );
    let tools = HangingTool { ready };

    let _ = Lane {
        name: MAIN_LANE.into(),
        storage: &mut storage,
        model: &model,
        tools: &tools,
    }
    .run("start something interruptible", None)
    .await;

    unreachable!("the parent kills this process while the tool hangs");
}
