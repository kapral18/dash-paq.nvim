-- The real vim.pack.update blocks by pumping the event loop, long enough for other rows' pipeline callbacks to
-- run nested before the current apply returns. This stubs it the same way across 3 rows, and asserts the
-- applies never overlap and finalize waits for all of them.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local names = { "alpha", "beta", "gamma" }
local remotes = {}
for _, name in ipairs(names) do
  local remote = gitfixture.new_remote(name)
  gitfixture.commit(remote, "feat: initial", { ["README.md"] = "v1" })
  gitfixture.push(remote)
  remotes[name] = remote
end

require("pack_companion").setup({
  spec = {
    { src = remotes.alpha.src, name = "alpha", version = false },
    { src = remotes.beta.src, name = "beta", version = false },
    { src = remotes.gamma.src, name = "gamma", version = false },
  },
  dashboard = true,
  version_policy = false,
})

-- New commit on every remote after install, so an online refresh finds all three pending an update.
for _, name in ipairs(names) do
  gitfixture.commit(remotes[name], "feat: another commit", { ["more.txt"] = "y" })
  gitfixture.push(remotes[name])
end

local view = require("pack_companion.dashboard.ui.view")
local refresh = require("pack_companion.dashboard.ui.refresh")
local operations = require("pack_companion.dashboard.ui.operations")
local report = require("pack_companion.dashboard.report")
local state = require("pack_companion.dashboard.state")

state.dashboard_config.skip_risk_confirm = true

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

t.describe("the `U` op updates 3 plugins whose vim.pack.update blocks by pumping the loop", function()
  t.it("has detected a pending update for all 3 before running the update op", function()
    local statuses = {}
    for _, row in ipairs(ctx.rows or {}) do
      statuses[row.name] = row.status
    end
    for _, name in ipairs(names) do
      t.assert.equals("update", statuses[name], name .. " was not detected as pending an update")
    end
  end)

  local concurrent = 0
  local max_concurrent = 0
  local apply_calls = 0
  local orig_pack_update = vim.pack.update
  vim.pack.update = function(...)
    concurrent = concurrent + 1
    apply_calls = apply_calls + 1
    max_concurrent = math.max(max_concurrent, concurrent)
    -- Pump the loop like the real vim.pack.update does, so nested pipeline callbacks for other rows can run.
    vim.wait(50, function()
      return false
    end)
    concurrent = concurrent - 1
  end

  local finalize_calls = 0
  local apply_calls_at_finalize = nil
  local orig_update_after_scan = refresh.update_after_scan
  -- finalize() calls update_after_scan exactly once; hooked here to count how many times it ran.
  refresh.update_after_scan = function(...)
    finalize_calls = finalize_calls + 1
    if apply_calls_at_finalize == nil then
      apply_calls_at_finalize = apply_calls
    end
    return orig_update_after_scan(...)
  end

  operations.update_by_names(ctx, names, "none", "noop")
  t.wait_until(function()
    return ctx.online_check_running == false
  end, 10000, "update op never finished")
  vim.pack.update = orig_pack_update
  refresh.update_after_scan = orig_update_after_scan

  t.it("never runs two applies concurrently", function()
    t.assert.equals(1, max_concurrent)
  end)

  t.it("runs on_finalize exactly once", function()
    t.assert.equals(1, finalize_calls)
  end)

  t.it("runs finalize only after every update row was applied", function()
    t.assert.equals(#names, apply_calls_at_finalize)
  end)

  t.it("has applied every update row exactly once", function()
    t.assert.equals(#names, state.pack_report_cache.last_applied_count)
  end)

  t.it("leaves every row 'same'", function()
    local statuses = {}
    for _, row in ipairs(ctx.rows or {}) do
      statuses[row.name] = row.status
    end
    for _, name in ipairs(names) do
      t.assert.equals("same", statuses[name], name .. " did not end up 'same'")
    end
  end)
end)

-- per_row_apply is documented to return ok, err rather than raise, but the drain loop pcalls it anyway and
-- must still finalize (and clear online_check_running) even if it does raise.
gitfixture.commit(remotes.alpha, "feat: one more commit", { ["more2.txt"] = "z" })
gitfixture.push(remotes.alpha)

refresh.refresh(ctx, true)
t.wait_until(function()
  return ctx.online_check_running == false
end, 10000, "refresh before the raising per_row_apply never finished")

t.describe("per_row_apply raises instead of returning ok, err", function()
  t.it("has detected alpha as pending an update again", function()
    local statuses = {}
    for _, row in ipairs(ctx.rows or {}) do
      statuses[row.name] = row.status
    end
    t.assert.equals("update", statuses.alpha)
  end)

  local finalize_calls = 0
  local orig_update_after_scan2 = refresh.update_after_scan
  refresh.update_after_scan = function(...)
    finalize_calls = finalize_calls + 1
    return orig_update_after_scan2(...)
  end

  refresh.run_row_op(ctx, {
    names = { "alpha" },
    online = true,
    per_row_apply = function()
      error("boom-per-row-apply")
    end,
  })
  t.wait_until(function()
    return ctx.online_check_running == false
  end, 10000, "run_row_op with a raising per_row_apply never finalized")
  refresh.update_after_scan = orig_update_after_scan2

  t.it("still finalizes exactly once despite the raise", function()
    t.assert.equals(1, finalize_calls)
  end)

  t.it("clears online_check_running", function()
    t.assert.falsy(ctx.online_check_running)
  end)

  t.it("marks the row as an error row instead of leaving it stuck in-flight", function()
    local statuses = {}
    for _, row in ipairs(ctx.rows or {}) do
      statuses[row.name] = row.status
    end
    t.assert.equals("error", statuses.alpha)
  end)
end)

t.finish()
