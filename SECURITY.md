# Security policy

Leve executes model-authored code, so sandbox boundary failures and credential disclosure
are security issues, not ordinary bugs.

## Supported versions

Security fixes are provided for the latest released version. Until a stable 1.0 release,
users should update to the newest 0.x release rather than expecting fixes on older minors.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's private
security advisory form:

<https://github.com/tobi/leve/security/advisories/new>

Include the Leve version (`leve --version`), operating system, the pinned `microsandbox`
crate version (`=0.6.8`, the only sandbox dependency, declared in `Cargo.toml`), reproduction
steps, and potential impact. Remove API keys, model transcripts, session contents, and
other private workspace data from reports.

Reports involving a host command escape, workspace bind escape, unscoped secret exposure,
network-policy bypass, durable-record corruption, or recovery replay of an effectful tool
will be treated as high priority. You can expect acknowledgment within seven days and a
status update after the report has been reproduced.

## Security model

Leve deliberately fails closed:

- Every command a tool issues — `ctx.sh` — and every `leve exec` runs in the same mandatory
  microsandbox microVM. There is no host-shell, local, CLI, or FFI fallback.
- The sandbox is provided exclusively by the `microsandbox` Rust crate, pinned `=0.6.8` in
  `Cargo.toml`. It is Leve's only sandbox dependency, linked and called directly — no FFI
  shim, no daemon, no CLI transport.
- Only `workspace/` is bind-mounted into the VM, at `/workspace`, and set as the working
  directory. The agent's own definition files stay outside the mount.
- Network access is deny-by-default. The policy is built in Rust from
  `NetworkPolicy::none()` — deny both directions — plus one narrow gateway-DNS rule plus
  one allow rule per host named by `sandbox.lua`. Nothing in the crate can widen it to
  "the internet". GitHub hosts are reachable by default; `allow` is additive on top.
- Secrets are scoped per host. The guest sees only the placeholder; the real value is
  injected into requests to the named hosts at the network boundary. An unscoped secret
  (no `hosts`) is refused at load time. Secrets are hashed into the VM fingerprint, never
  stored in cleartext.
- Durable intent records are written before effects so recovery does not guess whether an
  effectful operation should be replayed.

The host Rust process, the Lua launch code (`agent.lua`, `sandbox.lua`, `tools/*.lua`), the
configured model providers, and the upstream microsandbox runtime remain trusted
components. Lua launch code runs on the host and is not model output; install an agent's
tools only as trusted code. They do not authorize model-authored host commands — there is
no host command path exposed to Lua.
