-- lazy.nvim passes callbacks a plugin with `name` and `dir`: `init(plugin)`, `config(plugin, opts)`,
-- `build(plugin)`. Specs written that way (`plugin.dir .. "/vim"`) must work here too.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local remote = gitfixture.new_remote("callbacks")
gitfixture.commit(remote, "feat: initial", { ["README.md"] = "1" })
gitfixture.push(remote)

local init_dir = require("support.dirfixture").new("initplug", {})
local merged_dir = require("support.dirfixture").new("mergedplug", {})
local seen = {}
require("dash_paq").setup({
  spec = {
    -- One plugin from two specs: `init` in one, `config` in the other.
    {
      dir = merged_dir,
      name = "merged",
      config = function(plugin)
        seen.merged = plugin.from_other_spec
      end,
    },
    {
      name = "merged",
      init = function(plugin)
        plugin.from_other_spec = "merged"
      end,
    },
    -- No explicit `name`: it comes from `dir`, so only the view supplies it.
    {
      dir = init_dir,
      init = function(plugin)
        seen.init_dir = { name = plugin.name, dir = plugin.dir }
        plugin.from_init = "shared"
      end,
      keys = function(plugin)
        seen.keys_name = plugin.name
        return {}
      end,
      opts = function(plugin)
        seen.opts_name = plugin.name
        seen.opts_from_init = plugin.from_init
      end,
    },
    {
      src = remote.src,
      name = "callbacks",
      opts = { level = 2 },
      init = function(plugin)
        seen.init = plugin.name
        plugin.from_init = "kept"
      end,
      build = function(plugin)
        seen.build = { name = plugin.name, dir = plugin.dir }
      end,
      config = function(plugin, opts)
        seen.config = { name = plugin.name, dir = plugin.dir, opts = opts, spec_opts = plugin.opts }
        seen.from_init = plugin.from_init
      end,
    },
  },
  dashboard = false,
  version_policy = false,
})
vim.wait(1000, function()
  return seen.build ~= nil
end)
local path = vim.pack.get({ "callbacks" }, { info = false })[1].path

t.describe("WHEN callbacks are written the lazy.nvim way", function()
  t.it("SHOULD give init the plugin name", function()
    t.assert.equals("callbacks", seen.init)
  end)

  t.it("SHOULD give keys and opts functions the derived name", function()
    t.assert.equals(vim.fs.basename(init_dir), seen.keys_name)
    t.assert.equals(vim.fs.basename(init_dir), seen.opts_name)
  end)

  t.it("SHOULD give init the derived name and dir of a dir spec", function()
    t.assert.same({ name = vim.fs.basename(init_dir), dir = init_dir }, seen.init_dir)
  end)

  t.it("SHOULD give build the plugin name and install directory", function()
    t.assert.same({ name = "callbacks", dir = path }, seen.build)
  end)

  t.it("SHOULD give config the plugin name, directory, and the spec's fields", function()
    t.assert.same({ name = "callbacks", dir = path, opts = { level = 2 }, spec_opts = { level = 2 } }, seen.config)
  end)
end)

t.describe("WHEN init sets a field on its plugin", function()
  t.it("SHOULD keep it for config, as lazy.nvim's plugin object does", function()
    t.assert.equals("kept", seen.from_init)
  end)

  t.it("SHOULD keep it for config defined in another spec of the plugin", function()
    t.assert.equals("merged", seen.merged)
  end)

  t.it("SHOULD keep it for an opts function too", function()
    t.assert.equals("shared", seen.opts_from_init)
  end)
end)

t.finish()
