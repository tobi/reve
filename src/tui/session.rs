//! The terminal, wired to the durable harness and a real microVM.
//!
//! This is what bare `reve` runs. Everything the user types either goes to the
//! model — as a durable operation on the `main` lane — or, prefixed with `!`,
//! straight into the agent's microVM. Nothing runs on the host.
//!
//! The worker here does not own the session file. A [`Session`] owner task
//! does, and this task holds a handle. That is what lets a run be a spawned
//! task while the terminal stays responsive: a steer typed mid-run is a
//! *conditional commit* against the running operation, not a message this loop
//! has to be free to receive.

use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use parking_lot::Mutex;
use tokio::sync::mpsc;

use crate::entry::MAIN_LANE;
use crate::events::Kind;
use crate::harness::{Harness, HarnessConfig, HarnessError};
use crate::hooks::Hooks;
use crate::model::{Assistant, BoxFuture, Deltas, Model, ModelError, Request};
use crate::project::Project;
use crate::provider::HttpModel;
use crate::provider::config::Models;
use crate::sandbox::tokio_util_lite::{CancelTx, channel};
use crate::sandbox::{ExecOptions, Sandbox};
use crate::session::Session;
use crate::state::{LaneConfiguration, ModelRef, Outcome, RetryPolicy, RunSettings};
use crate::storage::Storage;
use crate::tools::Toolbox;
use crate::tui::app::{Action, App, Update};
use crate::tui::complete::{Candidate, Command};
use crate::tui::item::{Item, Status};

/// A model that only knows why there is no model.
///
/// Better than refusing to start: the shell escape, the tools, and the
/// transcript all still work, and the first prompt explains itself instead of
/// the whole terminal failing at launch.
struct Unconfigured(String);

