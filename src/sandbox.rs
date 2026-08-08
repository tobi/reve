//! The mandatory microVM.
//!
//! Leve links the `microsandbox` crate directly. There is no CLI, no daemon, no
//! FFI shim, and no host-shell path: if the VM cannot boot, the agent refuses
//! to run rather than quietly executing model-authored commands on your machine.
//!
//! Egress is deny-by-default. The policy starts from
//! [`NetworkPolicy::none`] — deny both directions — and gains exactly two kinds
//! of rule: one narrow gateway-DNS rule so names resolve at all, and one allow
//! rule per host the agent's `sandbox.lua` names. Nothing here can widen that
//! to "the internet".

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use microsandbox::Sandbox as MsbSandbox;
use microsandbox_network::policy::{NetworkPolicy, Rule};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::sync::Mutex;

#[derive(Debug, Error)]
pub enum SandboxError {
    #[error("the microVM is unavailable: {0}")]
    Unavailable(String),
    #[error("sandbox operation failed: {0}")]
    Failed(String),
    #[error("invalid sandbox policy: {0}")]
    Policy(String),
}

pub type Result<T, E = SandboxError> = std::result::Result<T, E>;

/// A debian image with the tools an agent reaches for on its first turn.
pub const APT_PACKAGES: &[&str] = &[
    "ca-certificates",
    "curl",
    "git",
    "gh",
    "build-essential",
    "jq",
    "unzip",
    "ripgrep",
    "fd-find",
    "file",
    "less",
];
/// Node comes from mise. ast-grep stays on npm because mise's aqua backend
/// queries GitHub's unauthenticated, rate-limited releases API even for pinned
/// versions, and npm needs no implicit GitHub credential.
pub const MISE_TOOLS: &[&str] = &["node@lts"];
pub const NPM_TOOLS: &[&str] = &["@ast-grep/cli"];

/// Reachable by default, and nothing else.
pub const GITHUB_HOSTS: &[&str] = &[
    "github.com",
    "api.github.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
    "raw.githubusercontent.com",
];
/// Package mirrors, allowed *only* while provisioning is on. Bake your own
/// image and the policy collapses back to github-only.
pub const PROVISION_HOSTS: &[&str] = &[
    "deb.debian.org",
    "security.debian.org",
    "ftp.debian.org",
    "mise.run",
    "mise.jdx.dev",
    "registry.npmjs.org",
    "nodejs.org",
    "github.com",
    "objects.githubusercontent.com",
];

const PROVISION_MARKER: &str = "/var/lib/leve/provisioned";

/// A host credential the VM may use but never see.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Secret {
    pub env: String,
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    #[serde(default)]
    pub hosts: Vec<String>,
}

/// What `sandbox.lua` produced.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Policy {
    pub image: String,
    pub cpus: u8,
    pub memory: u32,
    pub workdir: String,
    pub mount_workspace: bool,
    pub provision: bool,
    pub packages: Vec<String>,
    pub mise: Vec<String>,
    pub npm: Vec<String>,
    pub allow_hosts: Vec<String>,
    pub secrets: Vec<Secret>,
    pub bootstrap: Vec<String>,
    pub env: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            image: "debian:trixie-slim".into(),
            cpus: 2,
            memory: 2048,
            workdir: "/workspace".into(),
            mount_workspace: true,
            provision: true,
            packages: APT_PACKAGES.iter().map(|s| s.to_string()).collect(),
            mise: MISE_TOOLS.iter().map(|s| s.to_string()).collect(),
            npm: NPM_TOOLS.iter().map(|s| s.to_string()).collect(),
            allow_hosts: GITHUB_HOSTS.iter().map(|s| s.to_string()).collect(),
            secrets: Vec::new(),
            bootstrap: Vec::new(),
            env: BTreeMap::from([
                ("DEBIAN_FRONTEND".into(), "noninteractive".into()),
                ("MISE_YES".into(), "1".into()),
            ]),
            name: None,
        }
    }
}

