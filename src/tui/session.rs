//! The terminal, wired to a real microVM.
//!
//! This is what bare `leve` runs. There is no model yet, so a prompt is taken
//! literally: it is run in the agent's VM and the result rendered as a tool
//! call. That is a genuinely useful shell — everything you type executes under
//! the sandbox policy in `sandbox.lua`, not on your machine — and it is the
//! same loop a model turn will use, so wiring providers replaces one step
//! rather than the structure.

use std::sync::Arc;
use std::time::Instant;

use tokio::sync::mpsc;

use crate::model::{Model, Request, StopReason};
use crate::project::Project;
use crate::provider::HttpModel;
use crate::provider::config::Models;
use crate::sandbox::tokio_util_lite::{CancelTx, channel};
use crate::sandbox::{ExecOptions, Sandbox};
use crate::tui::app::{Action, App, Update};
use crate::tui::item::{Item, Status};

/// Run the terminal until the user leaves.
pub async fn run(project: Project, sandbox: Arc<Sandbox>) -> anyhow::Result<()> {
    let (updates, updates_rx) = mpsc::channel(256);
    let (actions, mut actions_rx) = mpsc::channel(64);

    let location = project
        .root
        .file_name()
        .map(|n| format!("…/{}", n.to_string_lossy()))
        .unwrap_or_else(|| project.root.display().to_string());
    let app = App::new(
        project
            .runtime
            .agent
            .model
            .clone()
            .unwrap_or_else(|| "no model".into()),
        project
            .runtime
            .agent
            .thinking
            .clone()
            .unwrap_or_else(|| "default".into()),
        location,
    );

    let tools: Vec<String> = project
        .runtime
        .tools
        .iter()
        .map(|t| t.name.clone())
        .collect();
    // Resolve the model up front: a missing key should be a sentence at
    // startup, not a failure on the user's first prompt.
    let model = load_model(&project);
    let mut banner = match &model {
        Ok(_) => String::from(
            "What you type goes to the model. Prefix `!` to run a command in this agent's \
             microVM instead",
        ),
        Err(why) => format!("**No model.** {why}\n\nPrefix `!` to run a command in the microVM"),
    };
    if tools.is_empty() {
        banner.push('.');
    } else {
        banner.push_str(&format!(", or `/{}` to run a tool.", tools.join("`, `/")));
    }
    let _ = updates.send(Update::Item(Item::Assistant(banner))).await;

    let worker = {
        let updates = updates.clone();
        let project = Arc::new(project);
        tokio::spawn(async move {
            // The first request of a session has a cold prefix by definition,
            // so warning about it would be noise every single launch.
            let mut turns = 0usize;
            // Held so an Interrupt can reach the command that is running.
            let mut cancel: Option<CancelTx> = None;
            while let Some(action) = actions_rx.recv().await {
                match action {
                    Action::Interrupt => {
                        if let Some(tx) = &cancel {
                            tx.cancel();
                        }
                    }
                    Action::Prompt(text) | Action::Steer(text) | Action::FollowUp(text) => {
                        let (tx, rx) = channel();
                        cancel.replace(tx);
                        let _ = updates.send(Update::Item(Item::User(text.clone()))).await;
                        let _ = updates.send(Update::Working(Some("Running".into()))).await;

                        // `!` is the shell escape, exactly as it is in the
                        // durable record; anything else is for the model.
                        let item = if let Some(command) = text.strip_prefix('!') {
                            Some(run_command(&sandbox, command.trim(), rx).await)
                        } else if let Some(name) = text.strip_prefix('/') {
                            Some(run_tool(&project, &sandbox, name).await)
                        } else {
                            match &model {
                                Ok(model) => {
                                    turns += 1;
                                    ask(model.as_ref(), &project, &text, &updates, turns > 1).await
                                }
                                Err(why) => Some(Item::Notice(format!("no model: {why}"))),
                            }
                        };

                        if let Some(item) = item {
                            let _ = updates.send(Update::Item(item)).await;
                        }
                        let _ = updates.send(Update::Working(None)).await;
                        cancel.take();
                    }
                    Action::Quit => break,
                }
            }
        })
    };

    let result = crate::tui::run::run(app, updates_rx, actions).await;
    worker.abort();
    result.map_err(Into::into)
}

