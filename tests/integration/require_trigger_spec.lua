-- lazy.nvim-style require-triggered loading (loader/modules.lua): a `require(modname)` miss whose top-level
-- segment is provided by an enabled, not-yet-loaded deferred entry loads that entry first, then the require
-- resolves normally via Neovim's own rtp searcher.
local t = require("runner")
local dirfixture = require("support.dirfixture")

_G.DASH_PAQ_TEST_LOG = {}

-- `require("reqeventplug")` before its `event` ever fires: the module itself (`attach`), the marker
-- `plugin/init.lua`, and `config()` must all run, as if the (never-fired) event trigger had loaded it.
local event_dir = dirfixture.new(
  "reqeventplug",
  dirfixture.marker_plugin_files("reqeventplug-loaded", {
    ["lua/reqeventplug.lua"] = [[
return {
  attach = function()
    table.insert(_G.DASH_PAQ_TEST_LOG, "reqeventplug-attach")
  end,
}
]],
  })
)

-- `require("reqsubplug.bar")`: the trigger must key off the top-level segment (`reqsubplug`), not the full
-- dotted module name.
local sub_dir = dirfixture.new(
  "reqsubplug",
  dirfixture.marker_plugin_files("reqsubplug-loaded", {
    ["lua/reqsubplug/init.lua"] = "return { name = 'reqsubplug' }\n",
    ["lua/reqsubplug/bar.lua"] = "return { value = 42 }\n",
  })
)

-- A dependency whose after/plugin file requires its parent's module (the nvim-cmp source pattern): the parent
-- must already be on 'runtimepath' while its dependencies load.
local dep_parent_dir =
  dirfixture.new("reqdepparent", { ["lua/reqdepparent.lua"] = "return { name = 'reqdepparent' }\n" })
local dep_child_dir = dirfixture.new("reqdepchild", {
  ["after/plugin/reqdepchild.lua"] = [[
local ok, parent = pcall(require, "reqdepparent")
table.insert(_G.DASH_PAQ_TEST_LOG, ok and ("reqdepchild-saw-" .. parent.name) or "reqdepchild-require-failed")
]],
})

-- Same pattern, but the require that loads the parent is itself the trigger: the dependency's nested
-- `require` evaluates the parent's module first, so the outer `require` must return that cached module
-- instead of evaluating it a second time (a second evaluation splits plugin state, e.g. two nvim-cmp cores).
local dbl_parent_dir = dirfixture.new("reqdblparent", {
  ["lua/reqdblparent.lua"] = [[
_G.DASH_PAQ_TEST_EVALS = (_G.DASH_PAQ_TEST_EVALS or 0) + 1
return { name = 'reqdblparent' }
]],
})
local dbl_child_dir = dirfixture.new("reqdblchild", {
  ["after/plugin/reqdblchild.lua"] = "require('reqdblparent')\n",
})

-- Disabled: `require("reqdisabledplug")` must never load it, despite providing a matching `lua/` module.
local disabled_dir = dirfixture.new("reqdisabledplug", { ["lua/reqdisabledplug.lua"] = "return {}\n" })

require("dash_paq").setup({
  spec = {
    {
      dir = event_dir,
      name = "reqeventplug",
      event = "CursorHold",
      config = function()
        table.insert(_G.DASH_PAQ_TEST_LOG, "reqeventplug-config-ran")
      end,
    },
    {
      dir = sub_dir,
      name = "reqsubplug",
      cmd = "ReqSubCmd",
    },
    {
      dir = dep_parent_dir,
      name = "reqdepparent",
      event = "CursorHold",
      dependencies = { { dir = dep_child_dir, name = "reqdepchild" } },
    },
    {
      dir = dbl_parent_dir,
      name = "reqdblparent",
      cmd = "ReqDblCmd",
      dependencies = { { dir = dbl_child_dir, name = "reqdblchild" } },
    },
    {
      dir = disabled_dir,
      name = "reqdisabledplug",
      event = "CursorHold",
      enabled = false,
    },
  },
  dashboard = false,
  version_policy = false,
})

-- Headless `nvim -l` has no attached UI, so `:DashPaq trace`'s floating window falls back to `:sbuffer`, landing
-- the trace buffer in a new split; read it back and close the split again.
local function pack_trace_lines(filter)
  vim.cmd("DashPaq trace " .. filter)
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.cmd("close")
  return lines
end

-- Line 4 of a filtered `:DashPaq trace <name>` is the single matching data row
-- (title, header, blank, then it); `loaded_by` is its 3rd ` | `-joined field.
local function loaded_by(filter)
  local data_line = pack_trace_lines(filter)[4]
  if not data_line then
    return nil
  end
  return vim.split(data_line, " | ", { plain = true })[3]
end

t.describe("a deferred event-triggered plugin is required before its event ever fires", function()
  t.it("is not loaded at startup", function()
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "reqeventplug-loaded"))
  end)

  local mod = require("reqeventplug")

  t.it("loads the plugin (plugin/init.lua marker ran)", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "reqeventplug-loaded"))
  end)

  t.it("runs the spec's config()", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "reqeventplug-config-ran"))
  end)

  t.it("resolves the real module table via require(), not a stub", function()
    t.assert.truthy(type(mod) == "table" and type(mod.attach) == "function")
    mod.attach()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "reqeventplug-attach"))
  end)

  t.it("traces the load reason as require:<modname>", function()
    t.assert.equals("require:reqeventplug", loaded_by("reqeventplug"))
  end)
end)

t.describe("a submodule require targets a cmd-deferred entry by its top-level segment", function()
  t.it("is not loaded at startup", function()
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "reqsubplug-loaded"))
  end)

  local bar = require("reqsubplug.bar")

  t.it("loads the owning entry", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "reqsubplug-loaded"))
  end)

  t.it("resolves the submodule itself", function()
    t.assert.equals(42, bar.value)
  end)

  t.it("traces the load reason with the full dotted module name", function()
    t.assert.equals("require:reqsubplug.bar", loaded_by("reqsubplug"))
  end)
end)

t.describe("a disabled entry provides a matching lua/ module", function()
  t.it("is never loaded by require(); the require itself errors", function()
    t.assert.raises(function()
      require("reqdisabledplug")
    end, "not found")
  end)

  t.it("never appears as loaded", function()
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "reqdisabledplug-loaded"))
  end)
end)

t.describe("a required module isn't owned by any entry", function()
  t.it("falls through untouched to a normal 'module not found' error", function()
    t.assert.raises(function()
      require("dash_paq_test_totally_unknown_module_zzz")
    end, "not found")
  end)
end)
t.describe("a dependency's after/plugin requires its parent's module while the parent loads", function()
  vim.api.nvim_exec_autocmds("CursorHold", {})

  t.it("finds the parent on 'runtimepath' (no module-not-found)", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "reqdepchild-saw-reqdepparent"))
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "reqdepchild-require-failed"))
  end)
end)

t.describe("a require that loads the parent while its dependency also requires it", function()
  local mod = require("reqdblparent")

  t.it("evaluates the parent's module exactly once", function()
    t.assert.equals(1, _G.DASH_PAQ_TEST_EVALS)
  end)

  t.it("returns the cached module", function()
    t.assert.truthy(mod == package.loaded["reqdblparent"])
  end)
end)

t.finish()
