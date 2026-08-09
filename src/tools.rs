//! The tools a model is given.
//!
//! Seven built-ins plus whatever the agent declared in Lua. Every one of them
//! executes **inside the microVM** — there is no host path here, and paths are
//! resolved against the guest's `/workspace`, which is the bind mount of the
//! agent's own `workspace/`.
//!
//! Replay safety is declared per tool and is what recovery consults: a tool
//! that only reads may be re-run after a crash, one that writes may not.

use std::sync::Arc;

use serde_json::{Map, Value, json};

use crate::lane::Tools as LaneTools;
use crate::lua::Runtime;
use crate::model::{BoxFuture, ToolSchema};
use crate::records::Replay;
use crate::sandbox::{ExecOptions, Sandbox};

/// A built-in, and whether recovery may re-run it.
struct Builtin {
    name: &'static str,
    description: &'static str,
    replay: Replay,
    schema: fn() -> Value,
}

fn object(properties: Value, required: &[&str]) -> Value {
    json!({
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": false,
    })
}

const BUILTINS: &[Builtin] = &[
    Builtin {
        name: "bash",
        description: "Run a shell command in the workspace. Runs inside the agent's microVM.",
        replay: Replay::Never,
        schema: || {
            object(
                json!({
                    "command": {"type": "string", "description": "The command to run"},
                    "timeout_seconds": {"type": "integer", "description": "Give up after this long (default 120)"},
                }),
                &["command"],
            )
        },
    },
    Builtin {
        name: "read",
        description: "Read a file. Paths are relative to the workspace.",
        replay: Replay::Safe,
        schema: || {
            object(
                json!({
                    "path": {"type": "string"},
                    "offset": {"type": "integer", "description": "First line, 1-based"},
                    "limit": {"type": "integer", "description": "How many lines"},
                }),
                &["path"],
            )
        },
    },
    Builtin {
        name: "write",
        description: "Create or overwrite a file.",
        replay: Replay::Never,
        schema: || {
            object(
                json!({"path": {"type": "string"}, "content": {"type": "string"}}),
                &["path", "content"],
            )
        },
    },
    Builtin {
        name: "edit",
        description: "Replace an exact string in a file. The old text must appear exactly once.",
        replay: Replay::Never,
        schema: || {
            object(
                json!({
                    "path": {"type": "string"},
                    "old": {"type": "string", "description": "Exact text to replace"},
                    "new": {"type": "string", "description": "What to replace it with"},
                }),
                &["path", "old", "new"],
            )
        },
    },
    Builtin {
        name: "ls",
        description: "List a directory.",
        replay: Replay::Safe,
        schema: || object(json!({"path": {"type": "string"}}), &[]),
    },
    Builtin {
        name: "glob",
        description: "Find files matching a glob pattern.",
        replay: Replay::Safe,
        schema: || object(json!({"pattern": {"type": "string"}}), &["pattern"]),
    },
    Builtin {
        name: "grep",
        description: "Search file contents with a regular expression.",
        replay: Replay::Safe,
        schema: || {
            object(
                json!({
                    "pattern": {"type": "string"},
                    "path": {"type": "string", "description": "Where to search (default: the workspace)"},
                }),
                &["pattern"],
            )
        },
    },
];

/// Output longer than this is truncated in the model's view. A tool that dumps
/// a whole repository into the context window costs money and crowds out the
/// conversation; the file is still there to read a piece of.
const MAX_OUTPUT: usize = 24_000;

pub struct Toolbox {
    sandbox: Arc<Sandbox>,
    runtime: Arc<Runtime>,
}

impl Toolbox {
    pub fn new(sandbox: Arc<Sandbox>, runtime: Arc<Runtime>) -> Self {
        Self { sandbox, runtime }
    }

    /// Everything the model may call: built-ins first, then this agent's own.
    pub fn schemas(&self) -> Vec<ToolSchema> {
        let mut schemas: Vec<ToolSchema> = BUILTINS
            .iter()
            .map(|b| ToolSchema {
                name: b.name.to_string(),
                description: b.description.to_string(),
                schema: (b.schema)(),
            })
            .collect();
        for tool in &self.runtime.tools {
            // A Lua tool with a built-in's name would be ambiguous, so the
            // agent's own definition wins and replaces it.
            schemas.retain(|s| s.name != tool.name);
            schemas.push(ToolSchema {
                name: tool.name.clone(),
                description: tool.description.clone(),
                schema: tool.schema(),
            });
        }
        schemas
    }