impl Model for Unconfigured {
    fn respond<'a>(
        &'a self,
        _request: Request<'a>,
        _on_text: Deltas<'a>,
    ) -> BoxFuture<'a, crate::model::Result<Assistant>> {
        Box::pin(async move { Err(ModelError::terminal(format!("no model: {}", self.0))) })
    }
}

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
    app.set_files(file_candidates(&project.workspace()));

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
            let toolbox = Arc::new(Toolbox::new(sandbox.clone(), project.runtime_arc()));
            let session_path = project
                .latest_session(MAIN_LANE)
                .unwrap_or_else(|| project.conversation_path(MAIN_LANE));
            let storage = match Storage::open(&session_path, "main", Some("workspace".into())) {
                Ok(storage) => storage,
                Err(error) => {
                    let _ = updates
                        .send(Update::Item(Item::Notice(format!("session: {error}"))))
                        .await;
                    return;
                }
            };
            // The owner task is the single writer; everything below holds a
            // handle and commits through it.
            let session = Session::spawn(storage);
            let model: Arc<dyn Model> = match model {
                Ok(model) => model,
                Err(why) => Arc::new(Unconfigured(why)),
            };
            let harness = Harness::new(
                session.clone(),
                HarnessConfig {
                    model,
                    tools: toolbox,
                    hooks: Hooks::new(),
                    system_prompt: {
                        let project = project.clone();
                        // Rebuilt per turn: the agent edits these files.
                        Arc::new(move || system_prompt(&project))
                    },
                    settings: RunSettings::default(),
                    retry: RetryPolicy::default(),
                    configuration: LaneConfiguration {
                        model: ModelRef {
                            provider: project
                                .runtime
                                .agent
                                .model
                                .clone()
                                .unwrap_or_else(|| "none".into()),
                            model_id: project
                                .runtime
                                .agent
                                .model
                                .clone()
                                .unwrap_or_else(|| "none".into()),
                        },
                        thinking_level: project
                            .runtime
                            .agent
                            .thinking
                            .clone()
                            .unwrap_or_else(|| "default".into()),
                        active_tool_names: tools.clone(),
                    },
                    event_capacity: 1024,
                },
            );

            let events = tokio::spawn(forward_events(harness.subscribe(), updates.clone()));

            // Whatever the last process was doing, finish it before taking
            // anything new. This is the only place resume is called, and it is
            // called before the first prompt can claim the lane.
            match harness.resume_all().await {
                Ok(results) if !results.is_empty() => {
                    let _ = updates
                        .send(Update::Item(Item::Notice(format!(
                            "resumed {} interrupted operation(s) from the last session",
                            results.len()
                        ))))
                        .await;
                }
                Ok(_) => {}
                Err(error) => {
                    let _ = updates
                        .send(Update::Item(Item::Notice(format!("resume: {error}"))))
                        .await;
                }
            }

            // Side commands (`!`, `/tool`) are not durable operations, so they
            // keep their own cancellation.
            let side_cancel: Arc<Mutex<Option<CancelTx>>> = Arc::new(Mutex::new(None));
            let (finished, mut finished_rx) = mpsc::channel::<()>(8);
            let mut running = 0usize;

            loop {
                let action = tokio::select! {
                    action = actions_rx.recv() => match action {
                        Some(action) => action,
                        None => break,
                    },
                    Some(()) = finished_rx.recv() => {
                        running = running.saturating_sub(1);
                        if running == 0 {
                            let _ = updates
                                .send(Update::Files(file_candidates(&project.workspace())))
                                .await;
                        }
                        continue;
                    }
                };
                match action {
                    Action::Prompt(text)
                    | Action::Steer(text)
                    | Action::FollowUp(text)
                    | Action::ChannelMessage(crate::channels::Message { text, .. })
                        if text.trim().starts_with('!') =>
                    {
                        let (tx, rx) = channel();
                        *side_cancel.lock() = Some(tx);
                        let _ = updates.send(Update::Item(Item::User(text.clone()))).await;
                        let item = run_command(&sandbox, text.trim()[1..].trim(), rx).await;
                        side_cancel.lock().take();
                        let _ = updates.send(Update::Item(item)).await;
                    }
                    Action::Prompt(text)
                    | Action::Steer(text)
                    | Action::FollowUp(text)
                    | Action::ChannelMessage(crate::channels::Message { text, .. })
                        if text.trim().starts_with('/') =>
                    {
                        let (tx, rx) = channel();
                        *side_cancel.lock() = Some(tx);
                        let _ = updates.send(Update::Item(Item::User(text.clone()))).await;
                        let rest = text.trim()[1..].to_string();
                        let item = if let Some(argument) = rest.strip_prefix("compact") {
                            Some(compact(&harness, argument.trim()).await)
                        } else if let Some(argument) = rest.strip_prefix("queue") {
                            Some(queue(&harness, argument.trim()).await)
                        } else {
                            dispatch(&project, &sandbox, &rest, rx).await
                        };
                        side_cancel.lock().take();
                        if let Some(item) = item {
                            let _ = updates.send(Update::Item(item)).await;
                        }
                    }
                    action @ (Action::Prompt(_)
                    | Action::Steer(_)
                    | Action::FollowUp(_)
                    | Action::ChannelMessage(_)) => {
                        let (text, echo) = match action {
                            Action::Prompt(text) | Action::Steer(text) | Action::FollowUp(text) => {
                                (text, true)
                            }
                            Action::ChannelMessage(message) => (channel_prompt(&message), false),
                            _ => unreachable!(),
                        };
                        if echo {
                            let _ = updates.send(Update::Item(Item::User(text.clone()))).await;
                        }
                        // A prompt while the lane is busy is a steer. The
                        // harness decides that, not this loop: it commits
                        // against the operation it read, so the race between
                        // "the run just ended" and "the user just typed"
                        // resolves in the store.
                        match harness.steer(MAIN_LANE, &text).await {
                            Ok(_) => continue,
                            Err(HarnessError::Idle(_)) => {}
                            Err(error) => {
                                let _ = updates
                                    .send(Update::Item(Item::Notice(format!("steer: {error}"))))
                                    .await;
                                continue;
                            }
                        }
                        running += 1;
                        let harness = harness.clone();
                        let updates = updates.clone();
                        let finished = finished.clone();
                        tokio::spawn(async move {
                            if let Err(error) = harness.prompt(MAIN_LANE, &text).await {
                                let _ = updates
                                    .send(Update::Item(Item::Notice(format!("run: {error}"))))
                                    .await;
                            }
                            let _ = finished.send(()).await;
                        });
                    }
                    Action::Interrupt => {
                        // Both, in this order: the durable request is what
                        // makes the operation end aborted even if we die now.
                        if let Err(error) = harness.abort(MAIN_LANE).await
                            && !matches!(error, HarnessError::Idle(_))
                        {
                            let _ = updates
                                .send(Update::Item(Item::Notice(format!("interrupt: {error}"))))
                                .await;
                        }
                        if let Some(cancel) = side_cancel.lock().as_ref() {
                            cancel.cancel();
                        }
                    }
                    Action::Quit => break,
                }
            }
            events.abort();
            session.close().await;
        })
    };

    let result = crate::tui::run::run(app, updates_rx, actions).await;
    worker.abort();
    result.map_err(Into::into)
}

