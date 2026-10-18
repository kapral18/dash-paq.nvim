-- lazy = true stays deferred until a manual load, require, or dependency needs it.
-- A second setup() call errors clearly instead of silently duplicating commands/autocmds.
local t = require("runner")
local dirfixture = require("support.dirfixture")

_G.DASH_PAQ_TEST_LOG = {}

local lazy_dir = dirfixture.new("lazyplug", dirfixture.marker_plugin_files("lazyplug-loaded"))

require("dash_paq").setup({
  spec = {
    { dir = lazy_dir, name = "lazyplug", lazy = true },
  },
  dashboard = false,
  version_policy = false,
})

t.describe("a spec sets lazy = true with no trigger", function()
  t.it("does not load the plugin at startup", function()
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "lazyplug-loaded"))
  end)

  t.it("SHOULD describe an untriggered deferred plugin accurately in trace", function()
    vim.cmd("DashPaq trace lazyplug")
    local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    t.assert.match("manual / require / dependency", lines)
    vim.cmd("close")
  end)

  t.it("loads the plugin once :DashPaq load is used", function()
    vim.cmd("DashPaq load lazyplug")
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "lazyplug-loaded"))
  end)
end)

t.describe("setup() runs with dashboard = false", function()
  t.it("registers only the loader's :DashPaq subcommands", function()
    t.assert.same({ "load", "toggle-dev", "trace" }, vim.fn.getcompletion("DashPaq ", "cmdline"))
  end)
end)

t.describe("dash_paq.setup() is called a second time", function()
  t.it("raises a clear error instead of silently re-registering commands/autocmds", function()
    t.assert.raises(function()
      require("dash_paq").setup({ spec = { { dir = lazy_dir, name = "lazyplug2" } } })
    end, "setup%(%) was already called")
  end)
end)

t.finish()
