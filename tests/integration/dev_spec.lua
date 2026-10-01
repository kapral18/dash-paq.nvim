-- `dev = true` loads a matching spec from `opts.dev.path/<name>` (a local dir) instead of a `vim.pack` clone.
local t = require("runner")
local dirfixture = require("support.dirfixture")

_G.DASH_PAQ_TEST_LOG = {}

local dev_root = dirfixture.tmp_dir("dev-root")
local plugin_dir = vim.fs.joinpath(dev_root, "devplug")
vim.fn.mkdir(vim.fs.joinpath(plugin_dir, "plugin"), "p")
vim.fn.writefile(
  vim.split(dirfixture.marker_plugin_files("devplug-loaded")["plugin/init.lua"], "\n"),
  vim.fs.joinpath(plugin_dir, "plugin", "init.lua")
)

require("dash_paq").setup({
  spec = {
    -- `src` is a decoy: dev = true must resolve to the local directory first, never reaching it.
    { src = "https://example.invalid/owner/devplug.git", name = "devplug", dev = true },
  },
  dashboard = false,
  version_policy = false,
  dev = { path = dev_root, patterns = {}, fallback = true },
})

t.describe("a spec matches dev = true and its local dev directory exists", function()
  t.it("loads the plugin from the local dev directory at startup", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "devplug-loaded"))
  end)

  t.it("puts the dev directory on 'runtimepath'", function()
    t.assert.truthy(vim.tbl_contains(vim.opt.rtp:get(), plugin_dir))
  end)

  t.it("never registers the entry with vim.pack (never installed/updated/deleted)", function()
    -- vim.pack.get raises for a name it never installed; that proves devplug was never handed to vim.pack.add.
    t.assert.raises(function()
      vim.pack.get({ "devplug" }, { info = false })
    end, "not installed")
  end)
end)

t.finish()
