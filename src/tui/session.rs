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

use crate::lane::{Lane, RunEvent, recover};
use crate::model::Model;
use crate::project::Project;
use crate::provider::HttpModel;
use crate::provider::config::Models;
use crate::records::MAIN_LANE;
use crate::sandbox::tokio_util_lite::{CancelTx, channel};
use crate::sandbox::{ExecOptions, Sandbox};
use crate::storage::Storage;
use crate::tools::Toolbox;
use crate::tui::app::{Action, App, Update};
use crate::tui::complete::{Candidate, Command};
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
    let mut app = App::new(
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
    app.set_commands(commands_for(&project));

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
            let toolbox = Toolbox::new(sandbox.clone(), project.runtime_arc());
            // Storage is owned by this worker task. No other task receives a
            // mutable handle, making the single-writer rule structural on the
            // terminal path.
            let session_path = project
                .latest_session(MAIN_LANE)
                .unwrap_or_else(|| project.conversation_path(MAIN_LANE));
            let mut storage = match Storage::open(&session_path, "main", Some("workspace".into())) {
                Ok(storage) => storage,
                Err(error) => {
                    let _ = updates
                        .send(Update::Item(Item::Notice(format!("session: {error}"))))
                        .await;
                    return;
                }
            };
            let _ = recover(&mut storage, MAIN_LANE, &toolbox).await;
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
                        let item = if text.trim() == "/compact" {
                            match crate::compaction::compact(
                                &mut storage,
                                MAIN_LANE,
                                20,
                                "manual compaction",
                            ) {
                                Ok(report) => Some(Item::Assistant(format!(
                                    "compacted {} entries into `{}`",
                                    report.removed_from_context, report.summary_id
                                ))),
                                Err(error) => Some(Item::Notice(format!("compact: {error}"))),
                            }
                        } else if let Some(command) = text.strip_prefix('!') {
                            Some(run_command(&sandbox, command.trim(), rx).await)
                        } else if let Some(rest) = text.strip_prefix('/') {
                            dispatch(&project, &sandbox, rest).await
                        } else {
                            match &model {
                                Ok(model) => {
                                    let system = system_prompt(&project);
                                    let schemas = toolbox.schemas();
                                    let sink = updates.clone();
                                    let events = move |event| match event {
                                        RunEvent::AssistantDelta(delta) => {
                                            let _ = sink.try_send(Update::Delta(delta));
                                        }
                                        RunEvent::ToolStarted { name, .. } => {
                                            let _ = sink.try_send(Update::Working(Some(format!(
                                                "Running {name}"
                                            ))));
                                        }
                                        RunEvent::ToolFinished {
                                            name,
                                            success,
                                            text,
                                        } => {
                                            let _ = sink.try_send(Update::Item(Item::Tool {
                                                verb: "Ran".into(),
                                                description: name,
                                                status: if success {
                                                    Status::Ok
                                                } else {
                                                    Status::Failed
                                                },
                                                duration: None,
                                                detail: (!text.trim().is_empty()).then_some(text),
                                                outcome: (!success).then(|| "failed".to_string()),
                                            }));
                                        }
                                    };
                                    let mut lane = Lane {
                                        name: MAIN_LANE.into(),
                                        storage: &mut storage,
                                        model: model.as_ref(),
                                        tools: &toolbox,
                                    };
                                    match lane
                                        .run_with(&text, Some(rx), &system, &schemas, &events)
                                        .await
                                    {
                                        Ok(report) => {
                                            if report.outcome == crate::records::Outcome::Failed {
                                                Some(Item::Notice(format!(
                                                    "run failed after {} attempts",
                                                    report.attempts
                                                )))
                                            } else if report.outcome
                                                == crate::records::Outcome::Aborted
                                            {
                                                Some(Item::Notice("Interrupted".into()))
                                            } else {
                                                None
                                            }
                                        }
                                        Err(error) => Some(Item::Notice(format!("run: {error}"))),
                                    }
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

/// Run a slash command.
///
/// Built-ins first, then the agent's own Lua tools — so `tools/deploy.lua`
/// really is `/deploy`, with no registration step.
async fn dispatch(project: &Arc<Project>, sandbox: &Arc<Sandbox>, rest: &str) -> Option<Item> {
    let (name, argument) = match rest.split_once(' ') {
        Some((name, argument)) => (name, argument.trim()),
        None => (rest, ""),
    };
    let text = match name {
        "help" => commands_for(project)
            .iter()
            .map(|c| format!("- `/{}` — {}", c.name, c.description))
            .collect::<Vec<_>>()
            .join("\n"),
        "models" => {
            let models = Models::load(&project.root.join("models.yml"));
            match models {
                Ok(models) => {
                    let current = project.runtime.agent.model.clone().unwrap_or_default();
                    models
                        .catalog()
                        .iter()
                        .map(|id| {
                            if *id == current {
                                format!("- **{id}** (current)")
                            } else {
                                format!("- {id}")
                            }
                        })
                        .collect::<Vec<_>>()
                        .join("\n")
                }
                Err(e) => format!("could not read models.yml: {e}"),
            }
        }
        "model" => {
            if argument.is_empty() {
                format!(
                    "Current model: `{}`\n\nPass one to switch: `/model <provider/id>`",
                    project
                        .runtime
                        .agent
                        .model
                        .clone()
                        .unwrap_or_else(|| "none".into())
                )
            } else {
                // Switching for real means rebuilding the client and rewriting
                // agent.lua; neither is wired, so say so rather than appearing
                // to have done it.
                match Models::load(&project.root.join("models.yml"))
                    .and_then(|m| m.resolve(argument).map(|r| r.model.id))
                {
                    Ok(id) => format!(
                        "`{id}` resolves. Switching at runtime is not wired up yet — set it in \
                         `agent.lua` and restart."
                    ),
                    Err(e) => format!("{e}"),
                }
            }
        }
        "sandbox" => sandbox.describe(),
        "skills" => match crate::skills::discover(&project.workspace()) {
            Ok(skills) if skills.is_empty() => "No skills discovered.".to_string(),
            Ok(skills) => skills
                .iter()
                .map(|s| format!("- `{}` — {}", s.name, s.description))
                .collect::<Vec<_>>()
                .join("\n"),
            Err(error) => format!("skills: {error}"),
        },
        "tools" => {
            if project.runtime.tools.is_empty() {
                "No tools. Drop a file into `tools/`.".to_string()
            } else {
                project
                    .runtime
                    .tools
                    .iter()
                    .map(|t| format!("- `/{}` — {}", t.name, t.description))
                    .collect::<Vec<_>>()
                    .join("\n")
            }
        }
        "quit" => return None,
        // Anything else is a tool, or nothing.
        other if project.runtime.tool(other).is_some() => {
            return Some(run_tool(project, sandbox, other).await);
        }
        other => {
            return Some(Item::Notice(format!(
                "no command `/{other}` — press `/` to see what there is"
            )));
        }
    };
    Some(Item::Assistant(text))
}

/// The slash commands, built from what this agent actually has.
///
/// The list is assembled from live state rather than hardcoded, so it cannot
/// offer a tool the agent did not declare or a model it is not configured for.
fn commands_for(project: &Project) -> Vec<Command> {
    let models: Vec<Candidate> = Models::load(&project.root.join("models.yml"))
        .map(|models| {
            models
                .catalog()
                .into_iter()
                .map(|id| Candidate {
                    value: id,
                    detail: String::new(),
                })
                .collect()
        })
        .unwrap_or_default();

    let mut commands = vec![
        Command::new("help", "what these commands do"),
        Command::new("model", "show or switch the model").with_arguments(models),
        Command::new("models", "list the configured models"),
        Command::new("sandbox", "describe the microVM and its egress policy"),
        Command::new("compact", "summarize old conversation context"),
        Command::new("skills", "list workspace skills"),
        Command::new("tools", "list this agent's Lua tools"),
        Command::new("quit", "leave"),
    ];
    // An agent's own tools are commands too; that is the whole point of
    // dropping a file into tools/.
    for tool in &project.runtime.tools {
        commands.push(Command::new(&tool.name, &tool.description));
    }
    commands.sort_by(|a, b| a.name.cmp(&b.name));
    commands
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

/// The system prompt: identity, workspace context, and the live skill catalog.
///
/// Rebuilt each exchange because the agent edits these files inside the
/// workspace — that is the point of them being writable.
fn system_prompt(project: &Project) -> String {
    let mut parts = Vec::new();
    if let Ok(text) = std::fs::read_to_string(project.root.join("instructions.md")) {
        parts.push(text.trim().to_string());
    }
    let workspace = project.workspace();
    for (file, limit) in [
        ("AGENTS.md", usize::MAX),
        ("SOUL.md", usize::MAX),
        ("KNOWLEDGE.md", 100),
    ] {
        if let Ok(text) = std::fs::read_to_string(workspace.join(file)) {
            let body: String = text.lines().take(limit).collect::<Vec<_>>().join("\n");
            if !body.trim().is_empty() {
                parts.push(format!("# {file}\n\n{}", body.trim()));
            }
        }
    }
    if let Ok(skills) = crate::skills::discover(&workspace)
        && !skills.is_empty()
    {
        let catalog = skills
            .iter()
            .map(|skill| format!("- `{}` — {}", skill.name, skill.description))
            .collect::<Vec<_>>()
            .join("\n");
        parts.push(format!("# Available skills\n\n{catalog}"));
    }
    parts.push(
        "You are running inside a microVM. The workspace is mounted at /workspace and is \
         the working directory; paths are relative to it. Every tool runs in that VM."
            .to_string(),
    );
    parts.join("\n\n")
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
