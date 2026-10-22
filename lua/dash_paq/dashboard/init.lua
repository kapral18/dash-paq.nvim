local state = require("dash_paq.dashboard.state")
local report = require("dash_paq.dashboard.report")
local ui = require("dash_paq.dashboard.ui")
local analysis = require("dash_paq.dashboard.analysis")
local policy = require("dash_paq.policy")
local commands = require("dash_paq.commands")
local gitcmd = require("dash_paq.dashboard.analysis.gitcmd")

local M = {}

local configured = false
local load_version_policy = policy.load_version_policy
local rebuild_version_policy = policy.rebuild_version_policy
local refresh_version_policy_if_needed = policy.refresh_version_policy_if_needed

local function invalidate_version_evidence()
  gitcmd.invalidate_tags()
  state.invalidate_version_flags()
end

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

local function check_updates(offline)
  local stale = report.pack_report_buffers()
  vim.pack.update(nil, { offline = offline })
  invalidate_version_evidence()
  report.refresh_pack_report_cache_from_report_buffer(stale, offline and "offline" or "online")
  if state.version_policy_enabled then
    pcall(refresh_version_policy_if_needed)
  end
end

local function policy_rebuild(args)
  if not state.version_policy_enabled then
    vim.notify("Version policy is disabled (opts.version_policy = false)", vim.log.levels.WARN)
    return
  end
  local target = args[1]
  local ok = rebuild_version_policy(target)
  if ok then
    local version_policy = load_version_policy() or { plugins = {} }
    if target then
      local info = version_policy.plugins[target]
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
      for _, info in pairs(version_policy.plugins) do
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
  state.version_policy_enabled = config.version_policy ~= false
  state.set_dashboard_config(config.dashboard)
  analysis.configure_hosts(config.hosts)
  state.load_persisted_state_once()
  vim.api.nvim_create_autocmd("PackChanged", {
    group = vim.api.nvim_create_augroup("dash_paq_version_evidence", { clear = true }),
    callback = invalidate_version_evidence,
  })

  commands.register_default({
    usage = "[!]",
    bang = true,
    impl = function(_, opts)
      ui.open(opts.bang)
    end,
  })
  commands.register("sync", {
    usage = "sync",
    impl = function()
      check_updates(false)
    end,
  })
  commands.register("status", {
    usage = "status",
    impl = function()
      check_updates(true)
    end,
  })
  commands.register("policy-rebuild", {
    usage = "policy-rebuild [plugin]",
    impl = policy_rebuild,
    complete = installed_plugin_complete,
  })
end

return M
