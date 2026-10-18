-- Dev-checkout resolution: per-plugin base dir, git worktree/container
-- detection, and the persisted per-plugin dev choice
-- (stdpath("state")/dash-paq/dev.json).
local M = {}

local spec_mod = require("dash_paq.loader.spec")
local git = require("dash_paq.git")
local fs = require("dash_paq.fs")

-- The per-plugin base dir a dev entry resolves against: `entry.dev_base`
-- (set by loader/spec.lua when `spec.dev` is a string) if present, else the
-- shared `dev.path/<name>` convention.
function M.base_dir_for(entry, dev_cfg)
  if type(entry.dev_base) == "string" and entry.dev_base ~= "" then
    return entry.dev_base
  end
  return spec_mod.dev_path_for(entry.name, dev_cfg)
end

-- Runs a git subcommand in `cwd`, never raising: a missing `git` binary
-- (ENOENT) is caught by `pcall` rather than aborting `setup()`. Returns the
-- `vim.system` result, or nil on any failure to even launch the process.
local function run_git(args, cwd)
  local ok, result = pcall(function()
    return git.run(args, { cwd = cwd, text = true }):wait()
  end)
  if not ok then
    return nil
  end
  return result
end

-- True when `base` (whose `.git` is a file, i.e. a `gitdir:` pointer) itself
-- resolves to a bare repository, as with a `.bare`-backed worktree
-- container (`base/.bare` + `base/.git` -> `gitdir: ./.bare`). False on any
-- git failure (missing binary, not a repo at all), so an ordinary linked
-- worktree's pointer file keeps classifying as "worktree" below.
function M.is_bare_repo(base)
  local result = run_git({ "rev-parse", "--is-bare-repository" }, base)
  if not result or result.code ~= 0 then
    return false
  end
  return vim.trim(result.stdout or "") == "true"
end