/// Turn the harness's passive event stream into terminal updates.
///
/// One-way by construction: an observer cannot change what the run does, so a
/// slow or wedged terminal can never stall or alter an operation.
async fn forward_events(
    mut events: tokio::sync::broadcast::Receiver<crate::events::Event>,
    updates: mpsc::Sender<Update>,
) {
    loop {
        let event = match events.recv().await {
            Ok(event) => event,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(_) => break,
        };
        // The event stream is the only authority on whether an operation is
        // running, so it is the only thing allowed to raise or clear the
        // working indicator. The action loop used to do its own bookkeeping,
        // which meant a run it did not start -- a resume at launch, a queued
        // next run -- left the spinner on forever, and a stuck spinner turns
        // ctrl-c into an interrupt that never becomes a quit.
        let update = match event.kind {
            Kind::RunStart | Kind::RunResume { .. } => {
                Some(Update::Working(Some("Working".into())))
            }
            Kind::MessageUpdate { delta } => Some(Update::Delta(delta)),
            Kind::MessageEnd { .. } => Some(Update::EndMessage),
            Kind::ToolStart { tool_name, .. } => {
                Some(Update::Working(Some(format!("Running {tool_name}"))))
            }
            Kind::ToolEnd {
                tool_name,
                content,
                is_error,
                ..
            } => Some(Update::Item(Item::Tool {
                verb: "Ran".into(),
                description: tool_name,
                status: if is_error { Status::Failed } else { Status::Ok },
                duration: None,
                detail: (!content.trim().is_empty()).then(|| content.trim().to_string()),
                outcome: is_error.then(|| "failed".to_string()),
            })),
            Kind::RetryScheduled {
                attempt,
                max_attempts,
                ..
            } => Some(Update::Working(Some(format!(
                "Retrying ({attempt}/{max_attempts})"
            )))),
            Kind::RunEnd { outcome, error, .. } => {
                // The run is over however it ended, so the indicator goes down
                // before the notice explaining why.
                let _ = updates.send(Update::Working(None)).await;
                match outcome {
                    Outcome::Failed => Some(Update::Item(Item::Notice(match error {
                        Some(error) => format!("run failed: {}", error.message),
                        None => "run failed".into(),
                    }))),
                    Outcome::Aborted => Some(Update::Item(Item::Notice("Interrupted".into()))),
                    _ => None,
                }
            }
            Kind::CompactionStart { .. } => Some(Update::Working(Some("Compacting".into()))),
            Kind::CompactionEnd { outcome, .. } => {
                let _ = updates.send(Update::Working(None)).await;
                match outcome {
                    Outcome::Completed => Some(Update::Item(Item::Notice(
                        "compacted the conversation".into(),
                    ))),
                    Outcome::Failed => Some(Update::Item(Item::Notice("compaction failed".into()))),
                    _ => None,
                }
            }
            Kind::HandlerError { hook, error } => {
                Some(Update::Item(Item::Notice(format!("{hook}: {error}"))))
            }
            Kind::Fault { message } => Some(Update::Item(Item::Notice(format!(
                "session fault: {message}"
            )))),
            _ => None,
        };
        if let Some(update) = update
            && updates.send(update).await.is_err()
        {
            break;
        }
    }
}

