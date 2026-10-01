-- Local-only git fixture builder: a bare "remote" plus a working checkout, built with real `git` commands (no
-- network). Pins identity and signing so fixture creation never depends on the host's git config.
local M = {}

local GIT_IDENTITY = {
  "-c",
  "user.name=dash-paq-tests",
  "-c",
  "user.email=tests@dash-paq.invalid",
  "-c",
  "commit.gpgsign=false",
  "-c",
  "tag.gpgsign=false",
}

local function run(args, cwd)
  local result = vim.system(args, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    error(
      string.format(
        "gitfixture: `%s` failed (cwd=%s): %s",
        table.concat(args, " "),
        tostring(cwd),
        vim.trim(result.stderr or result.stdout or "")
      ),
      0
    )
  end
  return vim.trim(result.stdout or "")
end

local counter = 0
local function tmp_dir(label)
  counter = counter + 1
  local uv = vim.uv or vim.loop
  local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  local dir = string.format("%s/dash-paq-fixtures/%d-%d-%s", base, uv.os_getpid(), counter, label or "d")
  vim.fn.mkdir(dir, "p")
  return dir
end

M.tmp_dir = tmp_dir

-- Exposes the internal git runner for fixture code that needs a git
-- subcommand beyond this module's own helpers (e.g. `checkout`, `worktree`).
M.run = run

-- Creates a bare remote + working checkout on a pinned "main" branch (never
-- relies on the host's `init.defaultBranch`). Returns `{ bare, work, src }`.
function M.new_remote(name)
  local bare = tmp_dir((name or "remote") .. "-bare") .. ".git"
  vim.fn.delete(bare, "rf")
  run({ "git", "init", "--quiet", "--bare", bare })

  local work = tmp_dir((name or "remote") .. "-work")
  vim.fn.delete(work, "rf")
  run({ "git", "init", "--quiet", "--initial-branch=main", work })
  run({ "git", "-C", work, "remote", "add", "origin", bare })

  return { bare = bare, work = work, src = "file://" .. bare }
end

-- Writes and commits `files` (path -> content, empty/nil for an empty commit); returns the SHA.
function M.commit(remote, message, files)
  for path, content in pairs(files or {}) do
    local full = vim.fs.joinpath(remote.work, path)
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    vim.fn.writefile(vim.split(content, "\n"), full)
  end

  local args = { "git", "-C", remote.work }
  vim.list_extend(args, GIT_IDENTITY)
  vim.list_extend(args, { "add", "-A" })
  run(args)

  args = { "git", "-C", remote.work }
  vim.list_extend(args, GIT_IDENTITY)
  vim.list_extend(args, { "commit", "--quiet", "--allow-empty", "-m", message })
  run(args)

  return run({ "git", "-C", remote.work, "rev-parse", "HEAD" })
end

-- Checks out (creating/resetting) `branch` in `remote.work`, then writes and
-- commits `files` on it (same shape as `M.commit`), giving a second worktree
-- branch its own distinguishable content.
function M.commit_on_branch(remote, branch, message, files)
  local args = { "git", "-C", remote.work }
  vim.list_extend(args, GIT_IDENTITY)
  vim.list_extend(args, { "checkout", "-B", branch })
  run(args)
  return M.commit(remote, message, files)
end

-- Checks out `branch` in `remote.work` (the main worktree), e.g. to free it
-- up before `M.add_worktree` checks that same branch out elsewhere.
function M.checkout(remote, branch)
  local args = { "git", "-C", remote.work }
  vim.list_extend(args, GIT_IDENTITY)
  vim.list_extend(args, { "checkout", branch })
  run(args)
end

-- Adds a linked worktree for an already-existing `branch` at `path` (must
-- not be checked out anywhere else already, e.g. call `M.checkout` on the
-- main worktree first if it's currently on `branch`).
function M.add_worktree(remote, path, branch)
  local args = { "git", "-C", remote.work }
  vim.list_extend(args, GIT_IDENTITY)
  vim.list_extend(args, { "worktree", "add", path, branch })
  run(args)
  return path
end

function M.tag(remote, tag_name)
  local args = { "git", "-C", remote.work }
  vim.list_extend(args, GIT_IDENTITY)
  vim.list_extend(args, { "tag", tag_name })
  run(args)
end

-- Pushes `branch` (default "main") and every tag, then points the bare repo's
-- HEAD at it so `origin/HEAD` resolves in any later clone.
function M.push(remote, branch)
  branch = branch or "main"
  run({ "git", "-C", remote.work, "push", "--quiet", "origin", "HEAD:refs/heads/" .. branch })
  run({ "git", "-C", remote.work, "push", "--quiet", "--force", "--tags", "origin" })
  run({ "git", "-C", remote.bare, "symbolic-ref", "HEAD", "refs/heads/" .. branch })
end

return M
