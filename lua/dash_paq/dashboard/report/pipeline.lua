-- Per-plugin refresh pipeline: for each managed plugin, run `git fetch` (unless
-- offline) followed by an offline status computation as one independent unit,
-- concurrently across plugins. A per-plugin callback fires the moment each
-- plugin resolves, so the dashboard can flip that one row's status inline
-- instead of waiting for a monolithic `vim.pack.update` over the whole set.
--
-- The status computation matches vim.pack's own version-resolution rules
-- (runtime/lua/vim/pack.lua's resolve_version + infer_revisions): HEAD vs the
-- resolved target ref decides update/same, so dashboard statuses agree with
-- what `vim.pack.update` itself would report.
local notify = require("dash_paq.dashboard.report.notify")
local gitcmd = require("dash_paq.dashboard.analysis.gitcmd")

local M = {}

-- Env used for every git shell-out below: clears `GIT_DIR`/`GIT_WORK_TREE` so
-- a caller's own git-repo env vars never redirect these calls, matching
-- upstream vim.pack's `git_cmd`.
local function clean_env()
  local env = vim.fn.environ()
  env.GIT_DIR = nil
  env.GIT_WORK_TREE = nil
  return env
end

local function git_capture(path, args, callback)
  local cmd = { "git", "-C", path, "-c", "gc.auto=0" }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true, env = clean_env(), clear_env = true }, function(out)
    if out.code ~= 0 then
      callback(nil, vim.trim(out.stderr or out.stdout or "git error"))
      return
    end
    callback((out.stdout or ""):gsub("\n+$", ""), nil)
  end)
end

local function is_version_range(v)
  return type(v) == "table" and type(v.has) == "function"
end

-- strict, like vim.pack
local function greatest_in_range(tags, range)
  local best_tag, best_v
  for _, tag in ipairs(tags) do
    local ok, v = pcall(vim.version.parse, tag, { strict = true })
    if ok and v and range:has(v) and (not best_v or vim.version.gt(v, best_v)) then
      best_tag, best_v = tag, v
    end
  end
  return best_tag
end

-- Resolve the Git ref that `version` points at, mirroring vim.pack's
-- `resolve_version`. Async because branch/tag resolution shells out to git.
-- Calls `done(ref, err)`.
local function resolve_target_ref(path, version, done)
  if version == nil then
    git_capture(path, { "rev-parse", "--abbrev-ref", "origin/HEAD" }, function(out, err)
      if not out then
        done(nil, err or "no default branch")
        return
      end
      done("origin/" .. (out:gsub("^origin/", "")), nil)
    end)
    return
  end

  if is_version_range(version) then
    git_capture(path, { "tag", "--list", "--sort=-v:refname" }, function(out, err)
      if not out then
        done(nil, err or "no tags")
        return
      end
      local tags = out == "" and {} or vim.split(out, "\n")
      local tag = greatest_in_range(tags, version)
      if not tag then
        done(nil, "no tag fits version constraint")
        return
      end
      done(tag, nil)
    end)
    return
  end

  if type(version) == "string" then
    -- Branch (use origin/<branch>) vs tag/commit (verbatim).
    git_capture(path, { "branch", "--remote", "--list", "--format=%(refname:short)", "--", "origin/**" }, function(out)
      local is_branch = false
      for line in vim.gsplit(out or "", "\n") do
        if line:match("^origin/(.+)$") == version then
          is_branch = true
          break
        end
      end
      done(is_branch and ("origin/" .. version) or version, nil)
    end)
    return
  end

  done(nil, "unsupported version type")
end