/// `/compact` as its own durable operation.
async fn compact(harness: &Arc<Harness>, instructions: &str) -> Item {
    let custom = (!instructions.is_empty()).then(|| instructions.to_string());
    match harness.compact(MAIN_LANE, custom).await {
        Ok(result) if result.outcome == Outcome::Completed => Item::Assistant("Compacted.".into()),
        Ok(result) => Item::Notice(format!("compaction {}", result.outcome.as_str())),
        Err(error) => Item::Notice(format!("compact: {error}")),
    }
}

/// `/queue` — a prompt for the next run, durable the moment it is accepted.
async fn queue(harness: &Arc<Harness>, text: &str) -> Item {
    if text.is_empty() {
        return Item::Notice("say what to queue: `/queue <message>`".into());
    }
    match harness.next_run(MAIN_LANE, text).await {
        Ok(_) => Item::Assistant("Queued for the next run.".into()),
        Err(error) => Item::Notice(format!("queue: {error}")),
    }
}

/// The `!` escape: a command, in the microVM, right now.
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
async fn dispatch(
    project: &Arc<Project>,
    sandbox: &Arc<Sandbox>,
    rest: &str,
    cancel: crate::sandbox::tokio_util_lite::CancelRx,
) -> Option<Item> {
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
            return Some(run_tool(project, sandbox, other, cancel).await);
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
        Command::new("queue", "send a message after the current run"),
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

const MAX_FILE_CANDIDATES: usize = 5_000;

fn file_candidates(root: &Path) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    collect_files(root, root, &mut candidates, 0);
    candidates.sort_by(|a, b| a.value.cmp(&b.value));
    candidates
}

fn collect_files(root: &Path, directory: &Path, out: &mut Vec<Candidate>, depth: usize) {
    if out.len() >= MAX_FILE_CANDIDATES || depth >= 64 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    let mut entries = entries.flatten().collect::<Vec<_>>();
    entries.sort_by_key(std::fs::DirEntry::file_name);

    for entry in entries {
        if out.len() >= MAX_FILE_CANDIDATES {
            break;
        }
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            collect_files(root, &entry.path(), out, depth + 1);
        } else if kind.is_file() {
            let path = entry.path();
            let Ok(relative) = path.strip_prefix(root) else {
                continue;
            };
            let bytes = entry.metadata().map(|metadata| metadata.len()).unwrap_or(0);
            out.push(Candidate {
                value: format!("@{}", relative.to_string_lossy()),
                detail: file_size(bytes),
            });
        }
    }
}

