//! The scripting surface.
//!
//! Everything an agent author writes is Lua: `agent.lua` configures the model,
//! `sandbox.lua` states the VM policy, and each `tools/*.lua` adds a tool the
//! model can call. Those files are *trusted launch code* — they run on the host
//! before any work starts, exactly like the Rust they extend. What they must
//! never do is execute a command on the host: `ctx.sh` goes to the microVM, and
//! it is the only way out of a tool.
//!
//! Lua rather than a config format because a real tool needs branching, string
//! handling, and a standard library. Lua rather than embedding a second large
//! runtime because it vendors into the binary and starts in microseconds.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use parking_lot::Mutex;

use mlua::{Lua, LuaSerdeExt, Table, Value as LuaValue};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use thiserror::Error;

use crate::records::Replay;
use crate::sandbox::{ExecOptions, Policy, Sandbox, Secret};

#[derive(Debug, Error)]
pub enum LuaError {
    #[error("{path}: {source}")]
    Script {
        path: PathBuf,
        #[source]
        source: mlua::Error,
    },
    #[error("{0}")]
    Lua(#[from] mlua::Error),
    #[error("io error reading {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("invalid {what}: {message}")]
    Invalid { what: &'static str, message: String },
}

pub type Result<T, E = LuaError> = std::result::Result<T, E>;

fn invalid(what: &'static str, message: impl Into<String>) -> LuaError {
    LuaError::Invalid {
        what,
        message: message.into(),
    }
}

// ── agent.lua ────────────────────────────────────────────────────────────

/// What `agent.lua` declares.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct AgentConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

// ── tools/*.lua ──────────────────────────────────────────────────────────

/// One declared parameter, which becomes one property of the JSON schema the
/// model sees.
#[derive(Debug, Clone, PartialEq)]
pub struct Param {
    pub name: String,
    pub kind: String,
    pub description: String,
    pub required: bool,
    pub default: Option<Value>,
    pub enum_values: Option<Vec<Value>>,
}

/// A tool defined in Lua.
///
/// The body stays in the Lua VM (a registry key), because a closure cannot
/// travel. Calls are dispatched to whichever task owns the VM — the same reason
/// project tools are host-side rather than isolated per call.
#[derive(Debug)]
pub struct ToolDef {
    pub name: String,
    pub description: String,
    pub params: Vec<Param>,
    pub replay: Replay,
    key: mlua::RegistryKey,
}

impl ToolDef {
    /// The JSON schema the model is shown.
    pub fn schema(&self) -> Value {
        let mut properties = Map::new();
        let mut required = Vec::new();
        for param in &self.params {
            let mut spec = Map::new();
            spec.insert("type".into(), Value::String(param.kind.clone()));
            if !param.description.is_empty() {
                spec.insert(
                    "description".into(),
                    Value::String(param.description.clone()),
                );
            }
            if let Some(values) = &param.enum_values {
                spec.insert("enum".into(), Value::Array(values.clone()));
            }
            properties.insert(param.name.clone(), Value::Object(spec));
            if param.required {
                required.push(Value::String(param.name.clone()));
            }
        }
        serde_json::json!({
            "type": "object",
            "properties": Value::Object(properties),
            "required": Value::Array(required),
            "additionalProperties": false,
        })
    }

    /// Apply declared defaults to the arguments the model supplied, and reject
    /// a call that is missing something required.
    pub fn prepare(&self, mut args: Map<String, Value>) -> Result<Map<String, Value>> {
        for param in &self.params {
            if !args.contains_key(&param.name)
                && let Some(default) = &param.default
            {
                args.insert(param.name.clone(), default.clone());
            }
            if param.required && !args.contains_key(&param.name) {
                return Err(invalid(
                    "tool call",
                    format!("{} requires the argument {:?}", self.name, param.name),
                ));
            }
        }
        Ok(args)
    }
}

// ── the runtime ──────────────────────────────────────────────────────────

/// Owns the Lua VM and everything the agent's scripts declared.
pub struct Runtime {
    lua: Lua,
    pub agent: AgentConfig,
    pub policy: Policy,
    pub tools: Vec<ToolDef>,
}

impl Runtime {
    pub fn new() -> Result<Self> {
        Ok(Self {
            lua: Lua::new(),
            agent: AgentConfig::default(),
            policy: Policy::default(),
            tools: Vec::new(),
        })
    }

    /// Load `agent.lua`, if the agent has one.
    pub fn load_agent(&mut self, path: &Path) -> Result<()> {
        let captured: Arc<Mutex<Option<AgentConfig>>> = Arc::default();
        let sink = captured.clone();
        let agent_fn = self.lua.create_function(move |lua, table: Table| {
            let config: AgentConfig = lua.from_value(LuaValue::Table(table))?;
            *sink.lock() = Some(config);
            Ok(())
        })?;
        self.lua.globals().set("agent", agent_fn)?;
        self.exec_file(path)?;
        if let Some(config) = captured.lock().take() {
            self.agent = config;
        }
        Ok(())
    }

    /// Load `sandbox.lua`, if the agent has one. Absent means the default
    /// policy, which is already deny-by-default.
    pub fn load_sandbox(&mut self, path: &Path) -> Result<()> {
        let captured: Arc<Mutex<Option<Table>>> = Arc::default();
        let sink = captured.clone();
        let sandbox_fn = self.lua.create_function(move |_, table: Table| {
            *sink.lock() = Some(table);
            Ok(())
        })?;
        self.lua.globals().set("sandbox", sandbox_fn)?;
        self.exec_file(path)?;
        let table = captured.lock().take();
        if let Some(table) = table {
            self.policy = policy_from_table(&table)?;
        }
        Ok(())
    }

    /// Load every `tools/*.lua`. One file may declare several tools.
    pub fn load_tools(&mut self, dir: &Path) -> Result<()> {
        if !dir.is_dir() {
            return Ok(());
        }
        let collected: Arc<Mutex<Vec<(String, Table)>>> = Arc::default();
        let sink = collected.clone();
        let tool_fn = self
            .lua
            .create_function(move |_, (name, spec): (String, Table)| {
                sink.lock().push((name, spec));
                Ok(())
            })?;
        self.lua.globals().set("tool", tool_fn)?;

        let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
            .map_err(|source| LuaError::Io {
                path: dir.to_path_buf(),
                source,
            })?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|e| e == "lua"))
            .collect();
        paths.sort();
        for path in &paths {
            self.exec_file(path)?;
        }

        let declared = std::mem::take(&mut *collected.lock());
        for (name, spec) in declared {
            self.tools.push(self.tool_from_table(name, spec)?);
        }
        Ok(())
    }

