//! The agent directory.
//!
//! An agent is a directory, and the files in it are its definition. There is no
//! machine-wide profile, no home-directory config, and no global session store:
//! copy the directory and you copy the agent.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use thiserror::Error;

use crate::lua::Runtime;

#[derive(Debug, Error)]
pub enum ProjectError {
    #[error(
        "not an agent directory: {0}\n\n  an agent needs at least one of:\n    instructions.md   what the agent is and how it works\n    agent.lua         its configuration (model, tools, sandbox)\n\n  run `leve init` to scaffold one here"
    )]
    NotAnAgent(PathBuf),
    #[error("io error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error(transparent)]
    Lua(#[from] crate::lua::LuaError),
}

pub type Result<T, E = ProjectError> = std::result::Result<T, E>;

/// The files `leve init` writes. Kept as one table so `init` is idempotent and
/// can report created / unchanged / changed-and-kept per file.
const TEMPLATES: &[(&str, &str)] = &[
    ("agent.lua", include_str!("templates/agent.lua")),
    ("sandbox.lua", include_str!("templates/sandbox.lua")),
    (
        "tools/example.lua",
        include_str!("templates/example_tool.lua"),
    ),
    ("instructions.md", include_str!("templates/instructions.md")),
    ("models.yml", include_str!("templates/models.yml")),
    ("workspace/AGENTS.md", include_str!("templates/AGENTS.md")),
    ("workspace/SOUL.md", include_str!("templates/SOUL.md")),
    (
        "workspace/KNOWLEDGE.md",
        include_str!("templates/KNOWLEDGE.md"),
    ),
    (
        "workspace/HEARTBEAT.yml",
        include_str!("templates/HEARTBEAT.yml"),
    ),
    (".gitignore", include_str!("templates/gitignore")),
];

const KEEP_DIRS: &[&str] = &[
    "tools",
    "channels",
    "workspace/knowledge",
    "workspace/notes",
    "workspace/skills",
];

#[derive(Debug, Default)]
pub struct InitReport {
    pub root: PathBuf,
    pub created: Vec<String>,
    pub unchanged: Vec<String>,
    /// Present but different from the current template. Left alone.
    pub changed: Vec<String>,
}

/// Create (or top up) an agent directory. Idempotent, and it never writes
/// outside `root`.
pub fn init(root: impl AsRef<Path>) -> Result<InitReport> {
    let root = root.as_ref().to_path_buf();
    let mut report = InitReport {
        root: root.clone(),
        ..Default::default()
    };

    for dir in KEEP_DIRS {
        let path = root.join(dir);
        std::fs::create_dir_all(&path).map_err(|source| ProjectError::Io { path, source })?;
    }
    // `.leve` is durable state, not scaffold; it is created on first launch.
    for (name, body) in TEMPLATES {
        let path = root.join(name);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|source| ProjectError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        match std::fs::read_to_string(&path) {
            Ok(existing) if existing == *body => report.unchanged.push(name.to_string()),
            Ok(_) => report.changed.push(name.to_string()),
            Err(_) => {
                std::fs::write(&path, body).map_err(|source| ProjectError::Io {
                    path: path.clone(),
                    source,
                })?;
                report.created.push(name.to_string());
            }
        }
    }
    Ok(report)
}

/// A loaded agent directory.
pub struct Project {
    pub root: PathBuf,
    /// Shared, because tool calls need it alongside the sandbox and a Lua VM
    /// cannot be cloned.
    pub runtime: Arc<Runtime>,
}

impl Project {
    /// Is this a directory leve is willing to run?
    ///
    /// The check exists so an agent cannot silently attach itself to an
    /// arbitrary checkout and start acting like it belongs there.
    pub fn is_agent_dir(root: &Path) -> bool {
        root.join("agent.lua").is_file() || root.join("instructions.md").is_file()
    }

    pub fn load(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref().to_path_buf();
        if !Self::is_agent_dir(&root) {
            return Err(ProjectError::NotAnAgent(root));
        }
        let mut runtime = Runtime::new()?;
        runtime.load_agent(&root.join("agent.lua"))?;
        runtime.load_sandbox(&root.join("sandbox.lua"))?;
        runtime.load_tools(&root.join("tools"))?;
        Ok(Self {
            root,
            runtime: Arc::new(runtime),
        })
    }

    pub fn runtime_arc(&self) -> Arc<Runtime> {
        self.runtime.clone()
    }

    pub fn workspace(&self) -> PathBuf {
        self.root.join("workspace")
    }

    pub fn state_dir(&self) -> PathBuf {
        self.root.join(".leve")
    }

    pub fn sessions_dir(&self) -> PathBuf {
        self.state_dir().join("sessions")
    }

    /// The durable session file for a named conversation.
    pub fn conversation_path(&self, name: &str) -> PathBuf {
        let stamp = chrono::Utc::now().format("%Y%m%dT%H%M%S%.6f");
        self.sessions_dir().join(format!("{name}-{stamp}.jsonl"))
    }

    /// The newest existing session for a conversation, if there is one.
    pub fn latest_session(&self, name: &str) -> Option<PathBuf> {
        let mut found: Vec<PathBuf> = std::fs::read_dir(self.sessions_dir())
            .ok()?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                p.extension().is_some_and(|e| e == "jsonl")
                    && p.file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with(&format!("{name}-")))
            })
            .collect();
        found.sort();
        found.pop()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_scaffolds_a_directory_that_loads() {
        let dir = tempfile::tempdir().unwrap();
        let report = init(dir.path()).unwrap();
        assert!(report.created.contains(&"agent.lua".to_string()));
        assert!(report.created.contains(&"sandbox.lua".to_string()));
        assert!(report.changed.is_empty());

        // The scaffold must actually be a runnable agent, not just files.
        let project = Project::load(dir.path()).expect("the scaffold loads");
        assert!(
            project.runtime.agent.model.is_some(),
            "agent.lua sets a model"
        );
        assert!(
            project.runtime.tool("example").is_some(),
            "the example tool registered"
        );
        assert!(
            project.runtime.policy.mount_workspace,
            "workspace is mounted"
        );
    }

    #[test]
    fn init_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path()).unwrap();
        let second = init(dir.path()).unwrap();
        assert!(second.created.is_empty(), "nothing is rewritten");
        assert!(!second.unchanged.is_empty());
    }

    #[test]
    fn init_never_clobbers_an_edited_file() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path()).unwrap();
        std::fs::write(dir.path().join("agent.lua"), "-- mine\n").unwrap();
        let report = init(dir.path()).unwrap();
        assert!(report.changed.contains(&"agent.lua".to_string()));
        assert_eq!(
            std::fs::read_to_string(dir.path().join("agent.lua")).unwrap(),
            "-- mine\n"
        );
    }

    #[test]
    fn an_arbitrary_checkout_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("README.md"), "someone else's project").unwrap();
        assert!(!Project::is_agent_dir(dir.path()));
        let err = match Project::load(dir.path()) {
            Err(err) => err,
            Ok(_) => panic!("an arbitrary checkout must not load as an agent"),
        };
        assert!(
            err.to_string().contains("not an agent directory"),
            "got {err}"
        );
        assert!(
            err.to_string().contains("leve init"),
            "and it says how to fix that"
        );
    }

    #[test]
    fn durable_paths_stay_under_the_agent_root() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path()).unwrap();
        let project = Project::load(dir.path()).unwrap();
        assert!(project.sessions_dir().starts_with(dir.path()));
        assert!(
            project
                .conversation_path("main")
                .starts_with(project.sessions_dir())
        );
        assert!(project.workspace().starts_with(dir.path()));
    }
}