fn file_size(bytes: u64) -> String {
    if bytes < 1_024 {
        format!("{bytes} B")
    } else if bytes < 1_048_576 {
        format!("{:.1} KB", bytes as f64 / 1_024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / 1_048_576.0)
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
    parts.push(environment_prompt(&project.runtime.policy));
    parts.join("\n\n")
}

fn environment_prompt(policy: &crate::sandbox::Policy) -> String {
    let hosts = policy.egress_hosts();
    let internet = if hosts.is_empty() {
        "You have no internet access.".to_string()
    } else {
        format!("You have internet access to {}.", hosts.join(", "))
    };
    format!(
        "<env>\n\
         You are running inside a microVM. The workspace is mounted at /workspace and is the \
         working directory; paths are relative to it. Every tool runs in that VM.\n\
         mise is installed. Use it to install missing language runtimes and development tools.\n\
         {internet}\n\
         </env>"
    )
}

fn channel_prompt(message: &crate::channels::Message) -> String {
    format!(
        "<message channel=\"{}\" timestamp=\"{}\">\n{}\n</message>",
        escape_xml(&message.channel, true),
        message.timestamp,
        escape_xml(&message.text, false)
    )
}

fn escape_xml(text: &str, attribute: bool) -> String {
    let extra = text
        .bytes()
        .filter(|byte| matches!(byte, b'&' | b'<' | b'>' | b'"'))
        .count()
        * 4;
    let mut escaped = String::with_capacity(text.len() + extra);
    for ch in text.chars() {
        match ch {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' if attribute => escaped.push_str("&quot;"),
            _ => escaped.push(ch),
        }
    }
    escaped
}

async fn run_tool(
    project: &Project,
    sandbox: &Arc<Sandbox>,
    name: &str,
    cancel: crate::sandbox::tokio_util_lite::CancelRx,
) -> Item {
    let started = Instant::now();
    let result = project
        .runtime
        .call_tool_cancelled(
            name,
            serde_json::Map::new(),
            sandbox.clone(),
            Some(cancel.clone()),
        )
        .await;
    let interrupted = cancel.is_cancelled();
    match result {
        Ok(text) => Item::Tool {
            verb: "Ran tool".into(),
            description: name.to_string(),
            status: if interrupted {
                Status::Failed
            } else {
                Status::Ok
            },
            duration: Some(started.elapsed()),
            detail: (!text.trim().is_empty()).then(|| text.trim().to_string()),
            outcome: interrupted.then(|| "interrupted".to_string()),
        },
        Err(e) => Item::Tool {
            verb: "Ran tool".into(),
            description: name.to_string(),
            status: Status::Failed,
            duration: Some(started.elapsed()),
            detail: None,
            outcome: Some(if interrupted {
                "interrupted".to_string()
            } else {
                e.to_string()
            }),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_messages_carry_source_and_timestamp_metadata() {
        let prompt = channel_prompt(&crate::channels::Message {
            channel: "telegram&alerts".into(),
            text: "<ship & \"go\">".into(),
            timestamp: 13,
        });
        assert_eq!(
            prompt,
            "<message channel=\"telegram&amp;alerts\" timestamp=\"13\">\n\
             &lt;ship &amp; \"go\"&gt;\n\
             </message>"
        );
    }

    #[test]
    fn environment_prompt_names_mise_and_the_exact_egress_hosts() {
        let policy = crate::sandbox::Policy {
            allow_hosts: vec![
                "registry.npmjs.org".into(),
                "github.com".into(),
                "github.com".into(),
            ],
            ..Default::default()
        };
        let prompt = environment_prompt(&policy);

        assert!(prompt.starts_with("<env>\n"));
        assert!(prompt.ends_with("\n</env>"));
        assert!(prompt.contains("mise is installed"));
        assert!(prompt.contains("You have internet access to github.com, registry.npmjs.org."));
    }

    #[test]
    fn environment_prompt_says_when_egress_is_disabled() {
        let prompt = environment_prompt(&crate::sandbox::Policy::default());
        assert!(prompt.contains("You have no internet access."));
    }

    #[test]
    fn workspace_file_candidates_are_relative_sorted_and_private() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("knowledge")).unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::write(dir.path().join("z.txt"), "z").unwrap();
        std::fs::write(dir.path().join("knowledge/a.md"), "hello").unwrap();
        std::fs::write(dir.path().join(".git/config"), "secret").unwrap();

        let candidates = file_candidates(dir.path());
        assert_eq!(
            candidates
                .iter()
                .map(|candidate| candidate.value.as_str())
                .collect::<Vec<_>>(),
            vec!["@knowledge/a.md", "@z.txt"]
        );
        assert_eq!(candidates[0].detail, "5 B");
    }
}
