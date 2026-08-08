# Security policy

Reve executes model-authored code, so sandbox boundary failures and credential disclosure
are security issues, not ordinary bugs.

## Supported versions

Security fixes are provided for the latest released version. Until a stable 1.0 release,
users should update to the newest 0.x release rather than expecting fixes on older minors.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's private
security advisory form:

<https://github.com/tobi/reve/security/advisories/new>

Include the Reve version, operating system, microsandbox-rb version, reproduction steps,
and potential impact. Remove API keys, model transcripts, session contents, and other
private workspace data from reports.

Reports involving a host command escape, workspace bind escape, unscoped secret exposure,
network-policy bypass, durable-record corruption, or recovery replay of an effectful tool
will be treated as high priority. You can expect acknowledgment within seven days and a
status update after the report has been reproduced.

## Security model

Reve deliberately fails closed:

- Model `bash`, project context commands, and interactive `!command` execute in the same
  mandatory microsandbox microVM.
- There is no host/local execution fallback.
- Only `workspace/` is bind-mounted into the VM.
- Network access is deny-by-default and secrets are substituted only for explicitly scoped
  hosts.
- Durable intent records are written before effects so recovery does not guess whether an
  effectful operation should be replayed.

The host Ruby process, the configured model providers, the `microsandbox-rb` native
extension, and the upstream microsandbox runtime remain trusted components.
