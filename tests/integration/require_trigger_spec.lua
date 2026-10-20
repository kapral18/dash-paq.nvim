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

-- A dependency's after/plugin file can require its parent's module while the parent is mid-load.
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

local shared_a = dirfixture.new("shared_a", { ["lua/shared/one.lua"] = 'return "one"' })
local shared_b = dirfixture.new("shared_b", { ["lua/shared/two.lua"] = 'return "two"' })
local linked = dirfixture.new("linked", {})
local linked_target =
  dirfixture.new("linked_target", { ["linked.lua"] = 'return "linked"', ["tree/init.lua"] = 'return "tree"' })
vim.fn.mkdir(linked .. "/lua", "p")
assert(vim.uv.fs_symlink(linked_target .. "/linked.lua", linked .. "/lua/linked.lua"))
assert(vim.uv.fs_symlink(linked_target .. "/tree", linked .. "/lua/linked_tree"))
assert(vim.uv.fs_symlink(linked_target .. "/absent", linked .. "/lua/broken.lua"))
local missing = dirfixture.tmp_dir("retry") .. "/later"
local optional_child = dirfixture.new("optional_child", dirfixture.marker_plugin_files("optional_child"))
local optional_parent = dirfixture.new("optional_parent", { ["lua/optional_parent.lua"] = "return true" })
local optional_seen = false
local late_root = dirfixture.tmp_dir("late-require")
local late_target = late_root .. "/restored"
local late_link = late_root .. "/linked"
assert(vim.uv.fs_symlink(late_target, late_link))
local retry_parent = dirfixture.new("retry_parent", {})
local retry_middle = dirfixture.new("retry_middle", {})
local retry_dependency = dirfixture.tmp_dir("retry-dependency") .. "/restored"
local retry_config_calls = 0
local primary_provider = dirfixture.new("primary_provider", {
  ["lua/primary_first.lua"] = 'return "primary"',
  ["lua/provider.lua"] = 'return "primary"',
})
local duplicate_provider = dirfixture.new("duplicate_provider", {
  ["lua/provider.lua"] = 'return "duplicate"',
  ["plugin/init.lua"] = "vim.g.duplicate_provider_loaded = true",
})
local restored_provider = dirfixture.tmp_dir("restored-provider") .. "/later"
-- An installed deferred Vimscript plugin: its directory exists but has no `lua/`.
local vimscript_only = dirfixture.new("vimscript_only", { ["plugin/vimscript_only.vim"] = "let g:vimscript_only = 1" })
local config_only_dependency = dirfixture.new("config-only-dependency", {})
local config_only_order = {}
local config_only_manual_calls = 0
local config_only_event_calls = 0
local config_only_disabled_dependency_loaded = false
local config_only_retry_dependency = dirfixture.new("config-only-déps", {})
local config_only_retry_calls = 0
local config_only_command_calls = 0
local config_only_dependency_seen = false

