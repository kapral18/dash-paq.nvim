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

-- One plugin per tick: each plugin can still run sync `git tag` calls
-- (gitcmd.tags_on_revision/all_tags), so a bigger per-tick batch would delay
-- input for too long on large plugin sets. `ms >= 1`: a 0ms `vim.defer_fn`
-- chain, like a bare `vim.schedule` chain, is not guaranteed to yield to
-- input between steps.
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

local function read_checkout(plugin, declared)
  local head = git.run({ "-C", plugin.path, "rev-parse", "HEAD" }, { text = true }):wait()
  if head.code ~= 0 then
    return nil
  end
  local refs = git
    .run({ "-C", plugin.path, "for-each-ref", "--format=%(refname)", "refs/remotes/origin" }, { text = true })
    :wait()
  local branches = {}
  for ref in vim.gsplit(refs.stdout or "", "\n", { trimempty = true }) do
    branches[#branches + 1] = ref:gsub("^refs/remotes/origin/", "")
  end
  local rev = vim.trim(head.stdout)
  local checkout = { rev = rev, branches = branches }
  if type(declared) == "string" then
    if not vim.tbl_contains(branches, declared) then
      local target = git.run({ "-C", plugin.path, "rev-list", "-1", declared }, { text = true }):wait()
      checkout.target_rev = target.code == 0 and vim.trim(target.stdout) or nil
    end
  else
    checkout.tags = gitcmd.tags_on_revision(plugin.path, rev)
  end
  return checkout
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
  -- Rows use the cached result on the next render, so slow git tag calls
  -- never delay opening the dashboard.
  local function step()
    if restart_if_invalidated() then
      return
    end
    local plugin = plugins[index]
    if plugin then
      index = index + 1

      local name = plugin.spec and plugin.spec.name
      local intent = type(name) == "string" and state.declared_versions_cache[name] or nil
      local is_orphan = state.declared_names_published and not state.declared_names_cache[name] and not plugin.active
      if type(intent) == "table" and not is_orphan then
        local ok_checkout, checkout
        if intent.resolved ~= nil then
          ok_checkout, checkout = pcall(read_checkout, plugin, intent.resolved)
        end
        local flags = {
          drift = (ok_checkout and checkout and compute_version_drift(intent.resolved, checkout)) or nil,
          risky = detect_risky_star_pin(intent.star, intent.star and gitcmd.all_tags(plugin.path) or nil) or nil,
        }
        -- Git waits pump events, including native updates that invalidate us.
        if restart_if_invalidated() then
          return
        end
        state.version_flags_cache[name] = flags
      end
    end

    if index <= #plugins then
      vim.defer_fn(step, STEP_YIELD_MS)
      return
    end

    state.version_flags_scanned = true
    complete_scan()
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
