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
--
-- The default image already contains the toolchain -- rust, go, node, bun,
-- pnpm, python, and mise to add more -- so there is no provisioning step and
-- the first command runs as soon as the VM boots. Point `image` at a bare
-- distro instead and set `provision = true` to get the install-on-first-boot
-- behaviour back.

sandbox {
  image = "ghcr.io/tobi/wrap:latest",
  cpus = 2,
  memory = 2048,
  -- The writable rootfs layer, in MiB. A real build tree needs room.
  root_disk = 16384,

  allow = {
    "github.com",
    "api.github.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
    "raw.githubusercontent.com",
    -- mise, for installing a toolchain the image does not already have.
    "mise.run",
    "mise.jdx.dev",
    "registry.npmjs.org",
    "nodejs.org",
    -- Arch mirrors, for `pacman -S` inside the guest.
    "geo.mirror.pkgbuild.com",
    "mirror.osbeck.com",
  },

  -- A credential the VM may use without ever holding it: the guest sees only
  -- the placeholder and the proxy substitutes the real value for these hosts.
  -- The image has no `gh`, so git reads this straight from the environment
  -- through a credential helper. Export it first:
  --   export GITHUB_TOKEN="$(gh auth token)"
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