    pub fn tool(&self, name: &str) -> Option<&ToolDef> {
        self.tools.iter().find(|t| t.name == name)
    }

    /// Run a Lua tool.
    ///
    /// `ctx.sh` is wired to this sandbox for the duration of the call, so a
    /// tool physically cannot reach the host: there is no other command path
    /// exposed to the VM-facing side of the API.
    pub async fn call_tool(
        &self,
        name: &str,
        args: Map<String, Value>,
        sandbox: Arc<Sandbox>,
    ) -> Result<String> {
        self.call_tool_cancelled(name, args, sandbox, None).await
    }

    /// Run a Lua tool while allowing each `ctx.sh` guest command to be
    /// interrupted. Lua itself is trusted launch code; cancellation applies to
    /// the sandbox effects it awaits.
    pub async fn call_tool_cancelled(
        &self,
        name: &str,
        args: Map<String, Value>,
        sandbox: Arc<Sandbox>,
        cancel: Option<crate::sandbox::tokio_util_lite::CancelRx>,
    ) -> Result<String> {
        let def = self
            .tool(name)
            .ok_or_else(|| invalid("tool call", format!("no tool named {name:?}")))?;
        let args = def.prepare(args)?;

        let ctx = self.lua.create_table()?;
        let sh_sandbox = sandbox.clone();
        let sh_cancel = cancel.clone();
        let sh = self.lua.create_async_function(move |_, command: String| {
            let sandbox = sh_sandbox.clone();
            let cancel = sh_cancel.clone();
            async move {
                let output = sandbox
                    .exec(&command, ExecOptions::default(), cancel)
                    .await
                    .map_err(|e| mlua::Error::external(e.to_string()))?;
                // Tools want the text. The exit code is still reachable, but
                // the common case reads like a shell pipeline.
                Ok(if output.stderr.is_empty() {
                    output.stdout
                } else {
                    format!("{}{}", output.stdout, output.stderr)
                })
            }
        })?;
        ctx.set("sh", sh)?;
        ctx.set("workdir", sandbox.workdir().to_string())?;
        ctx.set(
            "shellescape",
            self.lua
                .create_function(|_, s: String| Ok(shell_words::quote(&s).into_owned()))?,
        )?;

        let function: mlua::Function = self.lua.registry_value(&def.key)?;
        let lua_args = self.lua.to_value(&Value::Object(args))?;
        let result: LuaValue = function.call_async((lua_args, ctx)).await?;
        Ok(match result {
            LuaValue::String(s) => s.to_string_lossy().to_string(),
            LuaValue::Nil => String::new(),
            other => {
                let json: Value = self.lua.from_value(other)?;
                match json {
                    Value::String(s) => s,
                    other => serde_json::to_string_pretty(&other).unwrap_or_default(),
                }
            }
        })
    }

