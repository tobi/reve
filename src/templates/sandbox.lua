-- The sandbox every command runs in.
--
-- workspace/ is mounted at /workspace and is the working directory, so a
-- relative path means the same thing on the host and in the VM. The agent's
-- own definition files stay outside it.
--
-- The microVM is mandatory: leve links the microsandbox Rust crate directly
-- and refuses to run without it. There is no host or local mode.
--
-- Egress is deny-by-default. `allow` adds to the GitHub hosts that are
-- reachable out of the box; it never opens the whole internet.

sandbox {
  image = "debian:trixie-slim",
  cpus = 2,
  memory = 2048,

  allow = { "api.github.com" },

  -- A credential the VM may use without ever holding it: the guest sees only
  -- the placeholder and the proxy substitutes the real value for these hosts.
  -- `gh` keeps its token in the OS keyring, so export it first:
  --   export GITHUB_TOKEN="$(gh auth token --hostname github.com)"
  secrets = {
    {
      env = "GITHUB_TOKEN",
      value = os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN") or "",
      placeholder = "leve-github-token",
      hosts = { "github.com", "api.github.com" },
    },
  },

  -- bootstrap = { "npm ci" },
}