-- Compute one plugin's offline status (HEAD vs target). `online` controls
-- whether a `git fetch` runs first. `done(result)` receives:
--   { name, path, source, status, rev_before, rev_after, error }
local function refresh_one(target, online, env, done)
  local function finalize(status, rev_before, rev_after, err)
    done({
      name = target.name,
      path = target.path,
      source = target.source,
      status = status,
      rev_before = rev_before,
      rev_after = rev_after,
      error = err,
    })
  end

  local function compute_status()
    git_capture(target.path, { "rev-list", "-1", "HEAD" }, function(sha_head, head_err)
      if not sha_head then
        finalize("error", nil, nil, head_err or "failed to read HEAD")
        return
      end
      resolve_target_ref(target.path, target.version, function(ref, ref_err)
        if not ref then
          finalize("error", sha_head, nil, ref_err or "failed to resolve target")
          return
        end
        git_capture(target.path, { "rev-list", "-1", ref }, function(sha_target, target_err)
          if not sha_target then
            finalize("error", sha_head, nil, target_err or "failed to resolve target ref")
            return
          end
          local status = sha_head ~= sha_target and "update" or "same"
          if status ~= "update" then
            finalize(status, sha_head, sha_target, nil)
            return
          end
          -- Prefetch the breaking-change inference inputs (tags, commit
          -- messages, pending log) asynchronously before the row flips, so
          -- `infer_breaking_status`'s sync calls are pure cache hits when the
          -- dashboard collects this row. A prefetch-side problem must never
          -- turn this "update" row into an error row: on a synchronous
          -- failure from `prefetch_range` itself, finalize as update anyway
          -- (the sync calls will just repeat the git work later).
          local prefetch_ok = pcall(gitcmd.prefetch_range, target.path, sha_head, sha_target, function()
            finalize(status, sha_head, sha_target, nil)
          end)
          if not prefetch_ok then
            finalize(status, sha_head, sha_target, nil)
          end
        end)
      end)
    end)
  end

  if not online then
    compute_status()
    return
  end

  vim.system({
    "git",
    "-c",
    "gc.auto=0",
    "fetch",
    "--quiet",
    "--tags",
    "--force",
    "--recurse-submodules=yes",
    "origin",
  }, { cwd = target.path, text = true, env = env, clear_env = true }, function(out)
    if out.code ~= 0 then
      finalize("error", nil, nil, vim.trim(out.stderr or out.stdout or "git fetch failed"))
      return
    end
    compute_status()
  end)
end

-- Run the per-plugin refresh pipeline concurrently.
--   names     - optional name filter (nil = all managed plugins)
--   online    - whether to `git fetch` before computing status
--   on_each   - called once per plugin as it resolves, with the result table
--   on_done   - called once after every plugin has resolved, with the count
-- Concurrency honors `state.dashboard_config.fetch_concurrency` (default 8).
function M.run(names, online, on_each, on_done)
  local ok, plugins = pcall(vim.pack.get, names, { info = false })
  if not ok or type(plugins) ~= "table" then
    notify.notify_err("Failed to read vim.pack plugins")
    vim.schedule(function()
      on_done(0)
    end)
    return
  end

  local state = require("dash_paq.dashboard.state")
  local targets = {}
  for _, plugin in ipairs(plugins) do
    local name = plugin and plugin.spec and plugin.spec.name
    local path = plugin and plugin.path
    if type(name) == "string" and name ~= "" and type(path) == "string" and path ~= "" then
      local declared = state.declared_versions_cache[name]
      -- nil/false resolved = branch; avoid and/or here.
      local version
      if declared ~= nil then
        version = declared.resolved
      else
        version = plugin.spec.version
      end
      targets[#targets + 1] = {
        name = name,
        path = path,
        source = plugin.spec.src,
        version = version,
      }
    end
  end

  local total = #targets
  if total == 0 then
    vim.schedule(function()
      on_done(0)
    end)
    return
  end

  local env = clean_env()

  local max_jobs = math.max(1, math.min(total, tonumber(state.dashboard_config.fetch_concurrency) or 8))
  local next_index = 1
  local running = 0
  local done_count = 0
  local finished = false

  local function finish_if_done()
    if finished or done_count < total then
      return
    end
    finished = true
    vim.schedule(function()
      on_done(total)
    end)
  end

  local launch_next
  launch_next = function()
    while running < max_jobs and next_index <= total do
      local target = targets[next_index]
      next_index = next_index + 1
      running = running + 1
      refresh_one(target, online, env, function(result)
        running = running - 1
        done_count = done_count + 1
        -- Captured now: the scheduled callback runs later, after more results
        -- may have completed, and must report this result's own position.
        local position = done_count
        vim.schedule(function()
          on_each(result, position, total)
        end)
        vim.schedule(launch_next)
        finish_if_done()
      end)
    end
    finish_if_done()
  end

  launch_next()
end

return M
