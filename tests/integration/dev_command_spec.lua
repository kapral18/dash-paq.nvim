-- `:DashPaq toggle-dev <plugin>`: flips a dev-capable plugin between its upstream clone and its dev checkout from an ex
-- command (dashboard disabled: the command belongs to the loader). The choice lands in dev.json (a restart applies it;
-- the restart prompt is stubbed to "No").
local t = require("runner")
local dirfixture = require("support.dirfixture")
local dev = require("dash_paq.loader.dev")
local fs = require("dash_paq.fs")

local dev_root = dirfixture.tmp_dir("dev-command-root")

local both_dir = dirfixture.new("bothplug-dev", dirfixture.marker_plugin_files("bothplug-loaded"))
local nosrc_dir = dirfixture.new("nosrcplug-dev", dirfixture.marker_plugin_files("nosrcplug-loaded"))

local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  notified[#notified + 1] = { msg = msg, level = level }
end

local prompts = {}
local orig_confirm = vim.fn.confirm
vim.fn.confirm = function(msg)
  prompts[#prompts + 1] = msg
  return 2
end

require("dash_paq").setup({
  spec = {
    { src = "https://example.invalid/owner/bothplug.git", name = "bothplug", dev = both_dir },
    { name = "nosrcplug", dev = nosrc_dir },
    { src = "https://example.invalid/owner/plainplug.git", name = "plainplug", lazy = true },
  },
  dashboard = false,
  version_policy = false,
  dev = { path = dev_root, patterns = {}, fallback = true },
})

local function last_notice()
  return notified[#notified]
end

local function saved(name)
  return dev.load_choices()[name]
end

t.describe(":DashPaq toggle-dev with a plugin that has both an upstream src and a dev checkout", function()
  t.it("starts on the dev checkout (no saved choice)", function()
    t.assert.is_nil(saved("bothplug"))
  end)

  t.it("first toggle switches to upstream and offers a restart", function()
    vim.cmd("DashPaq toggle-dev bothplug")
    t.assert.equals("upstream", saved("bothplug"))
    t.assert.truthy(prompts[#prompts]:find("bothplug: switching from the dev checkout to upstream.", 1, true))
  end)

  t.it("second toggle switches back to the dev checkout path", function()
    vim.cmd("DashPaq toggle-dev bothplug")
    t.assert.equals(fs.real_path(both_dir), saved("bothplug"))
    t.assert.truthy(prompts[#prompts]:find("switching from upstream to " .. fs.real_path(both_dir), 1, true))
  end)

  t.it("third toggle goes to upstream again", function()
    vim.cmd("DashPaq toggle-dev bothplug")
    t.assert.equals("upstream", saved("bothplug"))
  end)
end)

t.describe(":DashPaq toggle-dev refuses upstream when the installed clone lacks the dev checkout's modules", function()
  local stale_clone = dirfixture.new("bothplug-stale", { ["lua/oldname/init.lua"] = "return {}" })
  local dev_module_dir = dirfixture.new("bothplug-newdev", { ["lua/newname/init.lua"] = "return {}" })
  local orig_get = vim.pack.get

  t.it("keeps the dev choice, warns, and does not prompt", function()
    local cfg_dev = fs.real_path(both_dir)
    vim.cmd("DashPaq toggle-dev bothplug")
    t.assert.equals(cfg_dev, saved("bothplug"))
    local prompts_before = #prompts
    -- Stand-in for a dev checkout that provides `newname` while the clone only has `oldname`.
    local orig_default = dev.default_dir
    dev.default_dir = function()
      return dev_module_dir
    end
    local orig_matching = dev.matching_candidate_path
    dev.matching_candidate_path = function()
      return dev_module_dir
    end
    vim.pack.get = function()
      return { { path = stale_clone } }
    end
    local ok, err = pcall(vim.cmd, "DashPaq toggle-dev bothplug")
    vim.pack.get = orig_get
    dev.default_dir = orig_default
    dev.matching_candidate_path = orig_matching
    assert(ok, err)
    t.assert.equals(cfg_dev, saved("bothplug"))
    t.assert.equals(prompts_before, #prompts)
    t.assert.equals(vim.log.levels.WARN, last_notice().level)
    t.assert.truthy(last_notice().msg:find("bothplug: not switching to upstream", 1, true))
  end)
end)

t.describe(":DashPaq toggle-dev refusals leave dev.json untouched", function()
  local before = vim.deepcopy(dev.load_choices())

  t.it("a dev checkout with no upstream src has nothing to switch to", function()
    vim.cmd("DashPaq toggle-dev nosrcplug")
    t.assert.equals(vim.log.levels.WARN, last_notice().level)
    t.assert.truthy(last_notice().msg:find("no upstream", 1, true))
  end)

  t.it("a plugin without a dev checkout", function()
    vim.cmd("DashPaq toggle-dev plainplug")
    t.assert.equals("plainplug: no dev checkout configured", last_notice().msg)
  end)

  t.it("an unknown plugin", function()
    vim.cmd("DashPaq toggle-dev nope")
    t.assert.equals("nope: no dev checkout configured", last_notice().msg)
  end)

  t.it("a missing plugin name prints usage", function()
    vim.cmd("DashPaq toggle-dev")
    t.assert.truthy(last_notice().msg:find("Usage: :DashPaq toggle-dev <plugin>", 1, true))
  end)

  t.it("changed nothing", function()
    t.assert.same(before, dev.load_choices())
  end)
end)

t.describe(":DashPaq toggle-dev completion", function()
  t.it("lists only dev-capable plugins", function()
    t.assert.same({ "bothplug", "nosrcplug" }, vim.fn.getcompletion("DashPaq toggle-dev ", "cmdline"))
  end)

  t.it("is listed as a subcommand", function()
    t.assert.truthy(vim.tbl_contains(vim.fn.getcompletion("DashPaq ", "cmdline"), "toggle-dev"))
  end)
end)

vim.notify = orig_notify
vim.fn.confirm = orig_confirm
t.finish()
