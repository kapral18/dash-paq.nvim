-- pack-companion.nvim: a `vim.pack`-native lazy-loading layer plus an update
-- dashboard with tag-vs-branch version policy and breaking-change detection.
local M = {}

local configured = false

function M.is_configured()
  return configured
end

---@param opts table `{ spec?, modules?, dashboard?, version_policy?, default_host?, hosts?, dev? }`; see README/doc for field semantics.
function M.setup(opts)
  if configured then
    error("pack_companion.setup() was already called; call it exactly once during startup", 2)
  end
  local config = require("pack_companion.config").setup(opts)
  configured = true

  local dashboard = nil
  if config.dashboard then
    dashboard = require("pack_companion.dashboard")
  end

  require("pack_companion.loader").setup(config, dashboard)
end

return M
