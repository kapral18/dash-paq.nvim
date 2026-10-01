-- `version_policy = false` must disable cached tag/branch pins entirely: a stale on-disk version_policy.json
-- from a prior session must never be read/applied, and the dashboard's own U (update) op must never write one.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local remote = gitfixture.new_remote("pinnedplug")
gitfixture.commit(remote, "feat: initial", { ["README.md"] = "v1" })
gitfixture.tag(remote, "v1.0.0")
gitfixture.push(remote)

-- Pre-seed the on-disk cache with a strong pin, as if a prior setup() (with the policy enabled) wrote it.
local policy_dir = vim.fs.joinpath(vim.fn.stdpath("state"), "dash-paq")
local policy_path = vim.fs.joinpath(policy_dir, "version_policy.json")
vim.fn.mkdir(policy_dir, "p")
vim.fn.writefile({
  vim.json.encode({
    schema = 3,
    generated_at = os.time(),
    plugins = {
      pinnedplug = { strategy = "tags", latest_tag = "v9.9.9", semver_tags = true, tag_count = 1 },
    },
  }),
}, policy_path)

local updateplug = gitfixture.new_remote("updateplug")
gitfixture.commit(updateplug, "feat: initial", { ["README.md"] = "v1" })
gitfixture.push(updateplug)

require("dash_paq").setup({
  spec = {
    { src = remote.src, name = "pinnedplug" },
    { src = updateplug.src, name = "updateplug", version = false },
  },
  dashboard = true,
  version_policy = false,
})

-- New commit after install, so an online refresh sees a pending update for updateplug.
gitfixture.commit(updateplug, "feat: another commit", { ["more.txt"] = "y" })
gitfixture.push(updateplug)

t.describe("version_policy = false and a stale cached pin already exists on disk", function()
  t.it("installs the plugin without applying the stored tag pin", function()
    local info = vim.pack.get({ "pinnedplug" }, { info = false })
    t.assert.equals(1, #info)
    t.assert.is_nil(info[1].spec.version)
  end)
end)

t.describe("the `U` op updates a plugin with a pending update", function()
  local view = require("dash_paq.dashboard.ui.view")
  local refresh = require("dash_paq.dashboard.ui.refresh")
  local operations = require("dash_paq.dashboard.ui.operations")
  local report = require("dash_paq.dashboard.report")

  -- Delete the stale pin file so this block observes only what the U op itself does.
  vim.fn.delete(policy_path)

  local bufnr = vim.api.nvim_create_buf(false, true)
  local ctx = view.new_context({
    bufnr = bufnr,
    rows = report.collect_dashboard_rows(),
    selected = {},
    filter_mode = "all",
    sort_mode = "status",
    search_text = nil,
  })

  -- Matches the real dashboard flow: R refresh before U update.
  refresh.refresh(ctx, true)
  t.wait_until(function()
    return ctx.online_check_running == false
  end, 10000, "initial online refresh never finished")

  t.it("has detected the pending update before running the update op", function()
    local row
    for _, r in ipairs(ctx.rows or {}) do
      if r.name == "updateplug" then
        row = r
      end
    end
    t.assert.truthy(row ~= nil)
    t.assert.equals("update", row.status)
  end)

  operations.update_by_names(ctx, { "updateplug" }, "none", "noop")
  t.wait_until(function()
    return ctx.online_check_running == false
  end, 10000, "update op never finished")

  t.it("has applied the update", function()
    local row
    for _, r in ipairs(ctx.rows or {}) do
      if r.name == "updateplug" then
        row = r
      end
    end
    t.assert.truthy(row ~= nil)
    t.assert.equals("same", row.status)
  end)

  t.it("does not write a version_policy.json file", function()
    t.assert.equals(0, vim.fn.filereadable(policy_path))
  end)
end)

t.describe(":DashPaq with the dashboard enabled", function()
  t.it("registers the loader and dashboard subcommands", function()
    t.assert.same(
      { "load", "lock", "policy-rebuild", "stats", "status", "sync", "toggle-dev", "trace" },
      vim.fn.getcompletion("DashPaq ", "cmdline")
    )
  end)

  t.it("completes lock actions", function()
    t.assert.same({ "export", "import", "info" }, vim.fn.getcompletion("DashPaq lock ", "cmdline"))
  end)

  t.it("exports the lockfile to a path containing a space", function()
    local dest = vim.fs.joinpath(vim.fn.stdpath("state"), "lock export", "lock.json")
    vim.cmd("DashPaq lock export " .. dest)
    t.assert.equals(1, vim.fn.filereadable(dest))
  end)

  t.it("reaches policy-rebuild, which warns while the policy is disabled", function()
    local notes = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    vim.cmd("DashPaq policy-rebuild")
    vim.notify = orig
    t.assert.equals(1, #notes)
    t.assert.equals(vim.log.levels.WARN, notes[1].level)
    t.assert.match("Version policy is disabled", notes[1].msg)
  end)
end)

t.finish()
