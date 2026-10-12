-- `run_row_op`'s lifecycle against a stubbed pipeline whose `on_each`/`on_done` the test drives by hand, and a
-- captured `vim.defer_fn` so every drain step is fired explicitly: applies are separated by a yield even when results
-- arrive in separate callbacks, the busy flag is always released, a result is tallied once, and a raising
-- `on_finalize` cannot skip the final render.
local t = require("runner")
local dirfixture = require("support.dirfixture")

local plug = dirfixture.new("rowop", dirfixture.marker_plugin_files("rowop-loaded"))
require("dash_paq").setup({
  spec = { { dir = plug, name = "rowop" } },
  dashboard = true,
  version_policy = false,
})

local view = require("dash_paq.dashboard.ui.view")
local refresh = require("dash_paq.dashboard.ui.refresh")
local report = require("dash_paq.dashboard.report")
local state = require("dash_paq.dashboard.state")

local orig_pipeline = report.run_refresh_pipeline
local orig_defer_fn = vim.defer_fn
local orig_notify = vim.notify
local orig_render_row = view.render_row

local function new_ctx()
  return view.new_context({
    bufnr = vim.api.nvim_create_buf(false, true),
    rows = {},
    selected = {},
    filter_mode = "all",
    sort_mode = "status",
    search_text = nil,
  })
end

local function update_result(name)
  return { name = name, status = "update", source = "git", path = "/dev/null", rev_before = "a", rev_after = "b" }
end