async fn run_command(
    sandbox: &Sandbox,
    command: &str,
    cancel: crate::sandbox::tokio_util_lite::CancelRx,
) -> Item {
    let started = Instant::now();
    match sandbox
        .exec(command, ExecOptions::default(), Some(cancel))
        .await
    {
        Ok(output) => {
            let text = if output.stdout.trim().is_empty() {
                output.stderr.trim().to_string()
            } else {
                output.stdout.trim().to_string()
            };
            Item::Tool {
                verb: "Ran".into(),
                description: command.lines().next().unwrap_or("").to_string(),
                status: if output.cancelled || !output.success {
                    Status::Failed
                } else {
                    Status::Ok
                },
                duration: Some(started.elapsed()),
                detail: (!text.is_empty()).then_some(text),
                outcome: output
                    .cancelled
                    .then(|| "interrupted".to_string())
                    .or_else(|| (!output.success).then(|| format!("exit {}", output.exit_code))),
            }
        }
        Err(e) => Item::Notice(format!("sandbox error: {e}")),
    }
}

/// Resolve the configured model from the agent's own `models.yml`.
fn load_model(project: &Project) -> std::result::Result<Arc<dyn Model>, String> {
    let path = project.root.join("models.yml");
    let models = Models::load(&path).map_err(|e| e.to_string())?;
    let spec = project
        .runtime
        .agent
        .model
        .clone()
        .ok_or_else(|| "agent.lua does not set a model".to_string())?;
    let resolved = models.resolve(&spec).map_err(|e| e.to_string())?;
    Ok(Arc::new(HttpModel::new(resolved)))
}

/// One model turn, streamed.
///
/// Text is forwarded as it arrives so the terminal can settle finished blocks
/// into scrollback; only what is still in flight stays live.
async fn ask(
    model: &dyn Model,
    project: &Project,
    prompt: &str,
    updates: &mpsc::Sender<Update>,
    warn_on_cache_miss: bool,
) -> Option<Item> {
    let context = vec![crate::records::Entry::message(
        crate::records::MAIN_LANE,
        serde_json::json!({"role": "user", "content": prompt}),
    )];
    let tools = crate::provider::tool_schemas(&project.runtime);
    let instructions =
        std::fs::read_to_string(project.root.join("instructions.md")).unwrap_or_default();

    let sink = updates.clone();
    let forward = move |delta: &str| {
        // The renderer is async and this callback is not, so hand the chunk
        // over without waiting; the channel is bounded and ordered.
        let _ = sink.try_send(Update::Delta(delta.to_string()));
    };

    let request = Request {
        context: &context,
        system: instructions.trim(),
        tools: &tools,
    };
    match model.respond(request, &forward).await {
        Ok(turn) => {
            let _ = updates.send(Update::EndMessage).await;
            if turn.stop_reason == StopReason::ToolUse {
                let names: Vec<String> = turn.tool_calls.iter().map(|c| c.name.clone()).collect();
                // Executing them is the lane's job, and the lane is not wired
                // to the terminal yet — so say what was asked for rather than
                // pretending it happened.
                Some(Item::Notice(format!(
                    "the model asked to run {}; tool execution from the terminal is not \
                     wired up yet",
                    names.join(", ")
                )))
            } else if warn_on_cache_miss
                && turn.usage.input > 0
                && turn.usage.uncached_fraction() > 0.3
            {
                Some(Item::Notice(format!(
                    "prompt cache miss: {:.0}% of {} input tokens were uncached",
                    turn.usage.uncached_fraction() * 100.0,
                    turn.usage.input
                )))
            } else {
                // The reply already streamed into the transcript; there is
                // nothing left to announce.
                None
            }
        }
        Err(e) => Some(Item::Notice(e.to_string())),
    }
}

async fn run_tool(project: &Project, sandbox: &Arc<Sandbox>, name: &str) -> Item {
    let started = Instant::now();
    match project
        .runtime
        .call_tool(name, serde_json::Map::new(), sandbox.clone())
        .await
    {
        Ok(text) => Item::Tool {
            verb: "Ran tool".into(),
            description: name.to_string(),
            status: Status::Ok,
            duration: Some(started.elapsed()),
            detail: (!text.trim().is_empty()).then(|| text.trim().to_string()),
            outcome: None,
        },
        Err(e) => Item::Tool {
            verb: "Ran tool".into(),
            description: name.to_string(),
            status: Status::Failed,
            duration: Some(started.elapsed()),
            detail: None,
            outcome: Some(e.to_string()),
        },
    }
}
