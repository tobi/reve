//! Leve's direct binding to the `microsandbox` Rust crate.
//!
//! Leve has exactly one sandbox transport: this extension. There is no CLI,
//! daemon, Fiddle, or host-shell fallback anywhere in the project, so if this
//! binding cannot boot the configured microVM, Leve refuses to start.
//!
//! Shape of the boundary:
//!
//! * Configuration crosses as **one JSON string**. The sandbox spec is deeply
//!   nested (mounts, egress allowlist, scoped secrets) and Leve already speaks
//!   JSON on every other boundary it owns, so this keeps the magnus surface
//!   small and the Ruby side trivially testable against a fake.
//! * Results cross as JSON too, except raw file bytes.
//! * Every call blocks the calling Ruby thread but **releases the GVL**, so
//!   other Ruby threads keep running.
//! * A [`Vm`] is a live handle. It is deliberately *not* Ractor-shareable:
//!   Leve keeps it in the main Ractor and dispatches to it from there.

use std::collections::BTreeMap;
use std::ffi::c_void;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use magnus::{
    exception::ExceptionClass, function, method, prelude::*, Error, RModule, Ruby,
};
use microsandbox::Sandbox;
use microsandbox::sandbox::{ExecOptionsBuilder, SandboxBuilder, SandboxStatus};
use microsandbox::{ExecControl, ExecHandle};
use microsandbox_network::policy::{NetworkPolicy, Rule};
use serde::Deserialize;
use serde_json::json;
use tokio::runtime::Runtime;

/// The crate version this binding is written against. `rake version_check`
/// asserts this matches the pin in Cargo.toml; a silent drift here would mean
/// binding against an API we never read.
const MICROSANDBOX_VERSION: &str = "0.6.8";

//--------------------------------------------------------------------------------------------------
// Tokio runtime, fork-safe
//--------------------------------------------------------------------------------------------------

struct RuntimeCell {
    pid: u32,
    rt: Arc<Runtime>,
}

static RUNTIME: LazyLock<Mutex<Option<RuntimeCell>>> = LazyLock::new(|| Mutex::new(None));

/// Hand back the process-wide tokio runtime, rebuilding it after a fork.
///
/// A tokio runtime does not survive `fork(2)`: the child inherits the runtime
/// struct but none of its worker threads. Ruby forks (and Leve's own crash
/// tests fork real children), so every entry point re-checks the pid and
/// builds a fresh runtime when it changed. The lock is held only while
/// cloning the `Arc`, never across a blocking call.
fn runtime() -> Result<Arc<Runtime>, Error> {
    let mut guard = RUNTIME.lock().unwrap_or_else(|e| e.into_inner());
    let pid = std::process::id();
    if let Some(existing) = guard.as_ref() {
        if existing.pid == pid {
            return Ok(existing.rt.clone());
        }
    }
    let rt = Runtime::new().map_err(|e| unavailable(format!("cannot start async runtime: {e}")))?;
    let rt = Arc::new(rt);
    *guard = Some(RuntimeCell {
        pid,
        rt: rt.clone(),
    });
    Ok(rt)
}

//--------------------------------------------------------------------------------------------------
// GVL
//--------------------------------------------------------------------------------------------------

/// Run `func` with the GVL released.
///
/// `func` must not touch the Ruby VM in any way — it only ever runs plain Rust
/// here (a `block_on` over microsandbox futures), and its result is moved back
/// out after the GVL is reacquired.
fn nogvl<F, R>(func: F) -> R
where
    F: FnOnce() -> R,
{
    struct Carrier<F, R> {
        func: Option<F>,
        result: Option<R>,
    }

    unsafe extern "C" fn call<F, R>(arg: *mut c_void) -> *mut c_void
    where
        F: FnOnce() -> R,
    {
        // SAFETY: `arg` is the `&mut Carrier` handed to
        // `rb_thread_call_without_gvl` below, which outlives this call.
        let carrier = unsafe { &mut *(arg as *mut Carrier<F, R>) };
        if let Some(func) = carrier.func.take() {
            carrier.result = Some(func());
        }
        std::ptr::null_mut()
    }

    let mut carrier = Carrier {
        func: Some(func),
        result: None,
    };
    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(call::<F, R>),
            &mut carrier as *mut _ as *mut c_void,
            None,
            std::ptr::null_mut(),
        );
    }
    carrier
        .result
        .expect("rb_thread_call_without_gvl did not run the callback")
}

