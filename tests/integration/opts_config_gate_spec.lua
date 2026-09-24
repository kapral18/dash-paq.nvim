-- Auto setup(opts) runs only with opts or config = true.
local t = require("runner")
local dirfixture = require("support.dirfixture")

_G.PACK_COMPANION_SETUP_CALLS = {}

local function fake_module(name)
  package.preload[name] = function()
    return {
      setup = function(opts)
        _G.PACK_COMPANION_SETUP_CALLS[name] = opts
      end,
    }
  end
end

fake_module("with_opts")
fake_module("with_config_true")
fake_module("bare")
fake_module("with_explicit_config_fn")
fake_module("with_inplace_opts_fn")

local dirs = {
  with_opts = dirfixture.new("with_opts", dirfixture.marker_plugin_files("with_opts-loaded")),
  with_config_true = dirfixture.new("with_config_true", dirfixture.marker_plugin_files("with_config_true-loaded")),
  bare = dirfixture.new("bare", dirfixture.marker_plugin_files("bare-loaded")),
  with_explicit_config_fn = dirfixture.new(
    "with_explicit_config_fn",
    dirfixture.marker_plugin_files("with_explicit_config_fn-loaded")
  ),
  with_inplace_opts_fn = dirfixture.new(
    "with_inplace_opts_fn",
    dirfixture.marker_plugin_files("with_inplace_opts_fn-loaded")
  ),
}

require("pack_companion").setup({
  spec = {
    { dir = dirs.with_opts, name = "with_opts", opts = { greeting = "hi" } },
    { dir = dirs.with_config_true, name = "with_config_true", config = true },
    { dir = dirs.bare, name = "bare" },
    {
      dir = dirs.with_explicit_config_fn,
      name = "with_explicit_config_fn",
      opts = { x = 1 },
      config = function(_, opts)
        _G.PACK_COMPANION_SETUP_CALLS["with_explicit_config_fn:explicit"] = opts
      end,
    },
    {
      -- lazy.nvim-documented in-place form: mutates the `opts` table it is
      -- given and returns nothing.
      dir = dirs.with_inplace_opts_fn,
      name = "with_inplace_opts_fn",
      opts = function(_, opts)
        opts.mutated = true
      end,
    },
  },
  dashboard = false,
  version_policy = false,
})

t.describe("a spec supplies opts but no config function", function()
  t.it("auto-runs module.setup(opts)", function()
    t.assert.same({ greeting = "hi" }, _G.PACK_COMPANION_SETUP_CALLS.with_opts)
  end)
end)

t.describe("a spec sets config = true with no opts", function()
  t.it("auto-runs module.setup({}) because config = true was requested", function()
    t.assert.truthy(_G.PACK_COMPANION_SETUP_CALLS.with_config_true ~= nil)
  end)
end)

t.describe("a spec has neither opts nor config = true nor a config function", function()
  t.it("does not auto-run module.setup at all", function()
    t.assert.is_nil(_G.PACK_COMPANION_SETUP_CALLS.bare)
  end)
end)

t.describe("a spec has an explicit config function", function()
  t.it("runs the explicit config function instead of auto-setup", function()
    t.assert.same({ x = 1 }, _G.PACK_COMPANION_SETUP_CALLS["with_explicit_config_fn:explicit"])
  end)

  t.it("does not also call module.setup via the auto-setup path", function()
    t.assert.is_nil(_G.PACK_COMPANION_SETUP_CALLS.with_explicit_config_fn)
  end)
end)

t.describe("a spec's opts function mutates in place and returns nil", function()
  t.it("still auto-runs module.setup(opts) with the mutated table", function()
    t.assert.same({ mutated = true }, _G.PACK_COMPANION_SETUP_CALLS.with_inplace_opts_fn)
  end)
end)

t.finish()
