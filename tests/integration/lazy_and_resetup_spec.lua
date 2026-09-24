-- lazy = true with no trigger stays deferred forever (loadable only via :PackLoad or as a dependency).
-- A second setup() call errors clearly instead of silently duplicating commands/autocmds.
local t = require("runner")
local dirfixture = require("support.dirfixture")

_G.PACK_COMPANION_TEST_LOG = {}

local lazy_dir = dirfixture.new("lazyplug", dirfixture.marker_plugin_files("lazyplug-loaded"))

require("pack_companion").setup({
  spec = {
    { dir = lazy_dir, name = "lazyplug", lazy = true },
  },
  dashboard = false,
  version_policy = false,
})

t.describe("a spec sets lazy = true with no trigger", function()
  t.it("does not load the plugin at startup", function()
    t.assert.falsy(vim.tbl_contains(_G.PACK_COMPANION_TEST_LOG, "lazyplug-loaded"))
  end)

  t.it("loads the plugin once :PackLoad is used", function()
    vim.cmd("PackLoad lazyplug")
    t.assert.truthy(vim.tbl_contains(_G.PACK_COMPANION_TEST_LOG, "lazyplug-loaded"))
  end)
end)

t.describe("pack_companion.setup() is called a second time", function()
  t.it("raises a clear error instead of silently re-registering commands/autocmds", function()
    t.assert.raises(function()
      require("pack_companion").setup({ spec = { { dir = lazy_dir, name = "lazyplug2" } } })
    end, "setup%(%) was already called")
  end)
end)

t.finish()