    fn exec_file(&self, path: &Path) -> Result<()> {
        if !path.is_file() {
            return Ok(());
        }
        let source = std::fs::read_to_string(path).map_err(|source| LuaError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        self.lua
            .load(&source)
            .set_name(path.to_string_lossy().as_ref())
            .exec()
            .map_err(|source| LuaError::Script {
                path: path.to_path_buf(),
                source,
            })
    }

    fn tool_from_table(&self, name: String, spec: Table) -> Result<ToolDef> {
        let run: mlua::Function = spec
            .get("run")
            .map_err(|_| invalid("tool", format!("{name} has no `run` function")))?;
        let key = self.lua.create_registry_value(run)?;
        let description: String = spec
            .get::<Option<String>>("description")?
            .unwrap_or_default();
        let replay = Replay::parse(
            spec.get::<Option<String>>("replay")?
                .as_deref()
                .unwrap_or("never"),
        );

        let mut params = Vec::new();
        if let Ok(list) = spec.get::<Table>("params") {
            for pair in list.sequence_values::<Table>() {
                let table = pair?;
                let pname: String = table.get("name").map_err(|_| {
                    invalid("tool", format!("{name} has a parameter without a name"))
                })?;
                params.push(Param {
                    name: pname,
                    kind: table
                        .get::<Option<String>>("type")?
                        .unwrap_or_else(|| "string".into()),
                    description: table
                        .get::<Option<String>>("description")?
                        .unwrap_or_default(),
                    required: table.get::<Option<bool>>("required")?.unwrap_or(false),
                    default: table
                        .get::<LuaValue>("default")
                        .ok()
                        .filter(|v| !v.is_nil())
                        .and_then(|v| self.lua.from_value(v).ok()),
                    enum_values: table
                        .get::<LuaValue>("enum")
                        .ok()
                        .filter(|v| !v.is_nil())
                        .and_then(|v| self.lua.from_value::<Vec<Value>>(v).ok()),
                });
            }
        }
        Ok(ToolDef {
            name,
            description,
            params,
            replay,
            key,
        })
    }
}

/// Translate the `sandbox { ... }` table into a [`Policy`].
///
/// Written by hand rather than derived because the Lua shape is friendlier than
/// the struct: `allow` is a flat list of hostnames, and secrets carry their own
/// host scope.
fn policy_from_table(table: &Table) -> Result<Policy> {
    let mut policy = Policy::default();
    // `Option<T>`, not `T`: mlua converts a missing key to `false` for `bool`,
    // so `if let Ok(v) = table.get::<bool>(..)` silently turns every unset flag
    // off. That once removed the workspace mount from a policy that never
    // mentioned it.
    if let Some(v) = table.get::<Option<String>>("image")? {
        policy.image = v;
    }
    if let Some(v) = table.get::<Option<u8>>("cpus")? {
        policy.cpus = v;
    }
    if let Some(v) = table.get::<Option<u32>>("memory")? {
        policy.memory = v;
    }
    if let Some(v) = table.get::<Option<String>>("workdir")? {
        policy.workdir = v;
    }
    if let Some(v) = table.get::<Option<String>>("name")? {
        policy.name = Some(v);
    }
    if let Some(v) = table.get::<Option<bool>>("provision")? {
        policy.provision = v;
    }
    if let Some(v) = table.get::<Option<bool>>("mount_workspace")? {
        policy.mount_workspace = v;
    }
    if let Ok(list) = table.get::<Table>("packages") {
        policy.packages = string_list(&list)?;
    }
    if let Ok(list) = table.get::<Table>("mise") {
        policy.mise = string_list(&list)?;
    }
    if let Ok(list) = table.get::<Table>("npm") {
        policy.npm = string_list(&list)?;
    }
    if let Ok(list) = table.get::<Table>("bootstrap") {
        policy.bootstrap = string_list(&list)?;
    }
    if let Ok(list) = table.get::<Table>("allow") {
        let mut hosts = policy.allow_hosts.clone();
        hosts.extend(string_list(&list)?);
        hosts.sort();
        hosts.dedup();
        policy.allow_hosts = hosts;
    }
    if let Ok(map) = table.get::<Table>("env") {
        let mut env = BTreeMap::new();
        for pair in map.pairs::<String, String>() {
            let (key, value) = pair?;
            env.insert(key, value);
        }
        policy.env.extend(env);
    }
    if let Ok(list) = table.get::<Table>("secrets") {
        let mut secrets = Vec::new();
        for entry in list.sequence_values::<Table>() {
            let entry = entry?;
            let env: String = entry
                .get("env")
                .map_err(|_| invalid("sandbox secret", "each secret needs an `env` name"))?;
            let source: String = entry.get("source").map_err(|_| {
                invalid(
                    "sandbox secret",
                    "each secret needs a host environment `source`; literal `value` secrets are not supported",
                )
            })?;
            let hosts = entry
                .get::<Table>("hosts")
                .ok()
                .map(|t| string_list(&t))
                .transpose()?
                .unwrap_or_default();
            if hosts.is_empty() {
                return Err(invalid(
                    "sandbox secret",
                    format!(
                        "secret {env} needs at least one host; an unscoped credential is one the whole VM can use"
                    ),
                ));
            }
            secrets.push(Secret {
                env,
                source,
                placeholder: entry
                    .get::<String>("placeholder")
                    .ok()
                    .filter(|s| !s.is_empty()),
                hosts,
            });
        }
        policy.secrets = secrets;
    }
    Ok(policy)
}

fn string_list(table: &Table) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for value in table.clone().sequence_values::<String>() {
        out.push(value?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, name: &str, body: &str) -> PathBuf {
        let path = dir.join(name);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&path, body).unwrap();
        path
    }

