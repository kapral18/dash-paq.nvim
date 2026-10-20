-- A dev entry disabled by `cond`/`enabled` never loads, so it must not warn about its dev path or show as a
-- `local` dashboard row.
local t = require("runner")
local dirfixture = require("support.dirfixture")

local dev_root = dirfixture.tmp_dir("dev-disabled-root")
local present = dirfixture.new("disabledpresent-dev", dirfixture.marker_plugin_files("disabledpresent"))

local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  notified[#notified + 1] = { msg = msg, level = level }
end
require("dash_paq").setup({
  spec = {
    { name = "disabledmissing", dev = vim.fs.joinpath(dev_root, "no-such-dir"), cond = false },
    { name = "disabledpresent", dev = present, enabled = false },
    { name = "optionalonly", dev = vim.fs.joinpath(dev_root, "no-such-optional"), optional = true },
  },
  dashboard = { refresh_on_open = false },
  version_policy = false,
  dev = { path = dev_root, patterns = {}, fallback = true },
})
vim.wait(100)
vim.notify = orig_notify

t.describe("WHEN a dev entry is disabled", function()
  t.it("SHOULD not report its dev path", function()
    for _, n in ipairs(notified) do
      t.assert.falsy(n.msg:find("disabled", 1, true) or n.msg:find("optionalonly", 1, true), n.msg)
    end
  end)

  t.it("SHOULD not show it as a local dashboard row", function()
    local paths = require("dash_paq.dashboard.state").dev_plugin_paths_cache
    t.assert.is_nil(paths.disabledpresent)
  end)
end)

t.finish()