/// Drive a future to completion off the GVL.
fn block<F, T>(fut: F) -> Result<T, Error>
where
    F: Future<Output = Result<T, microsandbox::MicrosandboxError>> + Send,
    T: Send,
{
    let rt = runtime()?;
    nogvl(|| rt.block_on(fut)).map_err(|e| failed(e.to_string()))
}

//--------------------------------------------------------------------------------------------------
// Errors
//--------------------------------------------------------------------------------------------------

fn error_class(name: &str) -> ExceptionClass {
    let ruby = Ruby::get().expect("no ruby vm");
    let leve: RModule = ruby
        .class_object()
        .const_get("Leve")
        .expect("Leve is not defined");
    let sandbox: RModule = leve.const_get("Sandbox").expect("Leve::Sandbox missing");
    let native: RModule = sandbox
        .const_get("Native")
        .expect("Leve::Sandbox::Native missing");
    native.const_get(name).expect("error class missing")
}

/// The microVM cannot be used at all: runtime missing, unbootable, no KVM.
fn unavailable(message: impl Into<String>) -> Error {
    Error::new(error_class("Unavailable"), message.into())
}

/// A sandbox operation failed.
fn failed(message: impl Into<String>) -> Error {
    Error::new(error_class("Failed"), message.into())
}

fn bad_spec(message: impl Into<String>) -> Error {
    Error::new(error_class("BadSpec"), message.into())
}