impl Policy {
    /// Every host this policy may reach.
    pub fn egress_hosts(&self) -> Vec<String> {
        let mut hosts = self.allow_hosts.clone();
        if self.provision {
            hosts.extend(PROVISION_HOSTS.iter().map(|s| s.to_string()));
        }
        hosts.sort();
        hosts.dedup();
        hosts
    }

    /// A stable VM name per workspace, so a second launch restarts the
    /// provisioned VM instead of installing the toolchain again.
    pub fn sandbox_name(&self, host_workspace: &Path) -> String {
        if let Some(name) = &self.name {
            return name.clone();
        }
        let root = host_workspace.parent().unwrap_or(host_workspace);
        let label: String = root
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "agent".into())
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                    c
                } else {
                    '-'
                }
            })
            .collect();
        let digest = Sha256::digest(root.to_string_lossy().as_bytes());
        format!("leve-{label}-{}", &hex(&digest)[..10])
    }

    /// Identifies the *shape* of this VM. A policy or toolchain change must
    /// force a rebuild; a secret rotation must too, so the proxy cannot keep
    /// serving a stale value. The secret itself is hashed, never stored.
    pub fn fingerprint(&self, host_workspace: &Path) -> String {
        let mut redacted = self.clone();
        for secret in &mut redacted.secrets {
            secret.value = format!("sha256:{}", hex(&Sha256::digest(secret.value.as_bytes())));
        }
        let mut hasher = Sha256::new();
        hasher.update(serde_json::to_vec(&redacted).unwrap_or_default());
        hasher.update(host_workspace.to_string_lossy().as_bytes());
        hex(&hasher.finalize())
    }

    /// One shell command that installs the default toolchain, guarded by a
    /// marker so it runs once per VM and keeps the boot path short.
    pub fn provision_script(&self) -> String {
        let packages = self.packages.join(" ");
        let mise = self.mise.join(" ");
        let npm = self.npm.join(" ");
        let mise_step = if mise.is_empty() {
            String::new()
        } else {
            format!("retry mise use -g {mise} > /dev/null")
        };
        let npm_step = if npm.is_empty() {
            String::new()
        } else {
            format!("retry npm install -g {npm} > /dev/null")
        };
        format!(
            r#"set -e
[ -f {PROVISION_MARKER} ] && exit 0
retry() {{
  attempts=0
  until "$@"; do
    attempts=$((attempts + 1))
    [ "$attempts" -ge 5 ] && return 1
    sleep "$attempts"
  done
}}
mkdir -p /var/lib/leve
if command -v apt-get > /dev/null; then
  apt-get -o Acquire::Retries=5 update -qq
  apt-get -o Acquire::Retries=5 install -y --no-install-recommends {packages} > /dev/null
  [ -x /usr/bin/fdfind ] && ln -sf /usr/bin/fdfind /usr/local/bin/fd || true
fi
if ! command -v mise > /dev/null; then
  retry curl -fsSL --retry 5 --retry-all-errors --retry-delay 1 -o /tmp/mise-install.sh https://mise.run
  retry env MISE_INSTALL_PATH=/usr/local/bin/mise sh /tmp/mise-install.sh
  rm -f /tmp/mise-install.sh
fi
printf '%s\n' 'export PATH="/usr/local/bin:$HOME/.local/share/mise/shims:$PATH"' > /etc/profile.d/10-mise.sh
chmod +x /etc/profile.d/10-mise.sh
. /etc/profile.d/10-mise.sh
{mise_step}
{npm_step}
touch {PROVISION_MARKER}
"#
        )
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The result of running a command in the VM.
///
/// A non-zero exit is **data**, not an error: the model reads the code and
/// stderr and decides what to do next.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Output {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: i32,
    pub success: bool,
    #[serde(default)]
    pub cancelled: bool,
}

/// Options for one command.
#[derive(Debug, Clone, Default)]
pub struct ExecOptions {
    pub cwd: Option<String>,
    pub env: BTreeMap<String, String>,
    pub timeout: Option<std::time::Duration>,
}

