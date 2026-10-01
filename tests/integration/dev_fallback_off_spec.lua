-- `dev.fallback = false`: a dev base that is missing, or exists but is not a plugin directory, disables the entry
-- with an error instead of loading its upstream `src`.
local t = require("runner")
local dirfixture = require("support.dirfixture")
local gitfixture = require("support.gitfixture")

_G.DASH_PAQ_TEST_LOG = {}

local function upstream(name)
  local remote = gitfixture.new_remote(name)
  gitfixture.commit(remote, "feat: initial", {
    ["plugin/init.lua"] = string.format([[table.insert(_G.DASH_PAQ_TEST_LOG, %q)]], name .. "-upstream-loaded"),
  })
  gitfixture.push(remote)
  return remote
end

local dev_root = dirfixture.tmp_dir("dev-fallback-off-root")
local missing_remote = upstream("offmissing")
local notplug_remote = upstream("offnotplug")
local not_plugin_dir = dirfixture.new("offnotplug-dev", { ["README.md"] = "docs only" })

local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  notified[#notified + 1] = { msg = msg, level = level }
end

require("dash_paq").setup({
  spec = {
    { src = missing_remote.src, name = "offmissing", dev = vim.fs.joinpath(dev_root, "no-such-dir") },
    { src = notplug_remote.src, name = "offnotplug", dev = not_plugin_dir },
  },
  dashboard = false,
  version_policy = false,
  dev = { path = dev_root, patterns = {}, fallback = false },
})

t.wait_until(function()
  return #notified >= 2
end, 5000, "expected two dev.fallback = false errors")
vim.notify = orig_notify

local function message_for(name)
  for _, n in ipairs(notified) do
    if n.msg:find(name .. ":", 1, true) == 1 then
      return n
    end
  end
end

t.describe("dev.fallback = false", function()
  t.it("disables a plugin whose dev base is missing, with an error", function()
    local n = message_for("offmissing")
    t.assert.truthy(n)
    t.assert.equals(vim.log.levels.ERROR, n.level)
    t.assert.truthy(n.msg:find("dev.fallback is false, disabling", 1, true))
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "offmissing-upstream-loaded"))
  end)

  t.it("disables a plugin whose dev base is not a plugin directory, with an error", function()
    local n = message_for("offnotplug")
    t.assert.truthy(n)
    t.assert.equals(vim.log.levels.ERROR, n.level)
    t.assert.truthy(n.msg:find("is not a plugin directory", 1, true))
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "offnotplug-upstream-loaded"))
  end)
end)

t.finish()