require("dash_paq").setup({
  spec = {
    {
      name = "k18-lsp-progress",
      dependencies = {
        {
          name = "config_only_dependency",
          dir = config_only_dependency,
          config = function()
            config_only_order[#config_only_order + 1] = "dependency"
          end,
        },
      },
      config = function()
        config_only_order[#config_only_order + 1] = "config"
      end,
    },
    {
      name = "config_only_manual",
      lazy = true,
      config = function()
        config_only_manual_calls = config_only_manual_calls + 1
      end,
    },
    {
      name = "config_only_event",
      event = { { event = "User", pattern = "ConfigOnlyEvent" } },
      config = function()
        config_only_event_calls = config_only_event_calls + 1
      end,
    },
    {
      name = "config_only_disabled_dependency",
      dependencies = { { name = "disabled_missing", dir = "", enabled = false } },
      config = function()
        config_only_disabled_dependency_loaded = true
      end,
    },
    {
      name = "config_only_retry",
      cmd = "ConfigOnlyRetry",
      dependencies = {
        {
          name = "config_only_middle",
          dependencies = { { name = "config_only_leaf", dir = config_only_retry_dependency } },
        },
      },
      config = function()
        config_only_retry_calls = config_only_retry_calls + 1
        config_only_dependency_seen = vim.g.config_only_dependency_ready == true
        vim.api.nvim_create_user_command("ConfigOnlyRetry", function()
          config_only_command_calls = config_only_command_calls + 1
        end, {})
      end,
    },
    { dir = primary_provider, name = "primary_provider", lazy = true },
    { dir = duplicate_provider, name = "duplicate_provider", lazy = true },
    { dir = restored_provider, name = "restored_provider", lazy = true },
    { dir = vimscript_only, name = "vimscript_only", cmd = "VimscriptOnly" },
    { dir = late_link, name = "late_require", lazy = true },
    {
      dir = retry_parent,
      name = "retry_parent",
      cmd = "LateDependencyCmd",
      dependencies = {
        {
          dir = retry_middle,
          name = "retry_middle",
          dependencies = { { dir = retry_dependency, name = "retry_leaf" } },
        },
      },
      config = function()
        retry_config_calls = retry_config_calls + 1
        assert(vim.g.retry_dependency_ready, "dependency must load before config")
      end,
    },
    {
      dir = optional_parent,
      name = "optional_parent",
      lazy = true,
      dependencies = { { dir = optional_child, name = "optional_child", optional = true } },
      config = function()
        optional_seen = vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "optional_child")
      end,
    },
    { dir = optional_child, name = "optional_child", lazy = true },
    { dir = shared_a, name = "shared_a", lazy = true },
    { dir = shared_b, name = "shared_b", lazy = true },
    { dir = linked, name = "linked", lazy = true },
    { dir = missing, name = "retry", lazy = true },
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

  t.it("resolves the parent's module during dependency loading", function()
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

t.describe("WHEN deferred plugins share a Lua namespace", function()
  t.it("SHOULD load the provider of each distinct module", function()
    t.assert.equals("one", require("shared.one"))
    t.assert.equals("two", require("shared.two"))
  end)
end)

t.describe("WHEN a deferred module is a symlink", function()
  t.it("SHOULD load through a linked Lua file", function()
    t.assert.equals("linked", require("linked"))
  end)

  t.it("SHOULD load through a linked module directory", function()
    t.assert.equals("tree", require("linked_tree"))
  end)

  t.it("SHOULD leave a broken link unresolved", function()
    t.assert.raises(function()
      require("broken")
    end, "not found")
  end)
end)

t.describe("WHEN an unavailable directory appears after a failed load", function()
  t.it("SHOULD permit a later load and report success only then", function()
    local notes = {}
    local original_notify = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("DashPaq load retry")
    local first = table.concat(notes, "\n")
    dirfixture.write(missing, "plugin/init.lua", "vim.g.retry_loaded = true")
    vim.cmd("DashPaq load retry")
    vim.notify = original_notify
    t.assert.truthy(vim.g.retry_loaded)
    t.assert.falsy(first:find("retry loaded", 1, true))
  end)
end)

t.describe("WHEN an optional dependency has another required spec", function()
  t.it("SHOULD load it before configuring the parent", function()
    require("optional_parent")
    t.assert.truthy(optional_seen)
  end)
end)

t.describe("WHEN an unavailable require provider becomes readable", function()
  t.it("SHOULD retry discovery through a restored directory symlink", function()
    t.assert.raises(function()
      require("late_require")
    end, "not found")
    dirfixture.write(late_target, "lua/late_require.lua", 'return "restored"')
    t.assert.equals("restored", require("late_require"))
  end)
end)

t.describe("WHEN a transitive dependency is unavailable", function()
  t.it("SHOULD keep the parent command retryable until the dependency appears", function()
    vim.cmd("LateDependencyCmd")
    local calls_before_retry = retry_config_calls
    local trigger_before_retry = vim.fn.exists(":LateDependencyCmd")
    dirfixture.write(retry_dependency, "plugin/init.lua", {
      "vim.g.retry_dependency_ready = true",
      'vim.api.nvim_create_user_command("LateDependencyCmd", function() vim.g.retry_dependency_command = true end, {})',
    })
    vim.cmd("LateDependencyCmd")
    t.assert.equals(0, calls_before_retry)
    t.assert.equals(2, trigger_before_retry)
    t.assert.equals(1, retry_config_calls)
    t.assert.truthy(vim.g.retry_dependency_command)
  end)
end)

t.describe("WHEN restoring a Lua root rebuilds module discovery", function()
  t.it("SHOULD preserve an already-loaded provider without loading a duplicate", function()
    t.assert.equals("primary", require("primary_first"))
    dirfixture.write(restored_provider, "lua/restored_provider.lua", "return true")
    require("restored_provider")
    t.assert.equals("primary", require("provider"))
    t.assert.falsy(vim.g.duplicate_provider_loaded)
  end)
end)

t.describe("WHEN a named entry has no src or dir", function()
  t.it("SHOULD configure it at startup after its filesystem dependency", function()
    t.assert.same({ "dependency", "config" }, config_only_order)
  end)

  t.it("SHOULD load a manually deferred entry only once", function()
    t.assert.equals(0, config_only_manual_calls)
    vim.cmd("DashPaq load config_only_manual")
    vim.cmd("DashPaq load config_only_manual")
    t.assert.equals(1, config_only_manual_calls)
  end)

  t.it("SHOULD configure an event-deferred entry only once", function()
    t.assert.equals(0, config_only_event_calls)
    vim.api.nvim_exec_autocmds("User", { pattern = "ConfigOnlyEvent" })
    vim.api.nvim_exec_autocmds("User", { pattern = "ConfigOnlyEvent" })
    t.assert.equals(1, config_only_event_calls)
  end)

  t.it("SHOULD ignore a disabled dependency with no directory", function()
    t.assert.truthy(config_only_disabled_dependency_loaded)
  end)

  t.it("SHOULD keep its command retryable while a transitive filesystem dependency is missing", function()
    t.assert.equals(0, vim.fn.delete(config_only_retry_dependency, "d"))
    vim.cmd("ConfigOnlyRetry")
    local calls_before_retry = config_only_retry_calls
    local trigger_before_retry = vim.fn.exists(":ConfigOnlyRetry")
    dirfixture.write(config_only_retry_dependency, "plugin/init.lua", "vim.g.config_only_dependency_ready = true")
    vim.cmd("ConfigOnlyRetry")
    vim.cmd("ConfigOnlyRetry")
    t.assert.equals(0, calls_before_retry)
    t.assert.equals(2, trigger_before_retry)
    t.assert.truthy(config_only_dependency_seen)
    t.assert.equals(1, config_only_retry_calls)
    t.assert.equals(2, config_only_command_calls)
  end)
end)

t.describe("WHEN a deferred plugin without lua/ is installed", function()
  t.it("SHOULD not rescan it on every require", function()
    local triggers = require("dash_paq.loader.triggers")
    local original = triggers.resolve_root
    local scans = 0
    triggers.resolve_root = function(entry)
      if entry.name == "vimscript_only" then
        scans = scans + 1
      end
      return original(entry)
    end
    pcall(require, "first_miss_builds_the_map")
    scans = 0
    for i = 1, 20 do
      pcall(require, "missing_module_" .. i)
    end
    triggers.resolve_root = original
    t.assert.equals(0, scans)
  end)
end)

t.finish()
