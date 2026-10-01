-- Dashboard-facing coverage for dev entries: {dir}/after on rtp, a single "local" row even with a stale
-- vim.pack clone of the same name, and "refresh all visible rows" not erroring when a dev row is among them.
local t = require("runner")
local dirfixture = require("support.dirfixture")
local gitfixture = require("support.gitfixture")

_G.DASH_PAQ_TEST_LOG = {}

local dev_root = dirfixture.tmp_dir("dev-dashboard-root")
local plugin_dir = vim.fs.joinpath(dev_root, "devplug")
vim.fn.mkdir(vim.fs.joinpath(plugin_dir, "plugin"), "p")
vim.fn.mkdir(vim.fs.joinpath(plugin_dir, "after", "plugin"), "p")
vim.fn.writefile(
  vim.split(dirfixture.marker_plugin_files("devplug-loaded")["plugin/init.lua"], "\n"),
  vim.fs.joinpath(plugin_dir, "plugin", "init.lua")
)
vim.fn.writefile(
  vim.split(dirfixture.marker_plugin_files("devplug-after-loaded")["plugin/init.lua"], "\n"),
  vim.fs.joinpath(plugin_dir, "after", "plugin", "init.lua")
)

-- A stale vim.pack clone under the same name, as if it had been vim.pack-managed before dev = true.
local remote = gitfixture.new_remote("devplug")
gitfixture.commit(remote, "feat: initial", { ["README.md"] = "hello" })
gitfixture.push(remote)
vim.pack.add({ { src = remote.src, name = "devplug" } }, { confirm = false, load = function() end })

-- A second dev entry with no vim.pack clone at all, alongside a real plugin: vim.pack.get(names) must skip
-- the dev name from the batch, or the real plugin's refresh would error out too.
local dev2_dir = vim.fs.joinpath(dev_root, "dev2plug")
vim.fn.mkdir(vim.fs.joinpath(dev2_dir, "plugin"), "p")
vim.fn.writefile({ "-- dev2plug marker" }, vim.fs.joinpath(dev2_dir, "plugin", "init.lua"))

local real_remote = gitfixture.new_remote("realplug")
gitfixture.commit(real_remote, "feat: initial", { ["README.md"] = "v1" })
gitfixture.push(real_remote)

require("dash_paq").setup({
  spec = {
    { src = remote.src, name = "devplug", dev = true },
    { src = "https://example.invalid/dev2plug", name = "dev2plug", dev = true },
    { src = real_remote.src, name = "realplug" },
  },
  dashboard = true,
  version_policy = false,
  dev = { path = dev_root, patterns = {}, fallback = true },
})

local report = require("dash_paq.dashboard.report")

t.describe("a dev entry's local directory has an after/plugin/**", function()
  t.it("puts {dir}/after on 'runtimepath' (same as :packadd would)", function()
    t.assert.truthy(vim.tbl_contains(vim.opt.rtp:get(), plugin_dir .. "/after"))
  end)

  t.it("sources its after/plugin/** at startup", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "devplug-after-loaded"))
  end)
end)

t.describe("a dev entry's name also has a stale vim.pack clone on disk", function()
  local dash_rows = report.collect_dashboard_rows()
  local matches = {}
  for _, row in ipairs(dash_rows) do
    if row.name == "devplug" then
      matches[#matches + 1] = row
    end
  end

  t.it("appears exactly once in the dashboard rows, not once per source", function()
    t.assert.equals(1, #matches)
  end)

  t.it("shows status 'local', never 'orphan', for the dev-managed name", function()
    t.assert.equals("local", matches[1].status)
  end)
end)

t.describe("the dashboard refreshes every visible row and a dev row is among them", function()
  local view = require("dash_paq.dashboard.ui.view")
  local refresh = require("dash_paq.dashboard.ui.refresh")
  local state = require("dash_paq.dashboard.state")

  local bufnr = vim.api.nvim_create_buf(false, true)
  local ctx = view.new_context({
    bufnr = bufnr,
    rows = {},
    selected = {},
    filter_mode = "all",
    sort_mode = "status",
    search_text = nil,
  })

  -- Including the synthetic dev name in vim.pack.get(names) would fail the whole batch and leave every row
  -- untouched, so assert concrete positive evidence: a fresh cache entry, and no failure notification.
  state.pack_report_cache.plugins.realplug = nil
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, ...)
    notified[#notified + 1] = msg
    return orig_notify(msg, ...)
  end

  local errored = false
  local ok = pcall(function()
    refresh.run_row_op(ctx, { names = nil, online = false })
  end)
  errored = not ok

  t.it("does not error scanning vim.pack for a synthetic dev name", function()
    t.assert.falsy(errored)
    t.wait_until(function()
      return ctx.online_check_running == false
    end, 5000, "refresh never finished")
    vim.notify = orig_notify
  end)

  t.it("does not report a failure reading vim.pack plugins for the whole batch", function()
    local saw_failure = false
    for _, msg in ipairs(notified) do
      if msg == "Failed to read vim.pack plugins" then
        saw_failure = true
      end
    end
    t.assert.falsy(saw_failure)
  end)

  t.it("repopulates the real plugin's cache entry", function()
    local entry = state.pack_report_cache.plugins.realplug
    t.assert.truthy(entry ~= nil)
    t.assert.truthy(entry.rev_after ~= nil and entry.rev_after ~= "")
  end)

  t.it("still resolves the dev row to 'local' after the refresh", function()
    local row
    for _, r in ipairs(ctx.rows or {}) do
      if r.name == "devplug" then
        row = r
      end
    end
    t.assert.truthy(row ~= nil)
    t.assert.equals("local", row.status)
  end)

  t.it("still refreshes the real (non-dev) plugin's row despite a dev name with no vim.pack clone", function()
    local row
    for _, r in ipairs(ctx.rows or {}) do
      if r.name == "realplug" then
        row = r
      end
    end
    t.assert.truthy(row ~= nil)
    t.assert.truthy(row.status ~= nil and row.status ~= "error")
  end)
end)

t.finish()
