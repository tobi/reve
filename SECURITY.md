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

Include the Leve version, operating system, the pinned `microsandbox` crate version
(`Leve::Sandbox::Native::MICROSANDBOX_VERSION`), reproduction steps, and potential impact.
Remove API keys, model transcripts, session contents, and other private workspace data
from reports.

Reports involving a host command escape, workspace bind escape, unscoped secret exposure,
network-policy bypass, durable-record corruption, or recovery replay of an effectful tool
will be treated as high priority. You can expect acknowledgment within seven days and a
status update after the report has been reproduced.

## Security model

Leve deliberately fails closed:

- Model `bash`, project context commands, and interactive `!command` execute in the same
  mandatory microsandbox microVM.
- There is no host/local execution fallback, no CLI transport, and no Fiddle path.
- The sandbox is provided exclusively by the in-repo `ext/leve_sandbox` native extension
  binding the `microsandbox` Rust crate (pinned `=0.6.8`). There is no Ruby gem dependency
  for the sandbox.
- Only `workspace/` is bind-mounted into the VM.
- Network access is deny-by-default. The policy is built inside the extension from
  `NetworkPolicy::none()` plus one narrow gateway-DNS rule plus one allow rule per host
  named by `allow`; nothing on the Ruby side can widen it. Secrets are substituted only for
  explicitly scoped hosts, and the guest sees only the placeholder.
- Durable intent records are written before effects so recovery does not guess whether an
  effectful operation should be replayed.

The host Ruby process, files under `tools/*.rb` and `channels/*.rb`, configured model
providers, the `ext/leve_sandbox` native extension, and the upstream microsandbox runtime
remain trusted components. Channel adapters intentionally perform host-side transport I/O;
install them only as trusted code. They do not authorize model-authored host commands.
