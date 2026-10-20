-- Version policy and tag/branch heuristic engine for the dash-paq
-- loader, kept separate from UI code so it can be unit-tested standalone.
local M = {}

local semver = require("dash_paq.semver")
local git = require("dash_paq.git")
local fs = require("dash_paq.fs")
local parse_release_tag = semver.parse_release_tag

-- `version_policy.json` layout version; a cache with any other value is rebuilt.
M.SCHEMA = 4

M.DEFAULTS = {
  min_tags = 3,
  commit_lag_multiplier = 1.5,
  max_commits_since_tag = 150,
  sparse_tag_threshold = 30,
  max_tag_age_days = 180,
  ttl_days = 3,
  avg_window = 6,
  startup_delay_ms = 200,
}

local cfg = vim.deepcopy(M.DEFAULTS)

function M.configure(opts)
  cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.DEFAULTS), opts or {})
end

function M.version_policy_path()
  return fs.state_path("version_policy.json")
end

local function read_tag_dates(path)
  if type(path) ~= "string" or path == "" then
    return {}
  end
  local format = "--format=%(refname:short)\t%(creatordate:unix)"
  local result = git
    .run({ "-C", path, "for-each-ref", "--sort=-creatordate", format, "refs/tags" }, { text = true })
    :wait()
  if result.code ~= 0 or type(result.stdout) ~= "string" or result.stdout == "" then
    return {}
  end

  local out = {}
  for _, line in ipairs(vim.split(result.stdout, "\n", { trimempty = true })) do
    local tag, ts = line:match("^(.-)\t(%d+)$")
    if tag and ts and parse_release_tag(tag) ~= nil then
      out[#out + 1] = { tag = tag, ts = tonumber(ts) or 0 }
    end
  end
  return out
end

local function tags_reachable_from(path, ref)
  if type(path) ~= "string" or path == "" or type(ref) ~= "string" or ref == "" then
    return nil
  end
  local result = git.run({ "-C", path, "tag", "--merged", ref }, { text = true }):wait()
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    return nil
  end
  local set = {}
  for _, line in ipairs(vim.split(result.stdout, "\n", { trimempty = true })) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      set[trimmed] = true
    end
  end
  return set
end

local function latest_semver_tag(tags_with_dates, reachable_set)
  local best = nil
  local best_v = nil
  local best_reachable = nil
  local best_reachable_v = nil
  for _, item in ipairs(tags_with_dates or {}) do
    local tag = item.tag
    local v = parse_release_tag(tag)
    if v ~= nil then
      if not best_v or vim.version.gt(v, best_v) then
        best = item
        best_v = v
      end
      if reachable_set and reachable_set[tag] then
        if not best_reachable_v or vim.version.gt(v, best_reachable_v) then
          best_reachable = item
          best_reachable_v = v
        end
      end
    end
  end
  if reachable_set and best_reachable then
    return best_reachable
  end
  return best
end

local function commit_count_between(path, from_ref, to_ref)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local result = git.run({ "-C", path, "rev-list", "--count", from_ref .. ".." .. to_ref }, { text = true }):wait()
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    return nil
  end
  return tonumber(vim.trim(result.stdout))
end

local function origin_head_ref(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local result = git
    .run({ "-C", path, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" }, { text = true })
    :wait()
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    return nil
  end
  local ref = vim.trim(result.stdout)
  return ref ~= "" and ref or nil
end

local function avg_commits_per_release(path, tags_with_dates, limit)
  limit = tonumber(limit) or cfg.avg_window
  if limit < 3 then
    limit = 3
  end
  if type(tags_with_dates) ~= "table" or #tags_with_dates < 2 then
    return nil
  end

  local tags = {}
  for _, item in ipairs(tags_with_dates) do
    if type(item) == "table" and type(item.tag) == "string" and item.tag ~= "" then
      tags[#tags + 1] = item.tag
    end
    if #tags >= limit then
      break
    end
  end
  if #tags < 2 then
    return nil
  end

  local weighted_sum = 0
  local weight_total = 0
  for i = 1, (#tags - 1) do
    local n = commit_count_between(path, tags[i + 1], tags[i])
    if n and n > 0 then
      local weight = 1 / i
      weighted_sum = weighted_sum + n * weight
      weight_total = weight_total + weight
    end
  end
  if weight_total == 0 then
    return nil
  end
  return math.floor(weighted_sum / weight_total)
end

local function current_head_tag(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local result = git.run({ "-C", path, "describe", "--tags", "--exact-match", "HEAD" }, { text = true }):wait()
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    return nil
  end
  local tag = vim.trim(result.stdout)
  if tag ~= "" and parse_release_tag(tag) ~= nil then
    return tag
  end
  return nil
end

local function decide_tag_strategy(path)
  local tag_dates = read_tag_dates(path)
  if #tag_dates == 0 then
    return { strategy = "branch", semver_tags = false, reason = "no semver tags" }
  end

  local head_ref = origin_head_ref(path) or "origin/HEAD"
  local reachable = tags_reachable_from(path, head_ref)
  local latest = latest_semver_tag(tag_dates, reachable)
  if not latest then
    return { strategy = "branch", semver_tags = false, reason = "no semver tags" }
  end

  local commits_since = commit_count_between(path, latest.tag, head_ref)
  local cur_tag = current_head_tag(path)
  if not commits_since then
    return {
      strategy = "tags",
      semver_tags = true,
      latest_tag = latest.tag,
      latest_tag_ts = latest.ts,
      current_tag = cur_tag,
      tag_count = #tag_dates,
      reason = "cannot count commits since tag",
    }
  end

  local base = {
    semver_tags = true,
    latest_tag = latest.tag,
    latest_tag_ts = latest.ts,
    current_tag = cur_tag,
    tag_count = #tag_dates,
    commits_since_tag = commits_since,
  }

  if commits_since == 0 then
    base.strategy = "tags"
    base.reason = "branch tip is at latest tag"
    return base
  end

  local min_tags = cfg.min_tags
  local multiplier = cfg.commit_lag_multiplier
  local abs_cap = cfg.max_commits_since_tag
  local sparse_threshold = cfg.sparse_tag_threshold
  local max_tag_age_days = cfg.max_tag_age_days

  -- Gate 1: not enough release history to trust an average.
  if #tag_dates < min_tags then
    if commits_since > sparse_threshold then
      base.strategy = "branch"
      base.reason = "insufficient release history ("
        .. #tag_dates
        .. " tags), "
        .. commits_since
        .. " unreleased commits"
    else
      base.strategy = "tags"
      base.reason = "insufficient release history, few unreleased commits"
    end
    return base
  end

  -- Gate 2: compare against average release size.
  local avg = avg_commits_per_release(path, tag_dates, cfg.avg_window)
  base.avg_commits_per_release = avg
  if avg and avg > 0 and commits_since > (avg * multiplier) then
    base.strategy = "branch"
    base.reason = "commits since tag (" .. commits_since .. ") exceed avg release size (" .. avg .. ")"
    return base
  end

  -- Gate 3: time since latest tag — stale releases indicate abandoned tagging.
  if latest.ts and latest.ts > 0 then
    local age_days = (os.time() - latest.ts) / 86400
    base.tag_age_days = math.floor(age_days)
    if age_days > max_tag_age_days and commits_since > 0 then
      base.strategy = "branch"
      base.reason = "latest tag is " .. math.floor(age_days) .. "d old with " .. commits_since .. " unreleased commits"
      return base
    end
  end

  -- Gate 4: absolute cap as safety net.
  if commits_since > abs_cap then
    base.strategy = "branch"
    base.reason = "too many unreleased commits (" .. commits_since .. ")"
    return base
  end

  base.strategy = "tags"
  base.reason = "within expected release cadence"
  return base
end

function M.load_version_policy()
  local decoded = fs.read_json(M.version_policy_path())
  if not decoded then
    return nil
  end
  if type(decoded.plugins) ~= "table" then
    decoded.plugins = {}
  end
  decoded.schema = tonumber(decoded.schema) or 0
  decoded.generated_at = tonumber(decoded.generated_at)
  return decoded
end

function M.write_version_policy(plugins)
  if type(plugins) ~= "table" then
    return false
  end
  return fs.write_json(M.version_policy_path(), { schema = M.SCHEMA, generated_at = os.time(), plugins = plugins })
end

-- Returns "fresh" (cache still valid), "full" (expired or schema mismatch,
-- recompute everything), or "incremental" (valid but missing some plugins).
local function policy_refresh_mode(existing, installed)
  if type(existing) ~= "table" or existing.schema ~= M.SCHEMA or type(existing.plugins) ~= "table" then
    return "full"
  end

  local generated_at = tonumber(existing.generated_at) or 0
  local max_age = cfg.ttl_days * 60 * 60 * 24
  if generated_at > 0 and (os.time() - generated_at) > max_age then
    return "full"
  end

  for _, item in ipairs(installed) do
    local cached = existing.plugins[item.name]
    if type(cached) ~= "table" or not git.same_remote(cached.src, item.src) then
      return "incremental"
    end
  end

  return "fresh"
end

-- True while `refresh_version_policy_async` is running. Stops the startup
-- refresh and a dashboard-triggered refresh from running concurrently.
local policy_refresh_in_progress = false
local refresh_generation = 0

local function supersede_refresh()
  refresh_generation = refresh_generation + 1
  policy_refresh_in_progress = false
end

-- Gap between processing one plugin and the next in `refresh_version_policy_async`'s
-- step chain. Chaining with bare `vim.schedule` would starve input: Neovim
-- drains newly queued scheduled callbacks within the same event-queue pass,
-- so `vim.defer_fn` with ms >= 1 is used instead to actually yield.
local ASYNC_STEP_YIELD_MS = 1

-- What a refresh must do for the installed plugin set. Returns nil when
-- `vim.pack.get` fails, else `{ mode, plugins, pending }`: `mode` is "fresh"
-- (cache still valid), "full" (expired or schema mismatch), or "incremental"
-- (valid but missing some plugins); `plugins` is the cached entries to keep
-- (removed plugins dropped); `pending` is the `{ name, path }` list to
-- recompute.
local function plan_refresh()
  local ok, plug_data = pcall(vim.pack.get, nil, { info = false })
  if not ok or type(plug_data) ~= "table" then
    return nil
  end

  local installed = {}
  for _, p in ipairs(plug_data) do
    local name = p and p.spec and p.spec.name
    if type(name) == "string" and name ~= "" then
      installed[#installed + 1] = { name = name, path = p.path, src = p.spec.src }
    end
  end
  local existing = M.load_version_policy()
  local mode = policy_refresh_mode(existing, installed)
  local existing_plugins = existing and existing.plugins or {}
  if mode == "fresh" then
    return { mode = mode, plugins = existing_plugins, pending = {} }
  end

  local plugins = {}
  if mode == "incremental" then
    for _, item in ipairs(installed) do
      local info = existing_plugins[item.name]
      if type(info) == "table" and git.same_remote(info.src, item.src) then
        plugins[item.name] = info
      end
    end
  end

  local pending = {}
  for _, item in ipairs(installed) do
    if type(item.path) == "string" and item.path ~= "" and plugins[item.name] == nil then
      pending[#pending + 1] = item
    end
  end
  return { mode = mode, plugins = plugins, pending = pending }
end

-- Synchronous refresh for user-initiated paths (`:DashPaq sync`, `status`, `policy-rebuild`)
-- where the user is already waiting.
function M.refresh_version_policy_if_needed()
  supersede_refresh()
  local plan = plan_refresh()
  if not plan then
    return false
  end
  if plan.mode == "fresh" then
    return true
  end
  for _, item in ipairs(plan.pending) do
    plan.plugins[item.name] = decide_tag_strategy(item.path)
    plan.plugins[item.name].src = item.src
  end
  return M.write_version_policy(plan.plugins)
end

-- Async variant used by the startup bootstrap and after a dashboard apply.
-- Processes one plugin per `vim.defer_fn` step so the UI can redraw between git
-- shell-outs, since the synchronous path can block for several seconds on a
-- cold run.
function M.refresh_version_policy_async(callback)
  local function reply(ok, reason)
    if callback then
      vim.schedule(function()
        callback(ok, reason)
      end)
    end
  end

  if policy_refresh_in_progress then
    reply(false, "busy")
    return false
  end

  local plan = plan_refresh()
  if not plan then
    reply(false, "no-plugins")
    return false
  end
  if plan.mode == "fresh" then
    reply(true, "fresh")
    return true
  end

  local plugins, pending = plan.plugins, plan.pending
  if #pending == 0 then
    local wrote = M.write_version_policy(plugins)
    reply(wrote, "no-work")
    return wrote
  end

  policy_refresh_in_progress = true
  local generation = refresh_generation
  local index = 0

  local function step()
    if generation ~= refresh_generation then
      reply(false, "superseded")
      return
    end
    index = index + 1
    if index > #pending then
      policy_refresh_in_progress = false
      local wrote = M.write_version_policy(plugins)
      if callback then
        callback(wrote, plan.mode)
      end
      return
    end

    local item = pending[index]
    local ok_item, decision = pcall(decide_tag_strategy, item.path)
    if ok_item and type(decision) == "table" then
      decision.src = item.src
      plugins[item.name] = decision
    end
    vim.defer_fn(step, ASYNC_STEP_YIELD_MS)
  end

  vim.defer_fn(step, ASYNC_STEP_YIELD_MS)
  return true
end

-- Drop a single plugin entry (or everything when `name == nil`) from the
-- on-disk version policy so the next refresh recomputes it from scratch.
function M.invalidate_version_policy(name)
  supersede_refresh()
  local existing = M.load_version_policy()
  if type(existing) ~= "table" or type(existing.plugins) ~= "table" then
    return true
  end
  if type(name) == "string" and name ~= "" then
    if existing.plugins[name] == nil then
      return true
    end
    existing.plugins[name] = nil
    return M.write_version_policy(existing.plugins)
  end
  local path = M.version_policy_path()
  if vim.fn.filereadable(path) == 1 then
    pcall(vim.fn.delete, path)
  end
  return true
end

-- Recompute the policy entry for a single plugin (or every plugin) and write
-- the result to disk. Runs synchronously; the caller decides whether to
-- block the UI (fine for a user-initiated command, use async on startup).
function M.rebuild_version_policy(name)
  M.invalidate_version_policy(name)
  return M.refresh_version_policy_if_needed()
end

return M
