-- Every tools/*.lua file is trusted launch code, loaded before any work runs.
-- There is no plugin manifest and no registry to edit: drop in a file.
--
-- The Lua body runs on the host, but `ctx.sh` executes in the microVM. That is
-- the only command path a tool has.

tool("example", {
  description = "Summarize the working tree: branch, status, and recent commits",
  replay = "safe", -- read-only, so recovery may re-run it

  params = {
    { name = "commits", type = "integer", description = "How many commits to list", default = 5 },
  },

  run = function(args, ctx)
    local branch = ctx.sh("git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(no repo)'")
    local status = ctx.sh("git status --short 2>/dev/null || true")
    local log = ctx.sh("git log --oneline -n " .. tostring(args.commits) .. " 2>/dev/null || true")

    if status == "" then status = "(clean)\n" end
    return ("branch: %sstatus:\n%s\nrecent commits:\n%s"):format(branch, status, log)
  end,
})
