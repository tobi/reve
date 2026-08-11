-- The sandbox every command runs in.
--
-- workspace/ is mounted at /workspace and is the working directory, so a
-- relative path means the same thing on the host and in the VM. The agent's
-- own definition files stay outside it.
--
-- The microVM is mandatory: Reve links the microsandbox Rust crate directly
-- and refuses to run without it. There is no host or local mode.
--
-- Egress starts with deny-all. Every reachable hostname must be listed here;
-- provisioning does not add hidden exceptions.

sandbox {
  image = "debian:trixie-slim",
  cpus = 2,
  memory = 2048,

  allow = {
    "github.com",
    "api.github.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
    "raw.githubusercontent.com",
    "deb.debian.org",
    "security.debian.org",
    "ftp.debian.org",
    "mise.run",
    "mise.jdx.dev",
    "registry.npmjs.org",
    "nodejs.org",
  },

  -- A credential the VM may use without ever holding it: the guest sees only
  -- the placeholder and the proxy substitutes the real value for these hosts.
  -- `gh` keeps its token in the OS keyring, so export it first:
  --   export GITHUB_TOKEN="$(gh auth token --hostname github.com)"
  secrets = {
    {
      env = "GITHUB_TOKEN",
      source = "GITHUB_TOKEN",
      placeholder = "reve-github-token",
      hosts = { "github.com", "api.github.com" },
    },
  },

  -- bootstrap = { "npm ci" },
}