/// A live microVM.
pub struct Sandbox {
    policy: Policy,
    host_workspace: PathBuf,
    name: String,
    vm: Mutex<Option<MsbSandbox>>,
}

impl Sandbox {
    /// Boot the VM: restart the persisted one when the policy is unchanged,
    /// otherwise build a fresh one and provision it.
    pub async fn start(
        policy: Policy,
        host_workspace: impl AsRef<Path>,
        state_dir: impl AsRef<Path>,
        progress: &dyn Progress,
    ) -> Result<Self> {
        let host_workspace = host_workspace.as_ref().to_path_buf();
        let name = policy.sandbox_name(&host_workspace);
        tokio::fs::create_dir_all(&host_workspace)
            .await
            .map_err(|e| SandboxError::Unavailable(format!("cannot create workspace: {e}")))?;

        if !microsandbox::setup::is_installed() {
            progress.stage("installing the microsandbox runtime");
            microsandbox::setup::install()
                .await
                .map_err(|e| SandboxError::Unavailable(format!("cannot install runtime: {e}")))?;
        }

        // Never adopt a VM another leve owns: replacing it would break
        // isolation for both processes.
        if let Ok(handle) = MsbSandbox::get(&name).await {
            use microsandbox::sandbox::SandboxStatus;
            if matches!(
                handle.status_snapshot(),
                SandboxStatus::Running | SandboxStatus::Draining
            ) {
                return Err(SandboxError::Unavailable(format!(
                    "microVM {name} is already running in another leve process"
                )));
            }
        }

        let fingerprint_path = state_dir.as_ref().join("sandbox-fingerprint");
        let fingerprint = policy.fingerprint(&host_workspace);
        let reusable = tokio::fs::read_to_string(&fingerprint_path)
            .await
            .map(|text| text.trim() == fingerprint)
            .unwrap_or(false);

        if reusable {
            progress.stage(&format!("restarting microVM {name}"));
            if let Ok(vm) = MsbSandbox::start(&name).await {
                progress.finish("sandbox ready");
                return Ok(Self {
                    policy,
                    host_workspace,
                    name,
                    vm: Mutex::new(Some(vm)),
                });
            }
        }

        progress.stage(&format!("building microVM {name} from {}", policy.image));
        let vm = build(&policy, &name, &host_workspace).await?;
        let sandbox = Self {
            policy,
            host_workspace,
            name,
            vm: Mutex::new(Some(vm)),
        };

        let mut ok = true;
        if sandbox.policy.provision {
            let tools = sandbox
                .policy
                .mise
                .iter()
                .chain(sandbox.policy.npm.iter())
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");
            progress.stage(&format!(
                "provisioning APT packages{}",
                if tools.is_empty() {
                    String::new()
                } else {
                    format!(" and {tools}")
                }
            ));
            ok = sandbox.provision().await;
        }
        for (index, command) in sandbox.policy.bootstrap.iter().enumerate() {
            progress.stage(&format!(
                "running bootstrap {}/{}: {}",
                index + 1,
                sandbox.policy.bootstrap.len(),
                command.lines().next().unwrap_or("")
            ));
            let result = sandbox.exec(command, ExecOptions::default(), None).await?;
            ok &= result.success;
        }

        if ok {
            if let Some(parent) = fingerprint_path.parent() {
                let _ = tokio::fs::create_dir_all(parent).await;
            }
            let _ = tokio::fs::write(&fingerprint_path, format!("{fingerprint}\n")).await;
        }
        progress.finish(if ok {
            "sandbox ready"
        } else {
            "sandbox ready with provisioning errors"
        });
        Ok(sandbox)
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn policy(&self) -> &Policy {
        &self.policy
    }

    pub fn workdir(&self) -> &str {
        &self.policy.workdir
    }

    pub fn host_workspace(&self) -> &Path {
        &self.host_workspace
    }

    /// Run a command through `sh -lc`, so the guest's login PATH (and therefore
    /// mise's shims) is in effect.
    ///
    /// `cancel` is what makes `/abort` real: it kills the guest command through
    /// the agent's own control channel instead of abandoning the caller while
    /// the VM keeps working.
    pub async fn exec(
        &self,
        command: &str,
        options: ExecOptions,
        cancel: Option<tokio_util_lite::CancelRx>,
    ) -> Result<Output> {
        let vm = self.live().await?;
        let cwd = options
            .cwd
            .clone()
            .unwrap_or_else(|| self.policy.workdir.clone());
        let script = command.to_string();
        let env = options.env.clone();
        let timeout = options.timeout;

        let mut handle = vm
            .exec_stream_with("sh", move |mut e| {
                e = e.args(["-lc", script.as_str()]).cwd(cwd).stdin_null();
                for (key, value) in &env {
                    e = e.env(key.as_str(), value.as_str());
                }
                if let Some(t) = timeout {
                    e = e.timeout(t);
                }
                e
            })
            .await
            .map_err(|e| SandboxError::Failed(e.to_string()))?;

        let control = handle.control();
        match cancel {
            None => {
                let output = handle
                    .collect()
                    .await
                    .map_err(|e| SandboxError::Failed(e.to_string()))?;
                Ok(encode(&output, false))
            }
            Some(mut rx) => {
                tokio::select! {
                    collected = handle.collect() => {
                        let output = collected.map_err(|e| SandboxError::Failed(e.to_string()))?;
                        Ok(encode(&output, false))
                    }
                    _ = rx.cancelled() => {
                        let _ = control.kill().await;
                        Ok(Output {
                            stdout: String::new(),
                            stderr: String::new(),
                            exit_code: 130,
                            success: false,
                            cancelled: true,
                        })
                    }
                }
            }
        }
    }

    pub async fn read_file(&self, path: &str) -> Result<String> {
        let vm = self.live().await?;
        vm.fs()
            .read_to_string(&self.absolute(path))
            .await
            .map_err(|e| SandboxError::Failed(e.to_string()))
    }

    pub async fn write_file(&self, path: &str, content: &str) -> Result<()> {
        let vm = self.live().await?;
        vm.fs()
            .write(&self.absolute(path), content.as_bytes())
            .await
            .map_err(|e| SandboxError::Failed(e.to_string()))
    }

    /// Stop the VM but keep its root disk and definition, so the next launch
    /// restarts it. Idempotent.
    pub async fn stop(&self) -> Result<()> {
        let vm = { self.vm.lock().await.take() };
        match vm {
            Some(vm) => vm
                .stop()
                .await
                .map_err(|e| SandboxError::Failed(e.to_string())),
            None => Ok(()),
        }
    }

    pub fn describe(&self) -> String {
        let mut extras = Vec::new();
        if self.policy.provision {
            extras.push("provisioned".to_string());
        }
        if !self.policy.mise.is_empty() {
            extras.push(format!("mise {}", self.policy.mise.join(",")));
        }
        extras.push(format!("net {} hosts", self.policy.egress_hosts().len()));
        if !self.policy.secrets.is_empty() {
            let names: Vec<&str> = self.policy.secrets.iter().map(|s| s.env.as_str()).collect();
            extras.push(format!("secrets {}", names.join(",")));
        }
        let mount = if self.policy.mount_workspace {
            format!(
                "bind {} → {} (rw)",
                self.host_workspace.display(),
                self.policy.workdir
            )
        } else {
            "no workspace mount".to_string()
        };
        format!(
            "microsandbox {} ({} cpu, {}MB, {}) {mount}",
            self.policy.image,
            self.policy.cpus,
            self.policy.memory,
            extras.join(", ")
        )
    }

    fn absolute(&self, path: &str) -> String {
        if path.starts_with('/') {
            path.to_string()
        } else {
            format!("{}/{path}", self.policy.workdir.trim_end_matches('/'))
        }
    }

    /// Clone the handle out of the mutex before any await, so a long command
    /// never blocks `stop`, `read_file`, or the next `exec`.
    async fn live(&self) -> Result<MsbSandbox> {
        self.vm
            .lock()
            .await
            .clone()
            .ok_or_else(|| SandboxError::Failed(format!("sandbox {} is stopped", self.name)))
    }

    async fn provision(&self) -> bool {
        let script = self.policy.provision_script();
        let options = ExecOptions {
            cwd: Some("/".into()),
            timeout: Some(std::time::Duration::from_secs(900)),
            ..Default::default()
        };
        match self.exec(&script, options, None).await {
            Ok(output) if output.success => true,
            Ok(output) => {
                eprintln!(
                    "\x1b[33m sandbox provisioning failed (exit {}): {}\x1b[0m",
                    output.exit_code,
                    output
                        .stderr
                        .lines()
                        .rev()
                        .take(3)
                        .collect::<Vec<_>>()
                        .join(" ")
                );
                false
            }
            Err(e) => {
                eprintln!("\x1b[33m sandbox provisioning failed: {e}\x1b[0m");
                false
            }
        }
    }
}

fn encode(output: &microsandbox::ExecOutput, cancelled: bool) -> Output {
    let status = output.status();
    Output {
        stdout: String::from_utf8_lossy(output.stdout_bytes()).into_owned(),
        stderr: String::from_utf8_lossy(output.stderr_bytes()).into_owned(),
        exit_code: status.code,
        success: status.success,
        cancelled,
    }
}

/// Turn a [`Policy`] into a booted VM.
async fn build(policy: &Policy, name: &str, host_workspace: &Path) -> Result<MsbSandbox> {
    let mut builder = MsbSandbox::builder(name.to_string())
        .image(policy.image.clone())
        .cpus(policy.cpus)
        .memory(policy.memory)
        .workdir(policy.workdir.clone())
        .replace();

    for (key, value) in &policy.env {
        builder = builder.env(key.as_str(), value.as_str());
    }

    if policy.mount_workspace {
        let host = host_workspace.to_path_buf();
        builder = builder.volume(policy.workdir.clone(), move |m| m.bind(host));
    }

    // Deny both directions, admit gateway DNS, then allow exactly the named
    // hosts. Order matters only in that `allow_domains` prepends.
    let mut network = NetworkPolicy::none();
    network.rules.push(Rule::allow_dns());
    network = network
        .allow_domains(policy.egress_hosts())
        .map_err(|e| SandboxError::Policy(format!("invalid allowed host: {e}")))?;
    builder = builder.network(move |n| n.enabled(true).policy(network));

    for secret in &policy.secrets {
        if secret.value.is_empty() {
            continue;
        }
        let secret = secret.clone();
        builder = builder.secret(move |mut s| {
            s = s.env(secret.env.as_str()).value(secret.value.as_str());
            if let Some(placeholder) = &secret.placeholder {
                s = s.placeholder(placeholder.as_str());
            }
            for host in &secret.hosts {
                s = s.allow_host(host.as_str());
            }
            s
        });
    }

    builder
        .create()
        .await
        .map_err(|e| SandboxError::Unavailable(e.to_string()))
}

/// Startup happens before the TUI exists, so a long image pull needs somewhere
/// to say so.
pub trait Progress: Send + Sync {
    fn stage(&self, label: &str);
    fn finish(&self, label: &str);
}

/// Progress that says nothing — for tests and non-interactive runs.
pub struct Silent;

impl Progress for Silent {
    fn stage(&self, _label: &str) {}
    fn finish(&self, _label: &str) {}
}

/// A one-shot cancellation flag.
///
/// Deliberately hand-rolled rather than pulling in `tokio-util` for a single
/// type: an abort is one bit, delivered once.
pub mod tokio_util_lite {
    use tokio::sync::watch;

