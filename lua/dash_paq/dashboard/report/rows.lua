local state = require("dash_paq.dashboard.state")
local analysis = require("dash_paq.dashboard.analysis")
local notify = require("dash_paq.notify")
local git = require("dash_paq.git")

local M = {}

-- Drop cache entries that no longer correspond to a managed plugin, and
-- persist the cache when anything was dropped.
function M.ensure_dashboard_cache()
  local ok, current = pcall(vim.pack.get, nil, { info = false })
  if not ok or type(current) ~= "table" then
    return
  end

  local valid_names = {}
  for _, plugin in ipairs(current) do
    local name = plugin and plugin.spec and plugin.spec.name
    if type(name) == "string" and name ~= "" then
      valid_names[name] = true
    end
  end
  for name in pairs(state.dev_plugin_paths_cache) do
    valid_names[name] = true
  end
  local dirty = false
  for name in pairs(state.pack_report_cache.plugins) do
    if not valid_names[name] then
      state.pack_report_cache.plugins[name] = nil
      dirty = true
    end
  end
  if dirty then
    state.write_persisted_state()
  end
end

-- Assemble one dashboard row for `plugin` (a `vim.pack.get` entry) from the
-- report cache, applying the orphan/drift/risky overrides and lazily inferring
-- breaking status + diff URL for update rows. Shared by the full-table and the
-- single-row builders so per-row refresh produces identical rows.
local function build_dashboard_row(plugin)
  -- Only flag orphans once the loader has advertised its declared set.
  -- Before publication we must not mark everything as
  -- orphaned (e.g. when a user runs `:DashPaq` from a minimal config).
  local orphan_flagging = state.declared_names_published
  local version_flagging = next(state.declared_versions_cache) ~= nil
  local name = plugin.spec.name
  local p_data = state.pack_report_cache.plugins[name]
  if p_data and not git.same_remote(p_data.source, plugin.spec.src) then
    state.pack_report_cache.plugins[name] = nil
    state.write_persisted_state()
    p_data = nil
  end
  p_data = p_data or {}
  local status = p_data.status or "unknown"
  local source = plugin.spec.src
  -- Equal revisions would link an empty compare page; `o` falls back to the repo.
  local diff_url = p_data.diff_url
    or (p_data.rev_before ~= p_data.rev_after and analysis.source_to_compare_url(
      source,
      p_data.rev_before,
      p_data.rev_after
    ))
    or nil
  local breaking = p_data.breaking
  -- An `active = true` plugin is declared by definition even without a
  -- matching spec; treating it as an orphan would let `C` (clean) delete it.
  local is_orphan = orphan_flagging and not state.declared_names_cache[name] and not plugin.active

  -- Spec-vs-disk version drift and risky `version = "*"` pins. Only meaningful
  -- for declared (non-orphan) plugins once versions have been published.
  local is_drift = false
  local is_risky_pin = false
  if version_flagging and not is_orphan then
    local flags = state.version_flags_cache[name]
    is_drift = type(flags) == "table" and flags.drift == true
    is_risky_pin = type(flags) == "table" and flags.risky == true
  end

  if is_orphan then
    -- Orphans supersede any prior update/same/error status coming from the
    -- `vim.pack.update` report: the user should be nudged to clean them
    -- before seeing them as an upgradeable row.
    status = "orphan"
    breaking = nil
  elseif is_drift then
    -- Drift (checkout no longer satisfies the spec) outranks update/same:
    -- the user changed intent and the on-disk ref must be re-resolved.
    status = "drift"
    breaking = nil
  elseif is_risky_pin then
    status = "risky"
    breaking = nil
  end
  if breaking == nil and status == "update" then
    p_data.source = source
    p_data.diff_url = diff_url
    -- `risk_reason` is set on every `infer_breaking_status` path (including
    -- the nil-verdict ones) and only cleared, alongside `breaking`, when a
    -- refresh recomputes this row's status (ui/refresh.lua
    -- apply_pipeline_result). So `risk_reason ~= nil` means this rev pair was
    -- already inferred; skip re-running it (and its sync git calls) on every
    -- subsequent collect, e.g. after a fresh-session reload where `breaking =
    -- nil` itself isn't persisted.
    if p_data.risk_reason == nil then
      p_data.breaking = analysis.infer_breaking_status(p_data)
      breaking = p_data.breaking
    end
  end

  local row = {
    name = name,
    status = status,
    source = source,
    rev = plugin.rev,
    target_version = p_data.target_version,
    current_version = p_data.current_version,
    rev_before = p_data.rev_before,
    rev_after = p_data.rev_after,
    pending_updates = p_data.pending_updates,
    breaking = breaking,
    semver_delta = p_data.semver_delta,
    commit_signal = p_data.commit_signal,
    risk_reason = p_data.risk_reason,
    diff_url = diff_url,
    repo_url = analysis.source_to_repo_url(source),
    is_orphan = is_orphan or nil,
    is_drift = is_drift or nil,
    is_risky_pin = is_risky_pin or nil,
  }

  if not row.diff_url and row.status == "update" and row.repo_url then
    local from_ref = row.current_version or row.rev_before
    local to_ref = row.target_version or row.rev_after
    row.diff_url = analysis.repo_to_compare_url(row.repo_url, from_ref, to_ref)
  end

  return row
end

-- A synthetic row for a `dev = true` / dev-pattern plugin: never in
-- `vim.pack.get`, so it gets its own `local` status instead of a cache entry.
local function build_dev_row(name, path)
  return {
    name = name,
    status = "local",
    source = path,
    is_dev = true,
  }
end

local function collect_dev_rows()
  local rows = {}
  for name, path in pairs(state.dev_plugin_paths_cache) do
    rows[#rows + 1] = build_dev_row(name, path)
  end
  return rows
end

local function collect_dashboard_rows()
  -- Keep the hot path fast: `info = true` shells out to git for every plugin,
  -- which can take hundreds of milliseconds on a large plugin set. Drift/risky
  -- checks gather tags only for the small subset of rows whose declared
  -- version can use them, asynchronously.
  local ok, plugins = pcall(vim.pack.get, nil, { info = false })
  if not ok then
    notify.err("Failed to read vim.pack plugins")
    return {}
  end

  local rows = {}
  for _, plugin in ipairs(plugins) do
    -- A `dev` name always wins over any on-disk clone of the same name: the
    -- dev directory is what loads; `collect_dev_rows` covers it.
    if not state.dev_plugin_paths_cache[plugin.spec.name] then
      rows[#rows + 1] = build_dashboard_row(plugin)
    end
  end
  vim.list_extend(rows, collect_dev_rows())

  return rows
end

-- Build a single dashboard row for `name` from the current cache. Returns nil
-- when the plugin is not (or no longer) managed. Used by the per-plugin refresh
-- pipeline to refresh exactly one row in place.
local function collect_dashboard_row(name)
  if state.dev_plugin_paths_cache[name] then
    return build_dev_row(name, state.dev_plugin_paths_cache[name])
  end
  local ok, plugins = pcall(vim.pack.get, { name }, { info = false })
  if not ok or type(plugins) ~= "table" or not plugins[1] then
    return nil
  end
  return build_dashboard_row(plugins[1])
end

M.collect_dashboard_rows = collect_dashboard_rows
M.collect_dashboard_row = collect_dashboard_row

return M