-- Runs one op against a hand-driven pipeline. Returns a handle with the captured callbacks/timers/notifications.
local function start_op(spec_extra)
  local h = { timers = {}, delays = {}, notified = {}, applied = {}, batches = {}, finalized = 0, counts = nil }
  report.run_refresh_pipeline = function(_, _, on_each, on_done)
    h.on_each, h.on_done = on_each, on_done
  end
  vim.defer_fn = function(fn, ms)
    h.timers[#h.timers + 1] = fn
    h.delays[#h.delays + 1] = ms
  end
  vim.notify = function(msg, level)
    h.notified[#h.notified + 1] = { msg = msg, level = level }
  end
  h.ctx = new_ctx()
  local spec = vim.tbl_extend("force", {
    online = false,
    apply_rows = function(names)
      for _, name in ipairs(names) do
        h.applied[#h.applied + 1] = name
      end
      h.batches[#h.batches + 1] = #names
      return true
    end,
    on_finalize = function(counts)
      h.finalized = h.finalized + 1
      h.counts = vim.deepcopy(counts)
    end,
  }, spec_extra or {})
  h.ok, h.err = pcall(refresh.run_row_op, h.ctx, spec)
  return h
end

local function fire_timer(h)
  local fn = table.remove(h.timers, 1)
  fn()
end

local function restore()
  report.run_refresh_pipeline = orig_pipeline
  vim.defer_fn = orig_defer_fn
  vim.notify = orig_notify
  view.render_row = orig_render_row
end

t.describe("results delivered in separate callbacks of one event-loop pass", function()
  local h = start_op()
  h.on_each(update_result("u1"), 1, 3)
  local applied_after_first = #h.applied
  h.on_each(update_result("u2"), 2, 3)
  local applied_after_second = #h.applied
  h.on_each(update_result("u3"), 3, 3)
  h.on_done()
  local finalized_before_timers = h.finalized
  local steps = {}
  while #h.timers > 0 do
    fire_timer(h)
    steps[#steps + 1] = { applied = #h.applied, finalized = h.finalized }
  end
  restore()

  t.it("applies the first immediately", function()
    t.assert.equals(1, applied_after_first)
  end)

  t.it("does not start another apply back-to-back: later results only queue until the yield fires", function()
    t.assert.equals(1, applied_after_second)
  end)

  t.it("applies one queued row per yield and finalizes only on the step after the last apply", function()
    t.assert.equals(0, finalized_before_timers)
    t.assert.same({
      { applied = 2, finalized = 0 },
      { applied = 3, finalized = 0 },
      { applied = 3, finalized = 1 },
    }, steps)
  end)

  t.it("tallies each row once and releases the busy flag", function()
    t.assert.same({ update = 0, same = 3, error = 0 }, h.counts)
    t.assert.equals(false, h.ctx.online_check_running)
  end)
end)

t.describe("an update result arriving while the cursor just moved", function()
  local h = start_op()
  -- Stamped in the future so a slow machine cannot outlast the idle window before `on_each` runs.
  state.last_cursor_move = vim.uv.hrtime() + 1e9
  h.on_each(update_result("u1"), 1, 1)
  h.on_done()
  local applied_while_moving = #h.applied
  local hold_ms = h.delays[1]
  state.last_cursor_move = vim.uv.hrtime() - 1e9
  while #h.timers > 0 do
    fire_timer(h)
  end
  state.last_cursor_move = nil
  restore()

  t.it("holds the apply and retries once the cursor has been still for the idle window", function()
    t.assert.equals(0, applied_while_moving)
    -- Stamped 1 s ahead: the hold is that second plus the 300 ms window, less any elapsed time.
    t.assert.truthy(hold_ms > 300 and hold_ms <= 1300)
  end)

  t.it("applies the row once the cursor is idle, then finalizes", function()
    t.assert.same({ "u1" }, h.applied)
    t.assert.equals(1, h.finalized)
  end)
end)

t.describe("the dashboard's cursor stamp", function()
  local bindings = require("dash_paq.dashboard.ui.bindings")
  local ctx = new_ctx()
  vim.api.nvim_buf_set_lines(ctx.bufnr, 0, -1, false, { "a", "b", "c" })
  local win = vim.api.nvim_open_win(ctx.bufnr, true, { relative = "editor", row = 0, col = 0, width = 20, height = 5 })
  bindings.attach(ctx)
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  vim.cmd("doautocmd CursorMoved")
  local first = state.last_cursor_move
  -- A spinner frame rewrites the cursor's row in place, which also fires CursorMoved.
  vim.bo[ctx.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(ctx.bufnr, 1, 2, false, { "b2" })
  vim.cmd("doautocmd CursorMoved")
  local after_rewrite = state.last_cursor_move
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  vim.cmd("doautocmd CursorMoved")
  local after_move = state.last_cursor_move
  vim.api.nvim_win_close(win, true)
  state.last_cursor_move = nil

  t.it("stamps when the cursor line changes", function()
    t.assert.truthy(first ~= nil)
    t.assert.truthy(after_move ~= first)
  end)

  t.it("does not restamp when only the cursor's row is rewritten", function()
    t.assert.equals(first, after_rewrite)
  end)
end)

t.describe("a result arriving after the op already finalized", function()
  local h = start_op()
  h.on_each(update_result("u1"), 1, 1)
  h.on_done()
  while #h.timers > 0 do
    fire_timer(h)
  end
  local finalized = h.finalized
  h.on_each(update_result("late"), 2, 1)
  h.on_each({ name = "late_same", status = "same", source = "git", path = "/dev/null" }, 3, 1)
  restore()

  t.it("finalized once", function()
    t.assert.equals(1, finalized)
  end)

  t.it("does not resurrect the progress line or apply the late row", function()
    t.assert.is_nil(h.ctx.online_check_progress)
    t.assert.same({ "u1" }, h.applied)
  end)

  t.it("does not write a late result into the report cache", function()
    t.assert.is_nil(require("dash_paq.dashboard.state").pack_report_cache.plugins.late_same)
  end)
end)

t.describe("apply_pipeline_result raises after the row was already tallied", function()
  local raised = false
  local h
  do
    -- First render of the row raises once (after the tally); the drain's fallback re-applies it as an error.
    view.render_row = function(...)
      if not raised then
        raised = true
        error("boom-render")
      end
      return orig_render_row(...)
    end
    h = start_op()
    h.on_each(update_result("u1"), 1, 1)
    h.on_done()
    while #h.timers > 0 do
      fire_timer(h)
    end
    restore()
  end

  t.it("counts the row once, as an error", function()
    t.assert.same({ update = 0, same = 0, error = 1 }, h.counts)
  end)
end)

t.describe("the pipeline raises synchronously before delivering anything", function()
  report.run_refresh_pipeline = function()
    error("boom-pipeline")
  end
  vim.defer_fn = function() end
  local notified = {}
  vim.notify = function(msg, level)
    notified[#notified + 1] = { msg = msg, level = level }
  end
  local ctx = new_ctx()
  local ok = pcall(refresh.run_row_op, ctx, { online = false })
  restore()

  t.it("does not raise out of run_row_op, and reports an error", function()
    t.assert.truthy(ok)
    t.assert.truthy(notified[1] and notified[1].level == vim.log.levels.ERROR)
    t.assert.truthy(notified[1].msg:find("boom%-pipeline"))
  end)

  t.it("releases the busy flag and the spinner so the next op can run", function()
    t.assert.equals(false, ctx.online_check_running)
    t.assert.is_nil(ctx.spinner_timer)
    t.assert.same({}, ctx.refreshing)
  end)
end)

t.describe("setup work before the pipeline raises", function()
  local orig_collect = report.collect_dashboard_rows
  report.collect_dashboard_rows = function()
    error("boom-collect")
  end
  local ctx = new_ctx()
  local ok, err = pcall(refresh.run_row_op, ctx, { online = false })
  report.collect_dashboard_rows = orig_collect

  t.it("propagates the error but leaves the dashboard not busy", function()
    t.assert.falsy(ok)
    t.assert.truthy(tostring(err):find("boom%-collect"))
    t.assert.equals(false, ctx.online_check_running)
  end)
end)

t.describe("on_finalize raises", function()
  local h = start_op({
    on_finalize = function()
      error("boom-finalize")
    end,
  })
  h.on_each(update_result("u1"), 1, 1)
  h.on_done()
  while #h.timers > 0 do
    fire_timer(h)
  end
  restore()

  t.it("reports it and still completes the op (busy flag released, final render reached)", function()
    t.assert.equals(false, h.ctx.online_check_running)
    local found = false
    for _, n in ipairs(h.notified) do
      if n.level == vim.log.levels.ERROR and tostring(n.msg):find("boom%-finalize") then
        found = true
      end
    end
    t.assert.truthy(found)
  end)
end)

t.describe("apply_batch_size = 2 with four queued updates", function()
  local h = start_op({ apply_batch_size = 2 })
  h.on_each(update_result("u1"), 1, 4)
  -- u1 applied alone (queue was empty when it arrived); the rest arrive during the yield and batch up to the cap.
  h.on_each(update_result("u2"), 2, 4)
  h.on_each(update_result("u3"), 3, 4)
  h.on_each(update_result("u4"), 4, 4)
  h.on_done()
  while #h.timers > 0 do
    fire_timer(h)
  end
  restore()

  t.it("takes up to the batch size per call, in queue order", function()
    t.assert.same({ 1, 2, 1 }, h.batches)
    t.assert.same({ "u1", "u2", "u3", "u4" }, h.applied)
  end)

  t.it("tallies every row of every batch once", function()
    t.assert.same({ update = 0, same = 4, error = 0 }, h.counts)
  end)
end)

t.describe("a batch whose apply_rows raises", function()
  local h = start_op({
    apply_batch_size = 2,
    apply_rows = function()
      error("boom-batch")
    end,
  })
  h.on_each(update_result("u1"), 1, 3)
  h.on_each(update_result("u2"), 2, 3)
  h.on_each(update_result("u3"), 3, 3)
  h.on_done()
  while #h.timers > 0 do
    fire_timer(h)
  end
  restore()

  t.it("marks every row of the batch as an error row and still finalizes once", function()
    t.assert.same({ update = 0, same = 0, error = 3 }, h.counts)
    t.assert.equals(1, h.finalized)
  end)
end)

t.finish()