-- True when `path/.git` exists, as a directory (a normal clone/worktree
-- root) or a file (a linked worktree's `gitdir:` pointer).
function M.is_git_dir(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local stat = vim.uv.fs_stat(vim.fs.joinpath(path, ".git"))
  return stat ~= nil and (stat.type == "directory" or stat.type == "file")
end

-- The first immediate child directory of `path` (name order) that is itself
-- a git dir, or nil. `path` itself must not already be a git dir.
function M.container_child(path)
  if type(path) ~= "string" or path == "" or M.is_git_dir(path) then
    return nil
  end
  local ok, entries = pcall(vim.fn.readdir, path)
  if not ok or type(entries) ~= "table" then
    return nil
  end
  table.sort(entries)
  for _, name in ipairs(entries) do
    local child = vim.fs.joinpath(path, name)
    if vim.fn.isdirectory(child) == 1 and M.is_git_dir(child) then
      return child
    end
  end
  return nil
end

-- Classifies a dev base dir: "worktree" (`base` itself is a checkout: a
-- `.git` dir, or a `.git` file whose target isn't bare), "container" (`base`
-- isn't a checkout but either has one as an immediate child, or its `.git`
-- file resolves to a bare repo, as with a `.bare`-backed worktree layout),
-- "plain" (an existing non-git directory), or "missing" (not a directory at
-- all). Returns `kind, git_dir`, where `git_dir` is the path `git worktree
-- list` should run against (nil for "plain"/"missing").
function M.classify_base(base)
  if type(base) ~= "string" or base == "" or vim.fn.isdirectory(base) ~= 1 then
    return "missing", nil
  end
  local git_stat = vim.uv.fs_stat(vim.fs.joinpath(base, ".git"))
  if git_stat then
    if git_stat.type == "directory" then
      return "worktree", base
    end
    if git_stat.type == "file" then
      -- A `.git` *file* either points at a normal linked worktree (base is
      -- itself a checkout) or, for a `.bare`-backed layout, at a bare repo
      -- (base is a container: git commands still resolve fine with cwd =
      -- base, but base has no working files of its own).
      if M.is_bare_repo(base) then
        return "container", base
      end
      return "worktree", base
    end
  end
  local child = M.container_child(base)
  if child then
    return "container", child
  end
  return "plain", nil
end

-- Human label for one worktree entry: "<branch>  <path>", "@<short-head>
-- <path>" when detached, or the bare path when neither is known (a plain,
-- non-git candidate).
local function candidate_label(entry)
  if type(entry.branch) == "string" and entry.branch ~= "" then
    return string.format("%s  %s", entry.branch, entry.path)
  end
  if type(entry.head) == "string" and not entry.head:match("^0+$") then
    return string.format("@%s  %s", entry.head:sub(1, 8), entry.path)
  end
  return entry.path
end

-- Parse `git worktree list --porcelain -z`. NUL delimiters keep quoted or
-- multiline paths intact; callers filter missing and bare worktrees.
function M.parse_worktree_porcelain(output)
  local entries = {}
  local current = nil
  for _, line in ipairs(vim.split(output or "", "\0", { plain = true, trimempty = false })) do
    if line == "" then
      current = nil
    elseif line:match("^worktree ") then
      current = { path = line:sub(#"worktree " + 1) }
      entries[#entries + 1] = current
    elseif current then
      if line == "bare" then
        current.bare = true
      elseif line:match("^branch ") then
        current.branch = line:sub(#"branch " + 1):gsub("^refs/heads/", "")
      elseif line:match("^HEAD ") then
        current.head = line:sub(#"HEAD " + 1)
      end
    end
  end
  return entries
end

-- Runs `git worktree list --porcelain -z` against `git_dir` (with a clean git
-- env) and returns the existing, non-bare worktrees (main worktree
-- first, as git reports them), each with a normalized `path` and a
-- ready `label` for `vim.ui.select`. Empty on any git failure, including a
-- missing `git` binary.
function M.list_worktrees(git_dir)
  local result = run_git({ "worktree", "list", "--porcelain", "-z" }, git_dir)
  if not result or result.code ~= 0 then
    return {}
  end
  local out = {}
  for _, entry in ipairs(M.parse_worktree_porcelain(result.stdout)) do
    if not entry.bare and type(entry.path) == "string" and entry.path ~= "" and vim.fn.isdirectory(entry.path) == 1 then
      entry.path = fs.real_path(entry.path)
      entry.label = candidate_label(entry)
      out[#out + 1] = entry
    end
  end
  return out
end

-- Candidate checkout dirs for `base`: `git worktree list` entries for a
-- "worktree"/"container" base, or a single `{path, label}` candidate for a
-- "plain" existing directory. Empty when `base` is missing.
function M.candidates_for(base)
  local kind, git_dir = M.classify_base(base)
  if kind == "missing" then
    return {}, kind
  end
  if kind == "plain" then
    local normalized = fs.real_path(base)
    return { { path = normalized, label = normalized } }, kind
  end
  return M.list_worktrees(git_dir), kind
end

-- Runtime subdirectories Neovim sources from a plugin root. A dev dir holding
-- none of them is not a plugin checkout (an empty or unrelated directory).
local PLUGIN_DIRS = {
  "lua",
  "plugin",
  "after",
  "autoload",
  "colors",
  "compiler",
  "doc",
  "ftdetect",
  "ftplugin",
  "indent",
  "keymap",
  "lsp",
  "queries",
  "rplugin",
  "syntax",
}

-- True when `path` is a directory with at least one runtime subdirectory.
function M.is_plugin_dir(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  for _, name in ipairs(PLUGIN_DIRS) do
    if vim.fn.isdirectory(vim.fs.joinpath(path, name)) == 1 then
      return true
    end
  end
  return false
end

-- The dev dir to use when no saved choice (or an invalid one) applies.
-- "worktree"/"plain": `base` itself, as spelled. "container": the first
-- non-bare worktree of its git child/self. nil when `base` doesn't exist.
function M.default_dir(base)
  local kind, git_dir = M.classify_base(base)
  if kind == "missing" then
    return nil
  end
  if kind == "container" then
    local worktrees = M.list_worktrees(git_dir)
    return worktrees[1] and worktrees[1].path or nil
  end
  -- Loaded as spelled (only `~` expanded) so the rtp entry matches the
  -- configured path; comparisons normalize separately.
  return vim.fn.expand(base)
end

-- A saved path choice for a dev-capable entry is honored
-- only when it names -- after normalization -- one of `base`'s *current*
-- candidate checkouts, not merely any existing directory. This stops a
-- stale `L`-toggle choice from silently overriding a base that a spec
-- change has since pointed elsewhere. Returns the matching candidate's
-- normalized path, or nil when `choice` doesn't match any candidate.
function M.matching_candidate_path(base, choice)
  local normalized_choice = fs.real_path(choice)
  if not normalized_choice then
    return nil
  end
  for _, candidate in ipairs(M.candidates_for(base)) do
    if candidate.path == normalized_choice then
      return candidate.path
    end
  end
  return nil
end

function M.choices_path()
  return fs.state_path("dev.json")
end

-- Reads the saved per-plugin dev choices (name -> "upstream" | absolute
-- path). Tolerates a missing or corrupt file: both return an empty table.
function M.load_choices()
  local out = {}
  for name, value in pairs(fs.read_json(M.choices_path()) or {}) do
    if type(name) == "string" and name ~= "" and type(value) == "string" and value ~= "" then
      out[name] = value
    end
  end
  return out
end

-- Overwrites the saved choices file with `choices` (name -> "upstream" |
-- absolute path). Returns true on success.
function M.save_choices(choices)
  return fs.write_json(M.choices_path(), type(choices) == "table" and choices or {})
end

-- What a toggle should switch `base`'s plugin to: "upstream" when it currently
-- uses a dev checkout, else the dev checkout (`default_dir`). `choice` is the
-- saved dev.json value (the pending state: no live reload), `has_src` whether
-- an upstream clone exists to fall back to. Mirrors how the loader resolves a
-- choice: "upstream" counts only with a `src`; a path only while it names a
-- current candidate; anything else means the default dir (when it exists).
-- Returns the target ("upstream" | absolute path), or nil plus a reason.
function M.toggle_target(base, has_src, choice)
  local default = M.default_dir(base)
  local not_plugin = default ~= nil and not M.is_plugin_dir(default)
  if not_plugin then
    default = nil
  end
  local on_dev
  if choice == "upstream" and has_src then
    on_dev = false
  elseif type(choice) == "string" and choice ~= "upstream" then
    local matched = M.matching_candidate_path(base, choice)
    on_dev = matched ~= nil and M.is_plugin_dir(matched)
    if not on_dev then
      on_dev = default ~= nil
    end
  else
    on_dev = default ~= nil
  end
  if on_dev then
    if not has_src then
      return nil, "no upstream (src) to switch to"
    end
    return "upstream"
  end
  if not default then
    if not_plugin then
      return nil, tostring(base) .. " is not a plugin directory"
    end
    return nil, "no dev checkout found at " .. tostring(base)
  end
  return M.matching_candidate_path(base, default) or default
end

-- Top-level Lua modules `dir` provides: the entries of `dir/lua`, with a
-- `.lua` suffix stripped (`lua/foo/` and `lua/foo.lua` both give `foo`).
local function lua_modules(dir)
  local ok, entries = pcall(vim.fn.readdir, vim.fs.joinpath(dir, "lua"))
  if not ok or type(entries) ~= "table" then
    return {}
  end
  local out = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = entry:gsub("%.lua$", "")
  end
  return out
end

-- Why switching `name` to its installed `vim.pack` clone would leave it
-- unloadable, or nil when it looks fine. Not installed counts as fine: the
-- restart installs it. An installed clone must be a plugin directory and,
-- when `dev_dir` (the checkout being left) has Lua modules, provide at least
-- one of them -- otherwise the clone predates the dev checkout (for example a
-- rename not yet pushed) and `require` would fail on the next start.
function M.upstream_problem(name, dev_dir)
  local ok, plugins = pcall(vim.pack.get, { name }, { info = false })
  local clone = ok and type(plugins) == "table" and plugins[1] and plugins[1].path or nil
  if type(clone) ~= "string" or vim.fn.isdirectory(clone) ~= 1 then
    return nil
  end
  if not M.is_plugin_dir(clone) then
    return string.format("the upstream clone at %s is not a plugin directory", clone)
  end
  local wanted = type(dev_dir) == "string" and lua_modules(dev_dir) or {}
  if #wanted == 0 then
    return nil
  end
  for _, module in ipairs(wanted) do
    local base = vim.fs.joinpath(clone, "lua", module)
    if vim.fn.isdirectory(base) == 1 or vim.fn.filereadable(base .. ".lua") == 1 then
      return nil
    end
  end
  return string.format(
    "the upstream clone at %s has none of lua/%s that the dev checkout provides; update or push upstream first",
    clone,
    table.concat(wanted, ", lua/")
  )
end

-- Saves `name`'s dev choice ("upstream" or an absolute path) to dev.json, then
-- offers a `:restart` (no live reload: a restart is the only clean switch) via
-- `vim.fn.confirm`. A switch to "upstream" is refused with a WARN, and nothing
-- is saved, when `upstream_problem` finds the clone unusable. A failed write is
-- reported with an ERROR notify and skips the restart prompt, since
-- restarting would apply nothing. Returns whether the choice was saved.
-- `hooks` (confirm/restart) let tests stub the UI; `hooks.from` optionally
-- names what the plugin switches away from, shown in the prompt;
-- `hooks.dev_dir` is the dev checkout being left, if any, for the clone check.
function M.set_choice(name, target, hooks)
  hooks = hooks or {}
  if target == "upstream" then
    local problem = M.upstream_problem(name, hooks.dev_dir)
    if problem then
      vim.notify(string.format("%s: not switching to upstream: %s", name, problem), vim.log.levels.WARN)
      return false
    end
  end
  local confirm_fn = hooks.confirm or vim.fn.confirm
  local restart_fn = hooks.restart or function()
    vim.cmd("restart")
  end

  local choices = M.load_choices()
  choices[name] = target
  if not M.save_choices(choices) then
    vim.notify(name .. ": failed to save dev choice to " .. M.choices_path(), vim.log.levels.ERROR)
    return false
  end
  local change = hooks.from and string.format("switching from %s to %s", hooks.from, target)
    or string.format("switching to %s", target)
  local msg = string.format("%s: %s.\nRestart now to apply?", name, change)
  if confirm_fn(msg, "&Yes\n&No", 2) == 1 then
    local ok, err = pcall(restart_fn)
    if not ok then
      vim.notify("Restart failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  return true
end

return M
