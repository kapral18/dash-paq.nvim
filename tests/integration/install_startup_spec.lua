-- Real vim.pack install path (local file:// remote, no network): setup() installs every plugin and startup-
-- loads a non-lazy one, while a cmd-deferred plugin installs but only sources once its command is invoked.
local t = require("runner")
local gitfixture = require("support.gitfixture")

_G.DASH_PAQ_TEST_LOG = {}

local nonlazy = gitfixture.new_remote("nonlazy")
gitfixture.commit(nonlazy, "feat: initial plugin", {
  ["plugin/init.lua"] = [[
_G.DASH_PAQ_TEST_LOG = _G.DASH_PAQ_TEST_LOG or {}
table.insert(_G.DASH_PAQ_TEST_LOG, "nonlazy-loaded")
]],
})
gitfixture.push(nonlazy)

local deferred = gitfixture.new_remote("deferred")
gitfixture.commit(deferred, "feat: initial plugin", {
  ["plugin/init.lua"] = [[
_G.DASH_PAQ_TEST_LOG = _G.DASH_PAQ_TEST_LOG or {}
table.insert(_G.DASH_PAQ_TEST_LOG, "deferred-loaded")
-- The real command the loader's cmd-stub forwards to once loaded.
vim.api.nvim_create_user_command("DeferredCmd", function() end, {})
]],
})
gitfixture.push(deferred)

require("dash_paq").setup({
  spec = {
    { src = nonlazy.src, name = "nonlazy" },
    { src = deferred.src, name = "deferredplug", cmd = "DeferredCmd" },
  },
  dashboard = false,
  version_policy = false,
})

t.describe("setup() installs a non-lazy plugin from a real git remote", function()
  t.it("installs it on disk via vim.pack", function()
    local info = vim.pack.get({ "nonlazy" }, { info = false })
    t.assert.equals(1, #info)
    t.assert.equals(1, vim.fn.isdirectory(info[1].path))
  end)

  t.it("loads it (source plugin/**) at startup without any trigger", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "nonlazy-loaded"))
  end)

  t.it("puts it on 'runtimepath'", function()
    local info = vim.pack.get({ "nonlazy" }, { info = false })
    t.assert.truthy(vim.tbl_contains(vim.opt.rtp:get(), info[1].path))
  end)
end)

t.describe("setup() installs a cmd-deferred plugin from a real git remote", function()
  t.it("installs it on disk via vim.pack", function()
    local info = vim.pack.get({ "deferredplug" }, { info = false })
    t.assert.equals(1, #info)
    t.assert.equals(1, vim.fn.isdirectory(info[1].path))
  end)

  t.it("does not source its plugin/** at startup under default 'loadplugins'", function()
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "deferred-loaded"))
  end)

  t.it("is not on 'runtimepath' yet", function()
    local info = vim.pack.get({ "deferredplug" }, { info = false })
    t.assert.falsy(vim.tbl_contains(vim.opt.rtp:get(), info[1].path))
  end)

  t.it("sources its plugin/** once its command trigger is invoked", function()
    vim.cmd("DeferredCmd")
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "deferred-loaded"))
    local info = vim.pack.get({ "deferredplug" }, { info = false })
    t.assert.truthy(vim.tbl_contains(vim.opt.rtp:get(), info[1].path))
  end)
end)

t.finish()
