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

use leve::lua::Runtime;
use leve::sandbox::{ExecOptions, Sandbox, Silent, tokio_util_lite};

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
          name = "leve-it-lua",
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
        Sandbox::start(rt.policy.clone(), &workspace, root.join(".leve"), &Silent)
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
    let _ = microsandbox::Sandbox::remove("leve-it-lua").await;
}

/// Deny-by-default is the claim the README makes; this is the claim being true.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn egress_reaches_an_allowed_host_and_nothing_else() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let workspace = root.join("workspace");

    let policy = leve::sandbox::Policy {
        name: Some("leve-it-net".into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        allow_hosts: vec!["github.com".into()],
        ..Default::default()
    };
    let sandbox = Sandbox::start(policy, &workspace, root.join(".leve"), &Silent)
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
    let _ = microsandbox::Sandbox::remove("leve-it-net").await;
}

/// `/abort` has to stop real work, not just stop waiting for it.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "boots a real microVM"]
async fn cancelling_kills_the_guest_command() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let workspace = root.join("workspace");

    let policy = leve::sandbox::Policy {
        name: Some("leve-it-cancel".into()),
        image: "alpine".into(),
        cpus: 1,
        memory: 512,
        provision: false,
        ..Default::default()
    };
    let sandbox = Sandbox::start(policy, &workspace, root.join(".leve"), &Silent)
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
    let _ = microsandbox::Sandbox::remove("leve-it-cancel").await;
}