    #[derive(Debug, Clone)]
    pub struct CancelTx(watch::Sender<bool>);

    #[derive(Debug, Clone)]
    pub struct CancelRx(watch::Receiver<bool>);

    pub fn channel() -> (CancelTx, CancelRx) {
        let (tx, rx) = watch::channel(false);
        (CancelTx(tx), CancelRx(rx))
    }

    impl CancelTx {
        pub fn cancel(&self) {
            let _ = self.0.send(true);
        }
    }

    impl CancelRx {
        /// Resolves once cancellation is requested, and stays resolved.
        pub async fn cancelled(&mut self) {
            if *self.0.borrow() {
                return;
            }
            while self.0.changed().await.is_ok() {
                if *self.0.borrow() {
                    return;
                }
            }
            std::future::pending::<()>().await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn egress_is_github_only_once_provisioning_is_off() {
        let policy = Policy {
            provision: false,
            ..Default::default()
        };
        let hosts = policy.egress_hosts();
        assert!(hosts.contains(&"github.com".to_string()));
        assert!(
            !hosts.contains(&"deb.debian.org".to_string()),
            "mirrors are provisioning-only"
        );
    }

    #[test]
    fn provisioning_opens_package_mirrors_and_nothing_more() {
        let hosts = Policy::default().egress_hosts();
        assert!(hosts.contains(&"deb.debian.org".to_string()));
        assert!(!hosts.contains(&"example.com".to_string()));
    }

    #[test]
    fn the_vm_name_is_stable_per_workspace() {
        let policy = Policy::default();
        let a = policy.sandbox_name(Path::new("/tmp/my-agent/workspace"));
        let b = policy.sandbox_name(Path::new("/tmp/my-agent/workspace"));
        let other = policy.sandbox_name(Path::new("/tmp/other-agent/workspace"));
        assert_eq!(a, b, "the same agent restarts the same VM");
        assert_ne!(a, other);
        assert!(a.starts_with("leve-my-agent-"), "got {a}");
    }

    #[test]
    fn an_explicit_name_wins() {
        let policy = Policy {
            name: Some("pinned".into()),
            ..Default::default()
        };
        assert_eq!(policy.sandbox_name(Path::new("/tmp/x/workspace")), "pinned");
    }

    #[test]
    fn a_secret_value_never_reaches_the_fingerprint() {
        let ws = Path::new("/tmp/agent/workspace");
        let policy = Policy {
            secrets: vec![Secret {
                env: "T".into(),
                value: "SUPERSECRET".into(),
                placeholder: None,
                hosts: vec!["x.com".into()],
            }],
            ..Default::default()
        };
        let fingerprint = policy.fingerprint(ws);
        assert!(!fingerprint.contains("SUPERSECRET"));
        assert_eq!(fingerprint, policy.fingerprint(ws), "and it is stable");
    }

    #[test]
    fn rotating_a_secret_forces_a_rebuild() {
        let ws = Path::new("/tmp/agent/workspace");
        let mut policy = Policy {
            secrets: vec![Secret {
                env: "T".into(),
                value: "old".into(),
                placeholder: None,
                hosts: vec!["x.com".into()],
            }],
            ..Default::default()
        };
        let before = policy.fingerprint(ws);
        policy.secrets[0].value = "new".into();
        assert_ne!(
            before,
            policy.fingerprint(ws),
            "the proxy must not keep a stale value"
        );
    }

    #[test]
    fn changing_the_policy_changes_the_fingerprint() {
        let ws = Path::new("/tmp/agent/workspace");
        let base = Policy::default();
        let bigger = Policy {
            cpus: 4,
            ..Policy::default()
        };
        assert_ne!(base.fingerprint(ws), bigger.fingerprint(ws));
    }

    #[test]
    fn the_provision_script_is_guarded_by_its_marker() {
        let script = Policy::default().provision_script();
        assert!(script.contains(PROVISION_MARKER));
        assert!(script.starts_with("set -e"));
        assert!(script.contains("ripgrep"), "default packages are installed");
        assert!(script.contains("node@lts"));
    }

    #[tokio::test]
    async fn a_cancel_flag_resolves_once_and_stays_resolved() {
        let (tx, mut rx) = tokio_util_lite::channel();
        tx.cancel();
        rx.cancelled().await;
        rx.cancelled().await; // still resolved, does not hang
    }
}
