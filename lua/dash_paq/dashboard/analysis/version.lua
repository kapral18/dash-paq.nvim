local state = require("dash_paq.dashboard.state")
local gitcmd = require("dash_paq.dashboard.analysis.gitcmd")
local git = require("dash_paq.git")

local M = {}

local function is_version_range(v)
  return type(v) == "table" and type(v.has) == "function"
end

-- A release-shaped tag: optional leading `v`, then numeric `X.Y.Z`. Requires
-- the full triplet so this matches vim.pack's own strict tag resolution; a
-- two-part tag like `nvim-0.6` never wins a strict comparison.
local function is_release_tag(t)
  if type(t) ~= "string" then
    return false
  end
  local body = t:gsub("^v", "")
  return body:match("^%d+%.%d+%.%d+$") ~= nil
end

local function greatest_tag(tags, filter)
  local best
  for _, t in ipairs(tags or {}) do
    if (not filter) or filter(t) then
      -- strict, like vim.pack
      local ok, v = pcall(vim.version.parse, t, { strict = true })
      if ok and v and (not best or vim.version.gt(v, best.v)) then
        best = { t = t, v = v }
      end
    end
  end
  return best and best.t or nil
end

-- True when the on-disk checkout no longer satisfies the declared version.
-- `plugin` contains the checkout rev, origin branches, and either tags at HEAD
-- for a version range or Git's resolved target_rev for a literal ref.
local function compute_version_drift(declared, plugin)
  if declared == nil then
    -- Branch-tracking / `version = false`: no constraint provable offline.
    return false
  end
  local rev = plugin.rev or ""
  local tags = plugin.tags or {}

  if is_version_range(declared) then
    for _, t in ipairs(tags) do
      -- strict, like vim.pack
      local ok, v = pcall(vim.version.parse, t, { strict = true })
      if ok and v and declared:has(v) then
        return false
      end
    end
    return true
  end

  if vim.tbl_contains(plugin.branches or {}, declared) then
    return false
  end
  return plugin.target_rev ~= rev
end

-- True when `version = "*"` would select a non-release tag that outranks the
-- greatest stable release (for example v2.0.0-rc1 over v1.9.0).
local function detect_risky_star_pin(is_star, tags)
  if not is_star or type(tags) ~= "table" or #tags == 0 then
    return false
  end
  local star_pick = greatest_tag(tags, nil)
  local intended = greatest_tag(tags, is_release_tag)
  if not intended then
    return false
  end
  return star_pick ~= intended
end

-- One plugin per tick, and every Git query in it is async, so the scan never
-- blocks input. `ms >= 1`: a 0ms `vim.defer_fn` chain, like a bare
-- `vim.schedule` chain, is not guaranteed to yield to input between steps.
local STEP_YIELD_MS = 1
local subscribers = {}

local function complete_scan()
  state.version_flags_scan_running = false
  local callbacks = subscribers
  subscribers = {}
  for _, callback in ipairs(callbacks) do
    local ok, err = pcall(callback)
    if not ok then
      require("dash_paq.notify").err("Version flag callback failed: " .. tostring(err))
    end
  end
end

-- Calls `done(checkout)`, or `done(nil)` when HEAD is unreadable.
local function read_checkout(plugin, declared, done)
  git.run_async({ "-C", plugin.path, "rev-parse", "HEAD" }, function(head)
    if head.code ~= 0 then
      done(nil)
      return
    end
    git.run_async({ "-C", plugin.path, "for-each-ref", "--format=%(refname)", "refs/remotes/origin" }, function(refs)
      local branches = {}
      for ref in vim.gsplit(refs.stdout or "", "\n", { trimempty = true }) do
        branches[#branches + 1] = ref:gsub("^refs/remotes/origin/", "")
      end
      local rev = vim.trim(head.stdout)
      local checkout = { rev = rev, branches = branches }
      if type(declared) ~= "string" then
        gitcmd.tags_on_revision(plugin.path, rev, function(tags)
          checkout.tags = tags
          done(checkout)
        end)
      elseif vim.tbl_contains(branches, declared) then
        done(checkout)
      else
        git.run_async({ "-C", plugin.path, "rev-list", "-1", declared }, function(target)
          checkout.target_rev = target.code == 0 and vim.trim(target.stdout) or nil
          done(checkout)
        end)
      end
    end)
  end)
end

local function refresh_version_flags_async(done)
  if type(done) == "function" then
    subscribers[#subscribers + 1] = done
  end
  if state.version_flags_scan_running then
    return
  end
  if state.version_flags_scanned or next(state.declared_versions_cache) == nil then
    complete_scan()
    return
  end

  local ok, plugins = pcall(vim.pack.get, nil, { info = false })
  if not ok or type(plugins) ~= "table" then
    complete_scan()
    return
  end

  state.version_flags_scan_running = true
  local generation = state.version_flags_generation
  local index = 1
  local function restart_if_invalidated()
    if generation == state.version_flags_generation then
      return false
    end
    state.version_flags_scan_running = false
    refresh_version_flags_async()
    return true
  end

  local step
  local function advance()
    if index <= #plugins then
      vim.defer_fn(step, STEP_YIELD_MS)
      return
    end
    state.version_flags_scanned = true
    complete_scan()
  end

  -- Rows use the cached result on the next render, so slow git tag calls
  -- never delay opening the dashboard.
  step = function()
    if restart_if_invalidated() then
      return
    end
    local plugin = plugins[index]
    if not plugin then
      advance()
      return
    end
    index = index + 1

    local name = plugin.spec and plugin.spec.name
    local intent = type(name) == "string" and state.declared_versions_cache[name] or nil
    local is_orphan = state.declared_names_published and not state.declared_names_cache[name] and not plugin.active
    if type(intent) ~= "table" or is_orphan then
      advance()
      return
    end

    local function record(checkout, star_tags)
      -- Git callbacks yield to input, including native updates that invalidate us.
      if restart_if_invalidated() then
        return
      end
      -- A throw here would leave the scan running forever, and refresh
      -- finalize waits on the scan to release the row-op lock.
      local ok_flags, flags = pcall(function()
        return {
          drift = (checkout and compute_version_drift(intent.resolved, checkout)) or nil,
          risky = detect_risky_star_pin(intent.star, star_tags) or nil,
        }
      end)
      if not ok_flags then
        require("dash_paq.notify").err("Version flag check failed for " .. name .. ": " .. tostring(flags))
      end
      state.version_flags_cache[name] = ok_flags and flags or {}
      advance()
    end
    local function with_star_tags(checkout)
      if intent.star then
        gitcmd.all_tags(plugin.path, function(tags)
          record(checkout, tags)
        end)
      else
        record(checkout, nil)
      end
    end
    if intent.resolved ~= nil then
      read_checkout(plugin, intent.resolved, with_star_tags)
    else
      with_star_tags(nil)
    end
  end

  vim.defer_fn(step, STEP_YIELD_MS)
end

local function short_rev(rev)
  if type(rev) ~= "string" or rev == "" then
    return nil
  end
  return rev:sub(1, 8)
end

M.is_version_range = is_version_range
M.is_release_tag = is_release_tag
M.compute_version_drift = compute_version_drift
M.detect_risky_star_pin = detect_risky_star_pin
M.refresh_version_flags_async = refresh_version_flags_async
M.short_rev = short_rev

return M