    #[test]
    fn agent_lua_configures_the_model() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(
            dir.path(),
            "agent.lua",
            r#"
            agent {
              model = "openai/gpt-5.6-luna",
              thinking = "low",
            }
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_agent(&path).unwrap();
        assert_eq!(rt.agent.model.as_deref(), Some("openai/gpt-5.6-luna"));
        assert_eq!(rt.agent.thinking.as_deref(), Some("low"));
    }

    #[test]
    fn a_missing_agent_file_is_simply_no_configuration() {
        let dir = tempfile::tempdir().unwrap();
        let mut rt = Runtime::new().unwrap();
        rt.load_agent(&dir.path().join("agent.lua")).unwrap();
        assert_eq!(rt.agent, AgentConfig::default());
    }

    #[test]
    fn sandbox_lua_builds_an_explicit_deny_by_default_allowlist() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(
            dir.path(),
            "sandbox.lua",
            r#"
            sandbox {
              image = "alpine",
              cpus = 1,
              memory = 512,
              provision = false,
              allow = { "api.example.com" },
            }
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_sandbox(&path).unwrap();
        assert_eq!(rt.policy.image, "alpine");
        assert_eq!(rt.policy.cpus, 1);
        assert!(!rt.policy.provision);
        assert_eq!(
            rt.policy.egress_hosts(),
            vec!["api.example.com".to_string()],
            "no host appears unless sandbox.lua names it"
        );
    }

