-- dash-paq.nvim: a `vim.pack`-native lazy-loading layer plus an update
-- dashboard with tag-vs-branch version policy and breaking-change detection.
local M = {}

local configured = false

function M.is_configured()
  return configured
end

---@param opts table `{ spec?, modules?, dashboard?, version_policy?, default_host?, hosts?, dev? }`; see README/doc for field semantics.
function M.setup(opts)
  if configured then
    error("dash_paq.setup() was already called; call it exactly once during startup", 2)
  end
  local config = require("dash_paq.config").setup(opts)
  configured = true

  local dashboard = nil
  if config.dashboard then
    dashboard = require("dash_paq.dashboard")
  end

  require("dash_paq.loader").setup(config, dashboard)
end

return M
