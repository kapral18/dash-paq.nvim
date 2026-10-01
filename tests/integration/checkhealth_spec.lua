-- `:checkhealth dash_paq` must run without a Lua error and report the
-- expected ok/warn lines for a healthy, already-configured setup.
local t = require("runner")
local dirfixture = require("support.dirfixture")

local plug_dir = dirfixture.new("healthplug", dirfixture.marker_plugin_files("healthplug-loaded"))

require("dash_paq").setup({
  spec = { { dir = plug_dir, name = "healthplug" } },
  dashboard = false,
  version_policy = false,
})

t.describe(":checkhealth dash_paq runs after setup()", function()
  local ok, err = pcall(vim.cmd, "silent checkhealth dash_paq")

  t.it("runs without raising a Lua error", function()
    if not ok then
      error("checkhealth raised: " .. tostring(err), 0)
    end
  end)

  t.it("reports the health buffer content confirming setup() was called", function()
    local health_buf = nil
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name:match("health://") then
        health_buf = bufnr
        break
      end
    end
    t.assert.truthy(health_buf ~= nil, "expected a health:// buffer to exist after :checkhealth")
    local lines = vim.api.nvim_buf_get_lines(health_buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    t.assert.match("setup%(%) has been called", text)
    t.assert.match("git found on PATH", text)
    t.assert.match("vim.pack is available", text)
    t.assert.match("state directory writable", text)
  end)
end)

t.finish()
