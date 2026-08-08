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

use crate::project::Project;
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
    let mut banner = String::from(
        "What you type goes to the model. Prefix `!` to run a command in this agent's \
         microVM instead",
    );
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
                            run_command(&sandbox, command.trim(), rx).await
                        } else if let Some(name) = text.strip_prefix('/') {
                            run_tool(&project, &sandbox, name).await
                        } else {
                            no_model_yet()
                        };

                        let _ = updates.send(Update::Item(item)).await;
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

/// Until a provider is wired, say so plainly rather than doing something else
/// with the text. Silently running a prompt as a shell command was worse than
/// refusing it.
fn no_model_yet() -> Item {
    Item::Notice(
        "No provider is wired up yet, so there is nothing to send this to. \
         Use `!command` to run something in the microVM in the meantime."
            .into(),
    )
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
