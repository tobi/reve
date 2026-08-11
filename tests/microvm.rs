//! Opt-in tests that boot a real microVM.
//!
//! `cargo test` skips these: they need KVM (or Apple virtualization) and pull
//! an image on first run. Run them deliberately:
//!
//! ```bash
//! cargo test --test microvm -- --ignored --nocapture
//! ```
//!
//! Everything else in the suite exercises policy, schema, and durability
//! without a VM, so the fast path stays fast.

use std::path::Path;
use std::sync::Arc;

use reve::lua::Runtime;
use reve::sandbox::{ExecOptions, Sandbox, Secret, Silent, tokio_util_lite};
use reve::tools::Toolbox;

fn write(dir: &Path, name: &str, body: &str) {
    let path = dir.join(name);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, body).unwrap();
}

/// The whole architecture in one test: Lua declares the policy and the tool,
/// Rust boots the VM, and the tool's `ctx.sh` runs in the guest.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn a_lua_tool_runs_its_commands_inside_the_microvm() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let workspace = root.join("workspace");
    std::fs::create_dir_all(&workspace).unwrap();
    std::fs::write(workspace.join("from_host.txt"), "written by the host\n").unwrap();

    write(
        root,
        "sandbox.lua",
        r#"
        sandbox {
          name = "reve-it-lua",
          image = "alpine",
          cpus = 1,
          memory = 512,
          provision = false,
          allow = { "github.com" },
        }
    "#,
    );
    write(
        root,
        "tools/probe.lua",
        r#"
        tool("probe", {
          description = "Report on the machine the agent is actually running on",
          replay = "safe",
          params = {
            { name = "path", type = "string", default = "from_host.txt" },
          },
          run = function(args, ctx)
            local kernel = ctx.sh("uname -s")
            local cwd = ctx.sh("pwd")
            local seen = ctx.sh("cat " .. ctx.shellescape(args.path))
            ctx.sh("echo 'written by the guest' > from_guest.txt")
            return kernel .. cwd .. seen
          end,
        })
    "#,
    );

    let mut rt = Runtime::new().unwrap();
    rt.load_sandbox(&root.join("sandbox.lua")).unwrap();
    rt.load_tools(&root.join("tools")).unwrap();
    assert_eq!(rt.policy.image, "alpine", "Lua drove the policy");

    let sandbox = Arc::new(
        Sandbox::start(rt.policy.clone(), &workspace, root.join(".reve"), &Silent)
            .await
            .expect("the microVM must boot"),
    );

    let out = rt
        .call_tool("probe", serde_json::Map::new(), sandbox.clone())
        .await
        .expect("the tool runs");

    assert!(
        out.contains("Linux"),
        "the tool ran in the guest kernel: {out:?}"
    );
    assert!(
        out.contains("/workspace"),
        "and in the mounted workspace: {out:?}"
    );
    assert!(
        out.contains("written by the host"),
        "the bind mount is readable: {out:?}"
    );
    assert_eq!(
        std::fs::read_to_string(workspace.join("from_guest.txt"))
            .unwrap()
            .trim(),
        "written by the guest",
        "and writable, straight through to the host"
    );

    sandbox.stop().await.unwrap();
    let _ = microsandbox::Sandbox::remove("reve-it-lua").await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn a_released_microvm_restarts_on_the_next_effect() {
    let dir = tempfile::tempdir().unwrap();
    let workspace = dir.path().join("workspace");
    let policy = reve::sandbox::Policy {
        name: Some("reve-it-lazy".into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        ..Default::default()
    };
    let sandbox = Sandbox::start(policy, &workspace, dir.path().join(".reve"), &Silent)
        .await
        .expect("the microVM must boot");

    sandbox.stop().await.expect("release the idle VM");
    let output = sandbox
        .exec("printf lazy-restart", ExecOptions::default(), None)
        .await
        .expect("the first effect restarts it");
    assert!(output.success);
    assert_eq!(output.stdout, "lazy-restart");

    sandbox.stop().await.unwrap();
    let _ = microsandbox::Sandbox::remove("reve-it-lazy").await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn simultaneous_tools_share_one_running_microvm() {
    let dir = tempfile::tempdir().unwrap();
    let workspace = dir.path().join("workspace");
    let policy = reve::sandbox::Policy {
        name: Some("reve-it-shared".into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        ..Default::default()
    };
    let sandbox = Arc::new(
        Sandbox::start(policy, &workspace, dir.path().join(".reve"), &Silent)
            .await
            .expect("the microVM must boot"),
    );

    let first = sandbox.exec("sleep 0.2; printf first", ExecOptions::default(), None);
    let second = sandbox.exec("printf second", ExecOptions::default(), None);
    let (first, second) = tokio::join!(first, second);
    let first = first.expect("the first tool shares the VM");
    let second = second.expect("the second tool shares the VM");
    assert!(first.success);
    assert!(second.success);
    assert_eq!(first.stdout, "first");
    assert_eq!(second.stdout, "second");

    sandbox.stop().await.unwrap();
    let _ = microsandbox::Sandbox::remove("reve-it-shared").await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn an_effect_waits_for_an_in_progress_stop_before_restarting() {
    let dir = tempfile::tempdir().unwrap();
    let workspace = dir.path().join("workspace");
    let name = "reve-it-stop-race";
    let policy = reve::sandbox::Policy {
        name: Some(name.into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        ..Default::default()
    };
    let sandbox = Arc::new(
        Sandbox::start(policy, &workspace, dir.path().join(".reve"), &Silent)
            .await
            .expect("the microVM must boot"),
    );

    let long_sandbox = Arc::clone(&sandbox);
    let long = tokio::spawn(async move {
        long_sandbox
            .exec("sleep 5", ExecOptions::default(), None)
            .await
    });
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let stopping_sandbox = Arc::clone(&sandbox);
    let stopping = tokio::spawn(async move { stopping_sandbox.stop().await });

    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            if let Ok(handle) = microsandbox::Sandbox::get(name).await
                && matches!(
                    handle.status_snapshot(),
                    microsandbox::sandbox::SandboxStatus::Draining
                )
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the running command keeps the stop transition observable");

    let restarted = sandbox
        .exec("printf restarted", ExecOptions::default(), None)
        .await
        .expect("the effect waits for stop instead of racing start against it");
    assert!(restarted.success);
    assert_eq!(restarted.stdout, "restarted");

    let _ = long.await;
    stopping.await.unwrap().unwrap();
    sandbox.stop().await.unwrap();
    let _ = microsandbox::Sandbox::remove(name).await;
}

/// Deny-by-default is the claim the README makes; this is the claim being true.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn egress_reaches_an_allowed_host_and_nothing_else() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let workspace = root.join("workspace");

    let policy = reve::sandbox::Policy {
        name: Some("reve-it-net".into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        allow_hosts: vec!["github.com".into(), "deb.debian.org".into()],
        ..Default::default()
    };
    let sandbox = Sandbox::start(policy, &workspace, root.join(".reve"), &Silent)
        .await
        .expect("the microVM must boot");

    let allowed = sandbox
        .exec(
            "wget -q -T 20 -O /dev/null https://github.com/ && echo ALLOWED || echo BLOCKED",
            ExecOptions::default(),
            None,
        )
        .await
        .unwrap();
    assert_eq!(
        allowed.stdout.trim(),
        "ALLOWED",
        "the named host is reachable"
    );

    let debian = sandbox
        .exec(
            "wget -q -T 20 -O /dev/null https://deb.debian.org/debian/README && echo ALLOWED || echo BLOCKED",
            ExecOptions::default(),
            None,
        )
        .await
        .unwrap();
    assert_eq!(
        debian.stdout.trim(),
        "ALLOWED",
        "an explicitly named Debian package host is reachable"
    );

    let blocked = sandbox
        .exec(
            "wget -q -T 12 -O /dev/null https://example.com/ && echo REACHED || echo BLOCKED",
            ExecOptions::default(),
            None,
        )
        .await
        .unwrap();
    assert_eq!(blocked.stdout.trim(), "BLOCKED", "an unlisted host is not");

    sandbox.stop().await.unwrap();
    let _ = microsandbox::Sandbox::remove("reve-it-net").await;
}

/// `/abort` has to stop real work, not just stop waiting for it.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn cancelling_kills_the_guest_command() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let workspace = root.join("workspace");

    let policy = reve::sandbox::Policy {
        name: Some("reve-it-cancel".into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        ..Default::default()
    };
    let sandbox = Sandbox::start(policy, &workspace, root.join(".reve"), &Silent)
        .await
        .expect("the microVM must boot");

    let (tx, rx) = tokio_util_lite::channel();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(800)).await;
        tx.cancel();
    });

    let started = std::time::Instant::now();
    let out = sandbox
        .exec("sleep 120", ExecOptions::default(), Some(rx))
        .await
        .unwrap();
    let elapsed = started.elapsed();

    assert!(out.cancelled, "the result says it was cancelled");
    assert!(
        elapsed.as_secs() < 10,
        "and it came back promptly: {elapsed:?}"
    );

    // The point of killing rather than abandoning: nothing survives in the guest.
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let survivors = sandbox
        .exec(
            "ps -o args= | grep -c '[s]leep 120'",
            ExecOptions::default(),
            None,
        )
        .await
        .unwrap();
    assert_eq!(survivors.stdout.trim(), "0", "the guest command is gone");

    // And the VM is still usable, so nothing is wedged behind a held handle.
    let after = sandbox
        .exec("echo still alive", ExecOptions::default(), None)
        .await
        .unwrap();
    assert_eq!(after.stdout.trim(), "still alive");

    sandbox.stop().await.unwrap();
    let _ = microsandbox::Sandbox::remove("reve-it-cancel").await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn runtime_secrets_rotate_without_a_rebuild_and_deleted_secrets_are_revoked() {
    const NAME: &str = "reve-it-secret-runtime";
    const SOURCE: &str = "REVE_IT_HOST_SECRET_7A31";
    const GUEST: &str = "REVE_IT_GUEST_SECRET";
    let dir = tempfile::tempdir().unwrap();
    let workspace = dir.path().join("workspace");
    let state_dir = dir.path().join(".reve");
    let secret = Secret {
        env: GUEST.into(),
        source: SOURCE.into(),
        placeholder: Some("reve-secret-placeholder".into()),
        hosts: vec!["github.com".into()],
    };
    let policy = reve::sandbox::Policy {
        name: Some(NAME.into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        secrets: vec![secret],
        ..Default::default()
    };
    // SAFETY: this test owns a process-unique variable name.
    unsafe { std::env::set_var(SOURCE, "first-host-value") };
    let sandbox = Sandbox::start(policy.clone(), &workspace, &state_dir, &Silent)
        .await
        .expect("the microVM must boot");
    let fingerprint = policy.fingerprint(&workspace);

    let first = sandbox
        .exec(
            &format!("printf '%s' \"${GUEST}\"; cat /proc/sys/kernel/random/boot_id"),
            ExecOptions::default(),
            None,
        )
        .await
        .unwrap();
    assert!(first.stdout.starts_with("reve-secret-placeholder"));
    assert!(!first.stdout.contains("first-host-value"));
    std::fs::write(workspace.join("kept-across-restart"), "same disk").unwrap();
    let first_boot = first
        .stdout
        .strip_prefix("reve-secret-placeholder")
        .unwrap()
        .trim()
        .to_string();

    // SAFETY: same process-unique variable, with no concurrent reader outside this test.
    unsafe { std::env::set_var(SOURCE, "second-host-value") };
    assert_eq!(
        fingerprint,
        policy.fingerprint(&workspace),
        "runtime rotation does not alter the disk fingerprint"
    );
    let second = sandbox
        .exec(
            &format!(
                "printf '%s' \"${GUEST}\"; cat /proc/sys/kernel/random/boot_id; cat kept-across-restart"
            ),
            ExecOptions::default(),
            None,
        )
        .await
        .unwrap();
    assert!(second.stdout.starts_with("reve-secret-placeholder"));
    assert!(!second.stdout.contains("second-host-value"));
    assert!(!second.stdout.contains(&first_boot), "the VM restarted");
    assert!(
        second.stdout.ends_with("same disk"),
        "but its disk was reused"
    );

    sandbox.stop().await.unwrap();
    let without_secret = reve::sandbox::Policy {
        secrets: Vec::new(),
        ..policy
    };
    let sandbox = Sandbox::start(without_secret, &workspace, &state_dir, &Silent)
        .await
        .expect("the source-only definition is reusable");
    let revoked = sandbox
        .exec(
            &format!("test -z \"${{{GUEST}+x}}\" && printf revoked"),
            ExecOptions::default(),
            None,
        )
        .await
        .unwrap();
    assert_eq!(revoked.stdout, "revoked");

    sandbox.stop().await.unwrap();
    let _ = microsandbox::Sandbox::remove(NAME).await;
    // SAFETY: cleanup of the process-unique variable owned by this test.
    unsafe { std::env::remove_var(SOURCE) };
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn long_bash_output_is_spilled_to_guest_tmp() {
    const NAME: &str = "reve-it-output-spill";
    let dir = tempfile::tempdir().unwrap();
    let workspace = dir.path().join("workspace");
    let policy = reve::sandbox::Policy {
        name: Some(NAME.into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        ..Default::default()
    };
    let sandbox = Arc::new(
        Sandbox::start(policy, &workspace, dir.path().join(".reve"), &Silent)
            .await
            .expect("the microVM must boot"),
    );
    let toolbox = Toolbox::new(sandbox.clone(), Arc::new(Runtime::new().unwrap()));
    let args = serde_json::json!({ "command": "head -c 50000 /dev/zero | tr '\\0' x" })
        .as_object()
        .unwrap()
        .clone();
    let shown = toolbox.call("bash", args).await.unwrap();
    let spill = shown
        .lines()
        .find_map(|line| line.strip_prefix("… truncated at 24000 characters. Full output: "))
        .expect("the model receives the spill location");
    assert!(spill.starts_with("/tmp/reve-tool-output-"), "{spill}");
    let full = sandbox.read_file(spill).await.unwrap();
    assert_eq!(full.len(), 50_000);
    assert!(shown.len() < full.len());

    sandbox.stop().await.unwrap();
    let _ = microsandbox::Sandbox::remove(NAME).await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn ordinary_environment_refreshes_without_rebuilding_the_vm() {
    const NAME: &str = "reve-it-runtime-env";
    let dir = tempfile::tempdir().unwrap();
    let workspace = dir.path().join("workspace");
    let state_dir = dir.path().join(".reve");
    let mut first = reve::sandbox::Policy {
        name: Some(NAME.into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        ..Default::default()
    };
    first
        .env
        .insert("REVE_RUNTIME_VALUE".into(), "first".into());
    let fingerprint = first.fingerprint(&workspace);
    let sandbox = Sandbox::start(first, &workspace, &state_dir, &Silent)
        .await
        .expect("the microVM must boot");
    let initial = sandbox
        .exec(
            "printf '%s' \"$REVE_RUNTIME_VALUE\"; printf same-disk > /runtime-env-marker",
            ExecOptions::default(),
            None,
        )
        .await
        .unwrap();
    assert_eq!(initial.stdout, "first");
    sandbox.stop().await.unwrap();

    let mut second = reve::sandbox::Policy {
        name: Some(NAME.into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        ..Default::default()
    };
    second
        .env
        .insert("REVE_RUNTIME_VALUE".into(), "second".into());
    assert_eq!(fingerprint, second.fingerprint(&workspace));
    let sandbox = Sandbox::start(second, &workspace, &state_dir, &Silent)
        .await
        .expect("the existing root disk is reusable");
    let refreshed = sandbox
        .exec(
            "printf '%s:' \"$REVE_RUNTIME_VALUE\"; cat /runtime-env-marker",
            ExecOptions::default(),
            None,
        )
        .await
        .unwrap();
    assert_eq!(refreshed.stdout, "second:same-disk");

    sandbox.stop().await.unwrap();
    let _ = microsandbox::Sandbox::remove(NAME).await;
}