    pub fn replay_of(&self, name: &str) -> Replay {
        if let Some(tool) = self.runtime.tool(name) {
            return tool.replay;
        }
        BUILTINS
            .iter()
            .find(|b| b.name == name)
            .map(|b| b.replay)
            .unwrap_or(Replay::Never)
    }

    /// Run a tool. `Err` is a tool failure the model gets to read, not a fault.
    pub async fn call(&self, name: &str, args: Map<String, Value>) -> Result<String, String> {
        // The agent's own tools take precedence.
        if self.runtime.tool(name).is_some() {
            return self
                .runtime
                .call_tool(name, args, self.sandbox.clone())
                .await
                .map(|text| truncate(&text))
                .map_err(|e| e.to_string());
        }
        let text = match name {
            "bash" => {
                let command = string(&args, "command")?;
                let timeout = args
                    .get("timeout_seconds")
                    .and_then(Value::as_u64)
                    .unwrap_or(120);
                let out = self
                    .sandbox
                    .exec(
                        &command,
                        ExecOptions {
                            timeout: Some(std::time::Duration::from_secs(timeout)),
                            ..Default::default()
                        },
                        None,
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                // The exit code is part of the answer, not an error.
                let mut text = String::new();
                text.push_str(out.stdout.trim_end());
                if !out.stderr.trim().is_empty() {
                    if !text.is_empty() {
                        text.push('\n');
                    }
                    text.push_str(out.stderr.trim_end());
                }
                if !out.success {
                    text.push_str(&format!("\n(exit {})", out.exit_code));
                }
                text
            }
            "read" => {
                let path = string(&args, "path")?;
                let content = self
                    .sandbox
                    .read_file(&path)
                    .await
                    .map_err(|e| e.to_string())?;
                let offset = args
                    .get("offset")
                    .and_then(Value::as_u64)
                    .unwrap_or(1)
                    .max(1) as usize;
                let limit = args
                    .get("limit")
                    .and_then(Value::as_u64)
                    .unwrap_or(u64::MAX) as usize;
                // Numbered, because the next thing asked is usually "edit line N".
                content
                    .lines()
                    .enumerate()
                    .skip(offset - 1)
                    .take(limit)
                    // Spaces, not a tab: a tab in a gutter lands wherever the
                    // terminal's tab stops happen to be.
                    .map(|(i, line)| format!("{:>5}  {line}", i + 1))
                    .collect::<Vec<_>>()
                    .join("\n")
            }
            "write" => {
                let path = string(&args, "path")?;
                let content = string(&args, "content")?;
                self.sandbox
                    .write_file(&path, &content)
                    .await
                    .map_err(|e| e.to_string())?;
                format!("wrote {} bytes to {path}", content.len())
            }
            "edit" => {
                let path = string(&args, "path")?;
                let old = string(&args, "old")?;
                let new = string(&args, "new")?;
                let content = self
                    .sandbox
                    .read_file(&path)
                    .await
                    .map_err(|e| e.to_string())?;
                let replaced = replace_once(&content, &old, &new)?;
                self.sandbox
                    .write_file(&path, &replaced)
                    .await
                    .map_err(|e| e.to_string())?;
                format!("edited {path}")
            }
            "ls" => {
                let path = args.get("path").and_then(Value::as_str).unwrap_or(".");
                self.shell(&format!("ls -la {}", quote(path))).await?
            }
            "glob" => {
                let pattern = string(&args, "pattern")?;
                // fd is provisioned; the find fallback keeps a bare image usable.
                self.shell(&format!(
                    "fd --hidden --glob {p} 2>/dev/null || find . -name {p} 2>/dev/null",
                    p = quote(&pattern)
                ))
                .await?
            }
            "grep" => {
                let pattern = string(&args, "pattern")?;
                let path = args.get("path").and_then(Value::as_str).unwrap_or(".");
                self.shell(&format!(
                    "rg -n --no-heading {} {} 2>/dev/null || grep -rn {} {} 2>/dev/null",
                    quote(&pattern),
                    quote(path),
                    quote(&pattern),
                    quote(path)
                ))
                .await?
            }
            other => return Err(format!("no tool named {other:?}")),
        };
        Ok(truncate(&text))
    }

    async fn shell(&self, command: &str) -> Result<String, String> {
        let out = self
            .sandbox
            .exec(command, ExecOptions::default(), None)
            .await
            .map_err(|e| e.to_string())?;
        let text = if out.stdout.trim().is_empty() {
            out.stderr
        } else {
            out.stdout
        };
        Ok(text.trim_end().to_string())
    }
}

impl LaneTools for Toolbox {
    fn replay(&self, name: &str) -> Replay {
        self.replay_of(name)
    }

