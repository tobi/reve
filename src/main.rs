//! The `reve` command.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use clap::{Parser, Subcommand};
use reve::progress::Spinner;
use reve::project::{self, Project};
use reve::sandbox::{ExecOptions, Sandbox};

#[derive(Parser)]
#[command(
    name = "reve",
    version,
    about = "A durable coding agent: Rust core, Lua scripting, mandatory microVM"
)]
struct Cli {
    /// Omitted: open the terminal for the agent in this directory.
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Scaffold an agent directory.
    Init {
        /// Where to create it (default: here).
        dir: Option<PathBuf>,
    },
    /// Run a command inside this agent's microVM.
    Exec {
        /// The command, as it would be typed in a shell.
        command: Vec<String>,
    },
    /// Run one of this agent's Lua tools.
    Tool {
        /// The tool name, as declared by `tool("name", ...)`.
        name: Option<String>,
        /// Arguments, as a JSON object.
        #[arg(long, default_value = "{}")]
        args: String,
    },
    /// Show what this agent is configured to do.
    Info,
}

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(code) => code,
        Err(e) => {
            eprintln!("\x1b[31mreve:\x1b[0m {e}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> anyhow::Result<ExitCode> {
    let cli = Cli::parse();
    let Some(command) = cli.command else {
        // Boot once to fail closed, then release the cheap persisted VM until
        // the first sandbox effect. This lets idle TUI sessions coexist.
        let project = Project::load(std::env::current_dir()?)?;
        let sandbox = start_sandbox(&project).await?;
        sandbox.stop().await?;
        let result = reve::tui::session::run(project, sandbox.clone()).await;
        let stopped = sandbox.stop().await;
        result?;
        stopped?;
        return Ok(ExitCode::SUCCESS);
    };
    match command {
        Command::Init { dir } => {
            let root = dir.unwrap_or(std::env::current_dir()?);
            let report = project::init(&root)?;
            println!("\x1b[1minitialised {}\x1b[0m", report.root.display());
            for name in &report.created {
                println!("  \x1b[32m+\x1b[0m {name}");
            }
            for name in &report.unchanged {
                println!("  \x1b[2m· {name} (unchanged)\x1b[0m");
            }
            for name in &report.changed {
                println!("  \x1b[2m· {name} (edited; kept)\x1b[0m");
            }
            println!();
            println!("  edit \x1b[1minstructions.md\x1b[0m, then run \x1b[1mreve\x1b[0m here");
            Ok(ExitCode::SUCCESS)
        }

        Command::Info => {
            let project = Project::load(std::env::current_dir()?)?;
            let agent = &project.runtime.agent;
            println!("root      {}", project.root.display());
            println!("model     {}", agent.model.as_deref().unwrap_or("(unset)"));
            println!(
                "thinking  {}",
                agent.thinking.as_deref().unwrap_or("(default)")
            );
            println!(
                "sandbox   {} ({} cpu, {}MB)",
                project.runtime.policy.image,
                project.runtime.policy.cpus,
                project.runtime.policy.memory
            );
            println!(
                "egress    {}",
                project.runtime.policy.egress_hosts().join(", ")
            );
            println!("tools     {}", tool_names(&project).join(", "));
            Ok(ExitCode::SUCCESS)
        }

        Command::Exec { command } => {
            if command.is_empty() {
                anyhow::bail!("nothing to run");
            }
            let (project, sandbox) = boot().await?;
            let _ = &project;
            let output = sandbox
                .exec(&command.join(" "), ExecOptions::default(), None)
                .await?;
            print!("{}", output.stdout);
            eprint!("{}", output.stderr);
            sandbox.stop().await?;
            Ok(if output.success {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            })
        }

        Command::Tool { name, args } => {
            let project = Project::load(std::env::current_dir()?)?;
            let Some(name) = name else {
                for tool in &project.runtime.tools {
                    println!("{:<20} {}", tool.name, tool.description);
                }
                return Ok(ExitCode::SUCCESS);
            };
            let parsed: serde_json::Value = serde_json::from_str(&args)?;
            let object = parsed
                .as_object()
                .ok_or_else(|| anyhow::anyhow!("--args must be a JSON object"))?
                .clone();

            let sandbox = start_sandbox(&project).await?;
            let result = project
                .runtime
                .call_tool(&name, object, sandbox.clone())
                .await;
            sandbox.stop().await?;
            println!("{}", result?);
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn tool_names(project: &Project) -> Vec<String> {
    let mut names: Vec<String> = project
        .runtime
        .tools
        .iter()
        .map(|t| t.name.clone())
        .collect();
    if names.is_empty() {
        names.push("(none)".into());
    }
    names
}

async fn boot() -> anyhow::Result<(Project, Arc<Sandbox>)> {
    let project = Project::load(std::env::current_dir()?)?;
    let sandbox = start_sandbox(&project).await?;
    Ok((project, sandbox))
}

async fn start_sandbox(project: &Project) -> anyhow::Result<Arc<Sandbox>> {
    let sandbox = Sandbox::start(
        project.runtime.policy.clone(),
        project.workspace(),
        project.state_dir(),
        &Spinner::new(),
    )
    .await?;
    Ok(Arc::new(sandbox))
}
