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

require("dash_paq").setup({
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

local view = require("dash_paq.dashboard.ui.view")
local refresh = require("dash_paq.dashboard.ui.refresh")
local operations = require("dash_paq.dashboard.ui.operations")
local report = require("dash_paq.dashboard.report")
local state = require("dash_paq.dashboard.state")
local policy = require("dash_paq.policy")

state.dashboard_config.skip_risk_confirm = true
-- One row per apply: the sections below assert per-apply behavior; batching has its own section at the end.
state.dashboard_config.apply_batch_size = 1

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

-- apply_rows is documented to return ok, err rather than raise, but the drain loop pcalls it anyway and
-- must still finalize (and clear online_check_running) even if it does raise.
gitfixture.commit(remotes.alpha, "feat: one more commit", { ["more2.txt"] = "z" })
gitfixture.push(remotes.alpha)

refresh.refresh(ctx, true)
t.wait_until(function()
  return ctx.online_check_running == false
end, 10000, "refresh before the raising apply_rows never finished")

t.describe("apply_rows raises instead of returning ok, err", function()
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
    apply_rows = function()
      error("boom-per-row-apply")
    end,
  })
  t.wait_until(function()
    return ctx.online_check_running == false
  end, 10000, "run_row_op with a raising apply_rows never finalized")
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

-- The drain loop separates applies with a real event-loop yield
-- (`vim.defer_fn`), not a back-to-back `while` loop, while still never
-- overlapping two applies even when a re-entrant pipeline result for
-- another row arrives mid-apply.
for _, name in ipairs(names) do
  gitfixture.commit(remotes[name], "feat: yield-separated commit", { ["yield.txt"] = name })
  gitfixture.push(remotes[name])
end

refresh.refresh(ctx, true)
t.wait_until(function()
  return ctx.online_check_running == false
end, 10000, "refresh before the yield-separation update op never finished")

t.describe("the `U` op separates applies with a real event-loop yield, not a back-to-back loop", function()
  t.it("has detected a pending update for all 3 again", function()
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
  -- Armed as a one-shot 1ms libuv timer at the END of every apply: with a
  -- real yield between applies (`vim.defer_fn`), this timer always has time
  -- to fire before the next apply starts. A back-to-back `while` loop would
  -- start the next apply immediately, before the timer ever got a chance to
  -- run, failing `sentinel_violations == 0` below.
  local sentinel_fired = true
  local sentinel_violations = 0
  local orig_pack_update = vim.pack.update
  vim.pack.update = function(...)
    if not sentinel_fired then
      sentinel_violations = sentinel_violations + 1
    end
    concurrent = concurrent + 1
    apply_calls = apply_calls + 1
    max_concurrent = math.max(max_concurrent, concurrent)
    -- Pump the loop like the real vim.pack.update does, so a re-entrant
    -- pipeline result for another row can arrive while this apply is still
    -- "in flight" and must only enqueue, never start a second apply.
    vim.wait(20, function()
      return false
    end)
    concurrent = concurrent - 1
    sentinel_fired = false
    local uv = vim.uv or vim.loop
    local timer = uv.new_timer()
    timer:start(1, 0, function()
      sentinel_fired = true
      timer:stop()
      timer:close()
    end)
  end

  local finalize_calls = 0
  local orig_update_after_scan = refresh.update_after_scan
  refresh.update_after_scan = function(...)
    finalize_calls = finalize_calls + 1
    return orig_update_after_scan(...)
  end

  operations.update_by_names(ctx, names, "none", "noop")
  t.wait_until(function()
    return ctx.online_check_running == false
  end, 10000, "yield-separation update op never finished")
  vim.pack.update = orig_pack_update
  refresh.update_after_scan = orig_update_after_scan

  t.it("never runs two applies concurrently, even with a re-entrant pipeline result mid-apply", function()
    t.assert.equals(1, max_concurrent)
  end)

  t.it("applied all 3 rows", function()
    t.assert.equals(#names, apply_calls)
  end)

  t.it("always starts the next apply only after the previous apply's post-yield sentinel already fired", function()
    t.assert.equals(0, sentinel_violations)
  end)

  t.it("runs on_finalize exactly once", function()
    t.assert.equals(1, finalize_calls)
  end)
end)

-- Closing the dashboard buffer mid-op must not strand the step-timer chain:
-- `online_check_running` must still reset and no extra/leaked apply must run
-- past the queued set.
for _, name in ipairs(names) do
  gitfixture.commit(remotes[name], "feat: close-mid-op commit", { ["close.txt"] = name })
  gitfixture.push(remotes[name])
end

t.describe("closing the dashboard buffer mid-op does not leak the step timer", function()
  local close_bufnr = vim.api.nvim_create_buf(false, true)
  local close_ctx = view.new_context({
    bufnr = close_bufnr,
    rows = report.collect_dashboard_rows(),
    selected = {},
    filter_mode = "all",
    sort_mode = "status",
    search_text = nil,
  })

  refresh.refresh(close_ctx, true)
  t.wait_until(function()
    return close_ctx.online_check_running == false
  end, 10000, "refresh before the close-mid-op update op never finished")

  local apply_calls = 0
  local orig_pack_update = vim.pack.update
  vim.pack.update = function(...)
    apply_calls = apply_calls + 1
    if apply_calls == 1 then
      -- Close the dashboard buffer partway through the op, like a user
      -- quitting the window mid-refresh.
      pcall(vim.api.nvim_buf_delete, close_bufnr, { force = true })
    end
  end

  operations.update_by_names(close_ctx, names, "none", "noop")
  t.wait_until(function()
    return close_ctx.online_check_running == false
  end, 10000, "update op never finalized after the dashboard buffer was closed mid-op")
  vim.pack.update = orig_pack_update

  t.it("still applies every queued row despite the closed buffer", function()
    t.assert.equals(#names, apply_calls)
  end)

  t.it("clears online_check_running (finalize still ran; no stranded step timer)", function()
    t.assert.falsy(close_ctx.online_check_running)
  end)

  t.it("recorded every row as applied", function()
    t.assert.equals(#names, state.pack_report_cache.last_applied_count)
  end)

  local settled = false
  vim.defer_fn(function()
    settled = true
  end, 50)
  t.wait_until(function()
    return settled
  end, 1000, "post-finalize settle wait never completed")

  t.it("does not leak a stray extra apply after finalize", function()
    t.assert.equals(#names, apply_calls)
  end)
end)

-- The post-update version-policy refresh (on_finalize) must be async
-- (`refresh_version_policy_async`), so it never delays finalize/the final
-- render: at the moment finalize completes the policy file must not be
-- written yet, only eventually once the deferred step chain runs.
t.describe("post-update version-policy refresh runs async, not synchronously in finalize", function()
  local policy_path = policy.version_policy_path()
  pcall(vim.fn.delete, policy_path)

  local policy_remote = gitfixture.new_remote("policyplug")
  gitfixture.commit(policy_remote, "feat: initial", { ["README.md"] = "v1" })
  gitfixture.push(policy_remote)
  vim.pack.add({ { src = policy_remote.src, name = "policyplug" } }, { confirm = false, load = function() end })
  gitfixture.commit(policy_remote, "feat: another commit", { ["more.txt"] = "y" })
  gitfixture.push(policy_remote)

  -- This file's setup() ran with `version_policy = false` and setup() cannot
  -- be called a second time; flip the same live flag `on_finalize` reads
  -- (`dashboard/init.lua` sets this from `config.version_policy ~= false`)
  -- instead, to exercise the enabled branch.
  local prev_enabled = state.version_policy_enabled
  state.version_policy_enabled = true

  local policy_bufnr = vim.api.nvim_create_buf(false, true)
  local policy_ctx = view.new_context({
    bufnr = policy_bufnr,
    rows = report.collect_dashboard_rows(),
    selected = {},
    filter_mode = "all",
    sort_mode = "status",
    search_text = nil,
  })

  refresh.refresh(policy_ctx, true)
  t.wait_until(function()
    return policy_ctx.online_check_running == false
  end, 10000, "refresh before the policy update op never finished")

  local sync_calls, async_calls = 0, 0
  local orig_sync = policy.refresh_version_policy_if_needed
  local orig_async = policy.refresh_version_policy_async
  policy.refresh_version_policy_if_needed = function(...)
    sync_calls = sync_calls + 1
    return orig_sync(...)
  end
  policy.refresh_version_policy_async = function(...)
    async_calls = async_calls + 1
    return orig_async(...)
  end

  operations.update_by_names(policy_ctx, { "policyplug" }, "none", "noop")
  t.wait_until(function()
    return policy_ctx.online_check_running == false
  end, 10000, "policy update op never finished")

  policy.refresh_version_policy_if_needed = orig_sync
  policy.refresh_version_policy_async = orig_async

  t.it("never runs the blocking policy refresh in finalize, and starts the async one once", function()
    t.assert.equals(0, sync_calls)
    t.assert.equals(1, async_calls)
  end)

  t.it("eventually writes the version policy file via the async post-update refresh", function()
    t.wait_until(function()
      return vim.fn.filereadable(policy_path) == 1
    end, 5000, "version policy file was never written by the async post-update refresh")
  end)

  state.version_policy_enabled = prev_enabled
end)

-- Batched applies: `apply_batch_size` rows share one blocking `vim.pack.update` call, with a yield between batches.
for _, name in ipairs(names) do
  gitfixture.commit(remotes[name], "feat: batch commit", { ["batch.txt"] = name })
  gitfixture.push(remotes[name])
end

refresh.refresh(ctx, true)
t.wait_until(function()
  return ctx.online_check_running == false
end, 10000, "refresh before the batched update op never finished")

t.describe("apply_batch_size = 2 with 3 pending updates", function()
  state.dashboard_config.apply_batch_size = 2
  local calls = {}
  local orig_pack_update = vim.pack.update
  vim.pack.update = function(list, opts)
    calls[#calls + 1] = { names = vim.deepcopy(list), opts = vim.deepcopy(opts) }
  end
  operations.update_by_names(ctx, names, "none", "noop")
  t.wait_until(function()
    return ctx.online_check_running == false
  end, 10000, "batched update op never finished")
  vim.pack.update = orig_pack_update
  state.dashboard_config.apply_batch_size = 1

  t.it("runs one vim.pack.update per batch (2 rows, then the remaining 1)", function()
    local sizes = vim.tbl_map(function(c)
      return #c.names
    end, calls)
    table.sort(sizes)
    t.assert.same({ 1, 2 }, sizes)
  end)

  t.it("applies every row exactly once, offline and forced", function()
    local seen = {}
    for _, c in ipairs(calls) do
      t.assert.same({ offline = true, force = true }, c.opts)
      for _, n in ipairs(c.names) do
        seen[#seen + 1] = n
      end
    end
    table.sort(seen)
    t.assert.same(vim.deepcopy(names), seen)
  end)

  t.it("counts every applied row", function()
    t.assert.equals(#names, state.pack_report_cache.last_applied_count)
  end)
end)

t.finish()