//--------------------------------------------------------------------------------------------------
// Spec
//--------------------------------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Spec {
    name: String,
    image: String,
    #[serde(default)]
    cpus: Option<u8>,
    #[serde(default)]
    memory: Option<u32>,
    #[serde(default)]
    workdir: Option<String>,
    #[serde(default)]
    env: BTreeMap<String, String>,
    #[serde(default)]
    mounts: Vec<MountSpec>,
    #[serde(default)]
    network: NetworkSpec,
    #[serde(default)]
    secrets: Vec<SecretSpec>,
    #[serde(default)]
    replace: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MountSpec {
    guest: String,
    host: String,
    #[serde(default)]
    readonly: bool,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct NetworkSpec {
    /// Absent or false means the network device is off entirely.
    #[serde(default)]
    enabled: bool,
    /// Exact hostnames permitted to egress. Empty with `enabled` means a
    /// policy that resolves nothing — deliberately not "allow all".
    #[serde(default)]
    allow: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SecretSpec {
    env: String,
    value: String,
    #[serde(default)]
    placeholder: Option<String>,
    #[serde(default)]
    hosts: Vec<String>,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct ExecSpec {
    #[serde(default)]
    args: Vec<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    env: BTreeMap<String, String>,
    #[serde(default)]
    timeout_ms: Option<u64>,
    #[serde(default)]
    stdin: Option<String>,
}

fn parse_spec<T: for<'de> Deserialize<'de>>(json_text: &str) -> Result<T, Error> {
    serde_json::from_str(json_text).map_err(|e| bad_spec(format!("invalid spec json: {e}")))
}

/// Translate a Leve spec into a microsandbox builder.
///
/// Egress is deny-by-default: the policy starts from `NetworkPolicy::none()`
/// (deny both directions) and gains exactly one narrow gateway-DNS rule plus
/// one allow rule per named host. Nothing here can widen that to "public".
fn builder_for(spec: &Spec) -> Result<SandboxBuilder, Error> {
    let mut b = Sandbox::builder(spec.name.clone()).image(spec.image.clone());

    if let Some(cpus) = spec.cpus {
        b = b.cpus(cpus);
    }
    if let Some(memory) = spec.memory {
        b = b.memory(memory);
    }
    if let Some(workdir) = &spec.workdir {
        b = b.workdir(workdir.clone());
    }
    for (key, value) in &spec.env {
        b = b.env(key.as_str(), value.as_str());
    }
    for mount in &spec.mounts {
        let host = mount.host.clone();
        let readonly = mount.readonly;
        b = b.volume(mount.guest.clone(), move |m| {
            let m = m.bind(host);
            if readonly {
                m.readonly()
            } else {
                m
            }
        });
    }

    if spec.network.enabled {
        let mut policy = NetworkPolicy::none();
        policy.rules.push(Rule::allow_dns());
        policy = policy
            .allow_domains(&spec.network.allow)
            .map_err(|e| bad_spec(format!("invalid allowed host: {e}")))?;
        b = b.network(move |n| n.enabled(true).policy(policy));
    } else {
        b = b.disable_network();
    }

    for secret in &spec.secrets {
        let env = secret.env.clone();
        let value = secret.value.clone();
        let placeholder = secret.placeholder.clone();
        let hosts = secret.hosts.clone();
        b = b.secret(move |s| {
            let mut s = s.env(env.as_str()).value(value.as_str());
            if let Some(p) = &placeholder {
                s = s.placeholder(p.as_str());
            }
            for host in &hosts {
                s = s.allow_host(host.as_str());
            }
            s
        });
    }

    if spec.replace {
        b = b.replace();
    }
    Ok(b)
}

//--------------------------------------------------------------------------------------------------
// Vm
//--------------------------------------------------------------------------------------------------

/// A live microVM handle.
///
/// `Mutex<Option<..>>` rather than a bare `Sandbox`: `stop` must be
/// idempotent and every later call on a stopped VM must fail loudly instead of
/// talking to a dead agent socket.
#[magnus::wrap(class = "Leve::Sandbox::Native::Vm", free_immediately, size)]
struct Vm {
    name: String,
    inner: Mutex<Option<Sandbox>>,
}

impl Vm {
    fn new(name: String, sandbox: Sandbox) -> Self {
        Self {
            name,
            inner: Mutex::new(Some(sandbox)),
        }
    }

    /// A clone of the live sandbox, with the lock already released.
    ///
    /// `Sandbox` is `Clone` (it is a name plus an `Arc` backend), so cloning
    /// here means a long `exec` never holds the mutex. That matters: an
    /// abandoned or slow command must not block `stop`, `read_file`, or a
    /// second `exec` behind it.
    fn live(&self) -> Result<Sandbox, Error> {
        let guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        match guard.as_ref() {
            Some(sandbox) => Ok(sandbox.clone()),
            None => Err(failed(format!("sandbox {} is stopped", self.name))),
        }
    }

    fn with<T, F>(&self, f: F) -> Result<T, Error>
    where
        F: FnOnce(&Sandbox) -> Result<T, Error>,
    {
        let sandbox = self.live()?;
        f(&sandbox)
    }

    fn name(&self) -> String {
        self.name.clone()
    }

    fn exec(&self, cmd: String, opts_json: String) -> Result<String, Error> {
        let opts: ExecSpec = parse_spec(&opts_json)?;
        self.with(|sandbox| {
            let output = block(sandbox.exec_with(cmd.clone(), |e| apply_exec(e, &opts)))?;
            Ok(encode_output(&output))
        })
    }

    fn shell(&self, script: String, opts_json: String) -> Result<String, Error> {
        let opts: ExecSpec = parse_spec(&opts_json)?;
        self.with(|sandbox| {
            let output = block(sandbox.shell_with(script.clone(), |e| apply_exec_no_args(e, &opts)))?;
            Ok(encode_output(&output))
        })
    }

    /// Start a command and hand back a handle that can actually kill it.
    ///
    /// `exec` is a single blocking call with no way in, so aborting a run could
    /// only ever abandon the caller while the guest kept working. A streaming
    /// session exposes the agent's own control channel, so `Exec#kill` stops
    /// the guest command itself — not the VM, and not just our side of it.
    fn exec_session(&self, cmd: String, opts_json: String) -> Result<Exec, Error> {
        let opts: ExecSpec = parse_spec(&opts_json)?;
        let sandbox = self.live()?;
        let handle = block(async move { sandbox.exec_stream_with(cmd, |e| apply_exec(e, &opts)).await })?;
        let control = handle.control();
        Ok(Exec {
            handle: Mutex::new(Some(handle)),
            control,
        })
    }

    fn read_file(&self, path: String) -> Result<String, Error> {
        self.with(|sandbox| block(sandbox.fs().read_to_string(&path)))
    }

    fn write_file(&self, path: String, data: String) -> Result<(), Error> {
        self.with(|sandbox| block(sandbox.fs().write(&path, data.as_bytes())))
    }

    /// Liveness probe. Deliberately a boolean rather than a status enum: the
    /// only question Leve ever asks is "can I still talk to the guest".
    fn alive(&self) -> bool {
        self.with(|sandbox| Ok(block(sandbox.ping()).is_ok()))
            .unwrap_or(false)
    }

    /// Stop the VM but keep its root disk and definition, so the next launch
    /// restarts it instead of reprovisioning. Idempotent.
    fn stop(&self) -> Result<(), Error> {
        let sandbox = {
            let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            guard.take()
        };
        match sandbox {
            Some(sandbox) => block(sandbox.stop()),
            None => Ok(()),
        }
    }
}

/// A running command, with a control channel.
///
/// `collect` blocks (off the GVL) until the command finishes; `kill` can be
/// called from another Ruby thread meanwhile. That pairing is what makes
/// `/abort` stop real work instead of merely abandoning the caller.
#[magnus::wrap(class = "Leve::Sandbox::Native::Exec", free_immediately, size)]
struct Exec {
    handle: Mutex<Option<ExecHandle>>,
    control: ExecControl,
}

impl Exec {
    /// Drain the session to completion. Consumes the handle, so a second call
    /// reports the session as already collected rather than hanging forever.
    fn collect(&self) -> Result<String, Error> {
        let mut handle = {
            let mut guard = self.handle.lock().unwrap_or_else(|e| e.into_inner());
            match guard.take() {
                Some(handle) => handle,
                None => return Err(failed("exec session was already collected")),
            }
        };
        let output = block(async move { handle.collect().await })?;
        Ok(encode_output(&output))
    }

    /// Kill the guest command. Killing an already-finished command is not an
    /// error: the race between "it just exited" and "abort now" is expected.
    fn kill(&self) -> Result<(), Error> {
        let control = self.control.clone();
        let rt = runtime()?;
        let _ = nogvl(|| rt.block_on(control.kill()));
        Ok(())
    }
}

fn apply_exec(e: ExecOptionsBuilder, opts: &ExecSpec) -> ExecOptionsBuilder {
    apply_exec_no_args(e.args(opts.args.clone()), opts)
}

fn apply_exec_no_args(mut e: ExecOptionsBuilder, opts: &ExecSpec) -> ExecOptionsBuilder {
    if let Some(cwd) = &opts.cwd {
        e = e.cwd(cwd.clone());
    }
    for (k, v) in &opts.env {
        e = e.env(k.as_str(), v.as_str());
    }
    if let Some(ms) = opts.timeout_ms {
        e = e.timeout(Duration::from_millis(ms));
    }
    match &opts.stdin {
        Some(data) => e.stdin_bytes(data.clone().into_bytes()),
        None => e.stdin_null(),
    }
}

fn encode_output(output: &microsandbox::ExecOutput) -> String {
    let status = output.status();
    json!({
        "stdout": String::from_utf8_lossy(output.stdout_bytes()),
        "stderr": String::from_utf8_lossy(output.stderr_bytes()),
        "exitCode": status.code,
        "success": status.success,
    })
    .to_string()
}

//--------------------------------------------------------------------------------------------------
// Module functions
//--------------------------------------------------------------------------------------------------

fn installed() -> bool {
    microsandbox::setup::is_installed()
}

fn install() -> Result<(), Error> {
    let rt = runtime()?;
    nogvl(|| rt.block_on(microsandbox::setup::install()))
        .map_err(|e| unavailable(format!("cannot install microsandbox runtime: {e}")))
}

fn create(spec_json: String) -> Result<Vm, Error> {
    let spec: Spec = parse_spec(&spec_json)?;
    let builder = builder_for(&spec)?;
    let sandbox = block(builder.create())?;
    Ok(Vm::new(spec.name, sandbox))
}

/// Restart an already-provisioned named VM.
fn start(name: String) -> Result<Vm, Error> {
    let sandbox = block(Sandbox::start(&name))?;
    Ok(Vm::new(name, sandbox))
}

fn exists(name: String) -> Result<bool, Error> {
    let rt = runtime()?;
    Ok(nogvl(|| rt.block_on(Sandbox::get(&name))).is_ok())
}

/// Is a persisted VM currently live?
///
/// Leve uses this to refuse to steal a microVM another Leve process owns:
/// replacing a running sandbox would break isolation for both of them. A name
/// that does not exist is simply not running.
fn running(name: String) -> Result<bool, Error> {
    let rt = runtime()?;
    let handle = match nogvl(|| rt.block_on(Sandbox::get(&name))) {
        Ok(handle) => handle,
        Err(_) => return Ok(false),
    };
    Ok(matches!(
        handle.status_snapshot(),
        SandboxStatus::Running | SandboxStatus::Draining
    ))
}

fn remove(name: String) -> Result<(), Error> {
    block(Sandbox::remove(&name))
}

fn microsandbox_version() -> String {
    MICROSANDBOX_VERSION.to_string()
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let leve = ruby.define_module("Leve")?;
    let sandbox = leve.define_module("Sandbox")?;
    let native = sandbox.define_module("Native")?;

    let base = native.define_error("Error", ruby.exception_standard_error())?;
    native.define_error("Unavailable", base)?;
    native.define_error("Failed", base)?;
    native.define_error("BadSpec", base)?;

    native.const_set("MICROSANDBOX_VERSION", MICROSANDBOX_VERSION)?;
    native.define_singleton_method("installed?", function!(installed, 0))?;
    native.define_singleton_method("install", function!(install, 0))?;
    native.define_singleton_method("create", function!(create, 1))?;
    native.define_singleton_method("start", function!(start, 1))?;
    native.define_singleton_method("exists?", function!(exists, 1))?;
    native.define_singleton_method("running?", function!(running, 1))?;
    native.define_singleton_method("remove", function!(remove, 1))?;
    native.define_singleton_method("microsandbox_version", function!(microsandbox_version, 0))?;

    let vm = native.define_class("Vm", ruby.class_object())?;
    vm.define_method("name", method!(Vm::name, 0))?;
    vm.define_method("exec", method!(Vm::exec, 2))?;
    vm.define_method("shell", method!(Vm::shell, 2))?;
    vm.define_method("read_file", method!(Vm::read_file, 1))?;
    vm.define_method("write_file", method!(Vm::write_file, 2))?;
    vm.define_method("alive?", method!(Vm::alive, 0))?;
    vm.define_method("exec_session", method!(Vm::exec_session, 2))?;
    vm.define_method("stop", method!(Vm::stop, 0))?;

    let exec = native.define_class("Exec", ruby.class_object())?;
    exec.define_method("collect", method!(Exec::collect, 0))?;
    exec.define_method("kill", method!(Exec::kill, 0))?;

    Ok(())
}