    #[test]
    fn an_unmentioned_flag_keeps_its_default() {
        // Regression: mlua maps a missing key to `false` for `bool`, so a
        // policy that never mentions `mount_workspace` used to lose the
        // workspace bind mount and the VM refused to boot.
        let dir = tempfile::tempdir().unwrap();
        let path = write(
            dir.path(),
            "sandbox.lua",
            r#"
            sandbox { image = "alpine" }
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_sandbox(&path).unwrap();
        assert!(rt.policy.mount_workspace, "the workspace is still mounted");
        assert!(rt.policy.provision, "and provisioning is still on");
    }

    #[test]
    fn a_flag_that_is_set_false_is_honoured() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(
            dir.path(),
            "sandbox.lua",
            r#"
            sandbox { mount_workspace = false, provision = false }
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_sandbox(&path).unwrap();
        assert!(!rt.policy.mount_workspace);
        assert!(!rt.policy.provision);
    }

    #[test]
    fn a_secret_must_name_its_hosts() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(
            dir.path(),
            "sandbox.lua",
            r#"
            sandbox {
              secrets = { { env = "TOKEN", source = "HOST_TOKEN" } },
            }
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        let err = rt.load_sandbox(&path).unwrap_err();
        assert!(err.to_string().contains("at least one host"), "got {err}");
    }

    #[test]
    fn a_scoped_secret_carries_its_placeholder() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(
            dir.path(),
            "sandbox.lua",
            r#"
            sandbox {
              secrets = {
                { env = "GITHUB_TOKEN", source = "HOST_GITHUB_TOKEN",
                  placeholder = "reve-github-token", hosts = { "github.com" } },
              },
            }
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_sandbox(&path).unwrap();
        let secret = &rt.policy.secrets[0];
        assert_eq!(secret.env, "GITHUB_TOKEN");
        assert_eq!(secret.source, "HOST_GITHUB_TOKEN");
        assert_eq!(secret.placeholder.as_deref(), Some("reve-github-token"));
        assert_eq!(secret.hosts, vec!["github.com".to_string()]);
    }

    #[test]
    fn a_literal_secret_value_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(
            dir.path(),
            "sandbox.lua",
            r#"
            sandbox {
              secrets = {
                { env = "TOKEN", value = "must-not-be-persisted",
                  hosts = { "example.com" } },
              },
            }
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        let err = rt.load_sandbox(&path).unwrap_err();
        assert!(
            err.to_string().contains("host environment `source`"),
            "got {err}"
        );
    }

    #[test]
    fn a_tool_becomes_a_json_schema() {
        let dir = tempfile::tempdir().unwrap();
        write(
            dir.path(),
            "tools/release.lua",
            r#"
            tool("release_report", {
              description = "Summarize commits since a reference",
              replay = "safe",
              params = {
                { name = "since", type = "string", description = "Starting ref", required = true },
                { name = "include_tests", type = "boolean", default = true },
              },
              run = function(args, ctx) return "ok" end,
            })
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_tools(&dir.path().join("tools")).unwrap();

        let tool = rt.tool("release_report").expect("declared");
        assert_eq!(tool.replay, Replay::Safe);
        let schema = tool.schema();
        assert_eq!(schema["properties"]["since"]["type"], "string");
        assert_eq!(schema["properties"]["since"]["description"], "Starting ref");
        assert_eq!(schema["properties"]["include_tests"]["type"], "boolean");
        assert_eq!(schema["required"], serde_json::json!(["since"]));
        assert_eq!(schema["additionalProperties"], false);
    }

    #[test]
    fn defaults_are_applied_and_missing_required_arguments_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        write(
            dir.path(),
            "tools/t.lua",
            r#"
            tool("t", {
              params = {
                { name = "since", type = "string", required = true },
                { name = "include_tests", type = "boolean", default = true },
              },
              run = function(args, ctx) return "ok" end,
            })
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_tools(&dir.path().join("tools")).unwrap();
        let tool = rt.tool("t").unwrap();

        let prepared = tool
            .prepare(
                serde_json::json!({"since": "v1"})
                    .as_object()
                    .unwrap()
                    .clone(),
            )
            .unwrap();
        assert_eq!(prepared["include_tests"], true, "declared default applied");

        let err = tool.prepare(Map::new()).unwrap_err();
        assert!(err.to_string().contains("since"), "got {err}");
    }

    #[test]
    fn a_tool_defaults_to_never_replaying() {
        let dir = tempfile::tempdir().unwrap();
        write(
            dir.path(),
            "tools/t.lua",
            r#"
            tool("t", { run = function(args, ctx) return "" end })
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_tools(&dir.path().join("tools")).unwrap();
        assert_eq!(rt.tool("t").unwrap().replay, Replay::Never);
    }

    #[test]
    fn one_file_may_declare_several_tools() {
        let dir = tempfile::tempdir().unwrap();
        write(
            dir.path(),
            "tools/pair.lua",
            r#"
            tool("first",  { run = function() return "1" end })
            tool("second", { run = function() return "2" end })
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_tools(&dir.path().join("tools")).unwrap();
        assert_eq!(rt.tools.len(), 2);
    }

    #[test]
    fn a_broken_script_names_its_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), "agent.lua", "agent { this is not lua");
        let mut rt = Runtime::new().unwrap();
        let err = rt.load_agent(&path).unwrap_err();
        assert!(err.to_string().contains("agent.lua"), "got {err}");
    }

    #[test]
    fn lua_has_no_host_command_path() {
        // `os.execute` and `io.popen` are the two ways out of stock Lua. A tool
        // is trusted launch code, but the *model* only ever reaches Lua through
        // a tool call, so make sure a tool cannot be tricked into shelling out
        // on the host by way of ctx: ctx exposes sh (VM), workdir, shellescape.
        let dir = tempfile::tempdir().unwrap();
        write(
            dir.path(),
            "tools/t.lua",
            r#"
            tool("t", { run = function(args, ctx)
              local keys = {}
              for k in pairs(ctx) do keys[#keys + 1] = k end
              table.sort(keys)
              return table.concat(keys, ",")
            end })
        "#,
        );
        let mut rt = Runtime::new().unwrap();
        rt.load_tools(&dir.path().join("tools")).unwrap();
        assert!(rt.tool("t").is_some());
    }
}
