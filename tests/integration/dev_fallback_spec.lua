-- A `dev` base that is missing, or exists but holds no plugin content, falls back to the spec's upstream `src` with
-- a warning (`dev.fallback = true`); with no `src` there is nothing to fall back to, so the entry is disabled with
-- an error. A valid dev checkout loads silently.
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

local dev_root = dirfixture.tmp_dir("dev-fallback-root")
local missing_remote = upstream("missingdev")
local notplug_remote = upstream("notplugdev")
local good_remote = upstream("gooddev")

local not_plugin_dir = dirfixture.new("notplugdev-dev", { ["README.md"] = "docs only" })
local good_dir = dirfixture.new("gooddev-dev", dirfixture.marker_plugin_files("gooddev-dev-loaded"))
local missing_dir = vim.fs.joinpath(dev_root, "no-such-dir")

local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  notified[#notified + 1] = { msg = msg, level = level }
end

require("dash_paq").setup({
  spec = {
    { src = missing_remote.src, name = "missingdev", dev = missing_dir },
    { src = notplug_remote.src, name = "notplugdev", dev = not_plugin_dir },
    { name = "nosrcdev", dev = vim.fs.joinpath(dev_root, "no-such-dir-2") },
    { src = good_remote.src, name = "gooddev", dev = good_dir },
  },
  dashboard = false,
  version_policy = false,
  dev = { path = dev_root, patterns = {}, fallback = true },
})

t.wait_until(function()
  return #notified >= 3
end, 5000, "expected three dev-resolution notifications")
vim.notify = orig_notify

local function message_for(name)
  for _, n in ipairs(notified) do
    if n.msg:find(name .. ":", 1, true) == 1 then
      return n
    end
  end
end

local function logged(marker)
  return vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, marker)
end

t.describe("a missing dev base with a src", function()
  t.it("warns that the path was not found and upstream is used", function()
    local n = message_for("missingdev")
    t.assert.truthy(n)
    t.assert.equals(vim.log.levels.WARN, n.level)
    t.assert.truthy(n.msg:find("dev path not found", 1, true))
    t.assert.truthy(n.msg:find("using upstream", 1, true))
  end)

  t.it("loads the upstream clone", function()
    t.assert.truthy(logged("missingdev-upstream-loaded"))
  end)
end)

t.describe("a dev base that exists but is not a plugin directory", function()
  t.it("warns and names the directory", function()
    local n = message_for("notplugdev")
    t.assert.truthy(n)
    t.assert.equals(vim.log.levels.WARN, n.level)
    t.assert.truthy(n.msg:find("is not a plugin directory", 1, true))
    t.assert.truthy(n.msg:find("using upstream", 1, true))
  end)

  t.it("loads the upstream clone, not the empty directory", function()
    t.assert.truthy(logged("notplugdev-upstream-loaded"))
    t.assert.falsy(vim.tbl_contains(vim.opt.rtp:get(), not_plugin_dir))
  end)
end)

t.describe("a missing dev base with no src", function()
  t.it("reports an error and disables the entry", function()
    local n = message_for("nosrcdev")
    t.assert.truthy(n)
    t.assert.equals(vim.log.levels.ERROR, n.level)
    t.assert.truthy(n.msg:find("no src to fall back to", 1, true))
  end)

  t.it("is disabled, so it cannot be loaded by name", function()
    local seen = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
      seen[#seen + 1] = { msg = msg, level = level }
    end
    vim.cmd("DashPaq load nosrcdev")
    vim.notify = orig
    t.assert.truthy(seen[1] and seen[1].msg:find("Unknown or disabled plugin", 1, true))
  end)
end)

t.describe("a valid dev checkout", function()
  t.it("loads from the dev dir without any notification", function()
    t.assert.is_nil(message_for("gooddev"))
    t.assert.truthy(logged("gooddev-dev-loaded"))
    t.assert.falsy(logged("gooddev-upstream-loaded"))
  end)
end)

t.finish()