    fn invoke<'a>(
        &'a self,
        name: &'a str,
        arguments: Map<String, Value>,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(self.call(name, arguments))
    }
}

fn string(args: &Map<String, Value>, key: &str) -> Result<String, String> {
    args.get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| format!("missing required argument {key:?}"))
}

fn quote(text: &str) -> String {
    shell_words::quote(text).into_owned()
}

/// Replace exactly one occurrence, or say why not.
///
/// Refusing an ambiguous edit is the whole value of this tool: replacing the
/// first of several matches silently corrupts a file in a way that is hard to
/// notice and harder to undo.
fn replace_once(content: &str, old: &str, new: &str) -> Result<String, String> {
    match content.matches(old).count() {
        0 => Err("that text does not appear in the file".to_string()),
        1 => Ok(content.replacen(old, new, 1)),
        n => Err(format!(
            "that text appears {n} times; include enough context to make it unique"
        )),
    }
}

fn truncate(text: &str) -> String {
    if text.len() <= MAX_OUTPUT {
        return text.to_string();
    }
    let kept: String = text.chars().take(MAX_OUTPUT).collect();
    format!("{kept}\n… truncated at {MAX_OUTPUT} characters; read a narrower range for the rest")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_builtin_has_a_usable_schema() {
        for builtin in BUILTINS {
            let schema = (builtin.schema)();
            assert_eq!(schema["type"], "object", "{}", builtin.name);
            assert!(schema["properties"].is_object(), "{}", builtin.name);
            assert!(schema["required"].is_array(), "{}", builtin.name);
            assert!(!builtin.description.is_empty(), "{}", builtin.name);
        }
    }

    #[test]
    fn only_the_read_only_tools_may_be_replayed() {
        let safe: Vec<&str> = BUILTINS
            .iter()
            .filter(|b| b.replay == Replay::Safe)
            .map(|b| b.name)
            .collect();
        assert_eq!(safe, vec!["read", "ls", "glob", "grep"]);

        let never: Vec<&str> = BUILTINS
            .iter()
            .filter(|b| b.replay == Replay::Never)
            .map(|b| b.name)
            .collect();
        assert_eq!(never, vec!["bash", "write", "edit"], "anything that writes");
    }

    #[test]
    fn an_ambiguous_edit_is_refused_rather_than_guessed() {
        let content = "let x = 1;\nlet x = 1;\n";
        let err = replace_once(content, "let x = 1;", "let x = 2;").unwrap_err();
        assert!(err.contains("appears 2 times"), "{err}");
        assert!(err.contains("unique"), "and says how to fix it: {err}");
    }

    #[test]
    fn an_edit_that_matches_nothing_says_so() {
        assert!(
            replace_once("abc", "xyz", "1")
                .unwrap_err()
                .contains("does not appear")
        );
    }

    #[test]
    fn a_unique_edit_replaces_exactly_once() {
        let out = replace_once("a\nb\nc\n", "b", "B").unwrap();
        assert_eq!(out, "a\nB\nc\n");
    }

    #[test]
    fn output_is_truncated_with_a_pointer_to_the_rest() {
        let long = "x".repeat(MAX_OUTPUT * 2);
        let out = truncate(&long);
        assert!(out.len() < long.len());
        assert!(out.contains("truncated"), "and says so");
        assert!(out.contains("narrower range"), "and what to do about it");
    }

    #[test]
    fn short_output_is_left_exactly_alone() {
        assert_eq!(truncate("hello"), "hello");
    }

    #[test]
    fn arguments_are_shell_quoted() {
        // A path with a space, or worse, must not become two arguments.
        assert_eq!(quote("my file.txt"), "'my file.txt'");
        assert_eq!(quote("; rm -rf /"), "'; rm -rf /'");
    }

    #[test]
    fn a_missing_required_argument_names_itself() {
        let err = string(&Map::new(), "path").unwrap_err();
        assert!(err.contains("path"), "{err}");
    }
}
