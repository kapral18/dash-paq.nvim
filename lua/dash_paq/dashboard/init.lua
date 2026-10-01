local state = require("dash_paq.dashboard.state")
local report = require("dash_paq.dashboard.report")
local ui = require("dash_paq.dashboard.ui")
local lockfile = require("dash_paq.dashboard.lockfile")
local analysis = require("dash_paq.dashboard.analysis")
local policy = require("dash_paq.policy")
local commands = require("dash_paq.commands")

local M = {}

local configured = false
local load_version_policy = policy.load_version_policy
local rebuild_version_policy = policy.rebuild_version_policy
local refresh_version_policy_if_needed = policy.refresh_version_policy_if_needed
-- opts.version_policy ~= false
local version_policy_enabled = false

function M.set_declared_plugin_names(names)
  state.set_declared_plugin_names(names)
end

function M.set_declared_plugin_versions(versions)
  state.set_declared_plugin_versions(versions)
end

function M.set_dev_plugin_paths(paths)
  state.set_dev_plugin_paths(paths)
end

function M.set_dev_capable_plugins(map)
  state.set_dev_capable_plugins(map)
end

local function installed_plugin_complete(arglead, done)
  if #done > 0 then
    return {}
  end
  local ok, plug_data = pcall(vim.pack.get, nil, { info = false })
  if not ok or type(plug_data) ~= "table" then
    return {}
  end
  local names = {}
  for _, p in ipairs(plug_data) do
    local n = p and p.spec and p.spec.name
    if type(n) == "string" then
      names[#names + 1] = n
    end
  end
  return commands.filter(names, arglead)
end

local function sync()
  vim.pack.update()
  local counts = report.refresh_pack_report_cache_from_report_buffer()
  if counts then
    state.pack_report_cache.last_check_counts = counts
  end
  state.pack_report_cache.mode = "online"
  state.pack_report_cache.last_online_at = os.time()
  state.write_persisted_state()
  if version_policy_enabled then
    pcall(refresh_version_policy_if_needed)
  end
end

local function status()
  vim.pack.update(nil, { offline = true })
  local counts = report.refresh_pack_report_cache_from_report_buffer()
  if counts then
    state.pack_report_cache.last_check_counts = counts
  end
  state.pack_report_cache.mode = "offline"
  state.pack_report_cache.last_offline_at = os.time()
  state.write_persisted_state()
  if version_policy_enabled then
    pcall(refresh_version_policy_if_needed)
  end
end

local function stats()
  local raw = state.pack_report_cache.last_check_counts
  local raw_text = "update:n/a same:n/a error:n/a"
  if type(raw) == "table" then
    raw_text = string.format(
      "update:%d same:%d error:%d",
      tonumber(raw.update) or 0,
      tonumber(raw.same) or 0,
      tonumber(raw.error) or 0
    )
  end
  local checked = state.format_cache_stamp(state.pack_report_cache.updated_at)
  local online = state.format_cache_stamp(state.pack_report_cache.last_online_at)
  local offline = state.format_cache_stamp(state.pack_report_cache.last_offline_at)
  local applied = state.format_cache_stamp(state.pack_report_cache.last_applied_at)
  local applied_count = tonumber(state.pack_report_cache.last_applied_count) or 0
  vim.notify(
    string.format(
      "DashPaq last-check [%s] mode:%s result:%s online:%s offline:%s applied:%s (%d)",
      raw_text,
      state.pack_report_cache.mode or "unknown",
      checked,
      online,
      offline,
      applied,
      applied_count
    ),
    vim.log.levels.INFO
  )
end

local function lock_info()
  local path = lockfile.path()
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("vim.pack lockfile not found at " .. path, vim.log.levels.WARN)
    return
  end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  local plugins = 0
  if ok_read and type(lines) == "table" then
    local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    if ok_decode and type(decoded) == "table" and type(decoded.plugins) == "table" then
      for _ in pairs(decoded.plugins) do
        plugins = plugins + 1
      end
    end
  end
  local stat = vim.uv.fs_stat(path)
  local mtime = stat and os.date("%Y-%m-%d %H:%M:%S", stat.mtime.sec) or "unknown"
  vim.notify(
    string.format("vim.pack lockfile: %s\n  plugins: %d\n  mtime:   %s", path, plugins, mtime),
    vim.log.levels.INFO
  )
end

local function lock_export(dest)
  if dest == "" then
    vim.notify("Usage: :DashPaq lock export <path>", vim.log.levels.WARN)
    return
  end
  local ok, result = lockfile.export(dest)
  if ok then
    vim.notify("Exported lockfile → " .. result, vim.log.levels.INFO)
  else
    vim.notify("DashPaq lock export failed: " .. tostring(result), vim.log.levels.ERROR)
  end
end

local function lock_import(source)
  if source == "" then
    vim.notify("Usage: :DashPaq lock import <path>", vim.log.levels.WARN)
    return
  end
  local ok, result = lockfile.import(source)
  if ok then
    vim.notify(
      "Imported lockfile from " .. source .. " → " .. result .. ". Restart or run :DashPaq sync to apply.",
      vim.log.levels.INFO
    )
  else
    vim.notify("DashPaq lock import failed: " .. tostring(result), vim.log.levels.ERROR)
  end
end

local LOCK_ACTIONS = { "info", "export", "import" }

local function lock(args, opts)
  local action = args[1]
  -- The path is the raw remainder after the action, so it may contain spaces.
  local path = vim.trim(opts.raw:match("^%S+(.*)$") or "")
  if action == "info" then
    lock_info()
  elseif action == "export" then
    lock_export(path)
  elseif action == "import" then
    lock_import(path)
  else
    vim.notify("Usage: :DashPaq lock info|export <path>|import <path>", vim.log.levels.WARN)
  end
end

local function lock_complete(arglead, done)
  if #done == 0 then
    return commands.filter(LOCK_ACTIONS, arglead)
  end
  if done[1] == "export" or done[1] == "import" then
    return vim.fn.getcompletion(arglead, "file")
  end
  return {}
end

local function policy_rebuild(args)
  if not version_policy_enabled then
    vim.notify("Version policy is disabled (opts.version_policy = false)", vim.log.levels.WARN)
    return
  end
  local target = args[1]
  local ok = rebuild_version_policy(target)
  if ok then
    local version_policy = load_version_policy() or { plugins = {} }
    if target then
      local info = version_policy.plugins and version_policy.plugins[target]
      if info then
        vim.notify(
          string.format(
            "Rebuilt policy for %s: strategy=%s\n  %s",
            target,
            tostring(info.strategy),
            tostring(info.reason or "")
          ),
          vim.log.levels.INFO
        )
      else
        vim.notify("Rebuilt policy, but no entry recorded for " .. target, vim.log.levels.WARN)
      end
    else
      local count = 0
      local tags, branch = 0, 0
      for _, info in pairs(version_policy.plugins or {}) do
        count = count + 1
        if info.strategy == "tags" then
          tags = tags + 1
        elseif info.strategy == "branch" then
          branch = branch + 1
        end
      end
      vim.notify(
        string.format("Rebuilt version policy: %d plugins (%d tags, %d branch)", count, tags, branch),
        vim.log.levels.INFO
      )
    end
  else
    vim.notify("DashPaq policy-rebuild failed", vim.log.levels.ERROR)
  end
end

function M.setup(config)
  if configured then
    return
  end
  configured = true
  version_policy_enabled = config.version_policy ~= false
  state.version_policy_enabled = version_policy_enabled
  state.set_dashboard_config(config.dashboard)
  analysis.configure_hosts(config.hosts)
  state.load_persisted_state_once()

  commands.register_default({
    usage = "[!]",
    bang = true,
    impl = function(_, opts)
      ui.open(true, opts.bang)
    end,
  })
  commands.register("sync", { usage = "sync", impl = sync })
  commands.register("status", { usage = "status", impl = status })
  commands.register("stats", { usage = "stats", impl = stats })
  commands.register("lock", { usage = "lock info|export <path>|import <path>", impl = lock, complete = lock_complete })
  commands.register("policy-rebuild", {
    usage = "policy-rebuild [plugin]",
    impl = policy_rebuild,
    complete = installed_plugin_complete,
  })
end

return M
