local report = require("dash_paq.dashboard.report")
local state = require("dash_paq.dashboard.state")
local view = require("dash_paq.dashboard.ui.view")
local rows = require("dash_paq.dashboard.ui.rows")
local version = require("dash_paq.dashboard.analysis.version")
local gitcmd = require("dash_paq.dashboard.analysis.gitcmd")

local M = {}

local SPINNER_INTERVAL_MS = 90

-- Gap between one queued update-apply and the next. Chaining with bare
-- `vim.schedule` would starve input, because Neovim drains newly queued
-- scheduled callbacks within the same event-queue pass; `vim.defer_fn` with
-- ms >= 1 actually yields, so each apply gets its own event-loop turn.
local APPLY_YIELD_MS = 10

-- A queued apply waits until the cursor has been still this long. Each apply
-- blocks input for its whole `vim.pack.update` call (hundreds of ms per
-- batch), so an apply that runs while the user moves through the rows makes
-- the cursor lag.
local CURSOR_IDLE_MS = 300
local operation_running = false
local pending_operations = {}

local function operation_done()
  operation_running = false
  local next_op = table.remove(pending_operations, 1)
  if next_op then
    operation_running = true
    vim.schedule(next_op)
  end
end

-- Stop and dispose the per-row spinner animation timer, if running.
local function stop_spinner(ctx)
  if ctx.spinner_timer then
    pcall(function()
      ctx.spinner_timer:stop()
      ctx.spinner_timer:close()
    end)
    ctx.spinner_timer = nil
  end
end

-- Redraw only pending rows and progress. Dispose the timer when the buffer closes.
local function start_spinner(ctx)
  stop_spinner(ctx)
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  ctx.spinner_timer = timer
  timer:start(
    SPINNER_INTERVAL_MS,
    SPINNER_INTERVAL_MS,
    vim.schedule_wrap(function()
      -- Self-dispose if the dashboard buffer was closed mid-refresh so the
      -- libuv timer never leaks past the window's lifetime.
      if not (ctx.bufnr and vim.api.nvim_buf_is_valid(ctx.bufnr)) then
        stop_spinner(ctx)
        return
      end
      if not (ctx.spinner_timer and next(ctx.refreshing)) then
        return
      end
      ctx.spinner_frame = (ctx.spinner_frame or 0) + 1
      view.render_header(ctx)
      for name in pairs(ctx.refreshing) do
        view.render_row(ctx, name)
      end
    end)
  )
end

-- Re-collect rows from the report cache, preserve selection by name, and
-- render. Used at the end of every row op / refresh.
function M.update_after_scan(ctx, current_name)
  ctx.rows = report.collect_dashboard_rows()
  local previous_selected = ctx.selected
  ctx.selected = {}
  for _, row in ipairs(ctx.rows) do
    if previous_selected[row.name] then
      ctx.selected[row.name] = true
    end
  end
  view.render(ctx)
  M.persist_ui_state(ctx)
  if current_name and ctx.winid and vim.api.nvim_win_is_valid(ctx.winid) then
    for line, row in pairs(ctx.row_by_line) do
      if row.name == current_name then
        pcall(vim.api.nvim_win_set_cursor, ctx.winid, { line, 0 })
        break
      end
    end
  end
end

-- Apply one resolved plugin result into the report cache, then refresh just
-- that row in place. Each plugin flips from its spinner to its final status
-- independently, in completion order, with no full-table redraw.
local function apply_pipeline_result(ctx, result, counts)
  local name = result.name
  -- Re-applying a result (the drain's fallback after a first pass raised past its
  -- tally) moves it between buckets instead of counting it twice.
  if result.counted then
    counts[result.counted] = counts[result.counted] - 1
    result.counted = nil
  end
  if result.status == "error" then
    state.pack_report_cache.plugins[name] = {
      status = "error",
      source = result.source,
      path = result.path,
      pending_updates = tostring(result.error or "refresh failed"),
    }
    counts.error = counts.error + 1
    result.counted = "error"
  else
    local prev = state.pack_report_cache.plugins[name]
    local entry = type(prev) == "table" and prev or {}
    entry.status = result.status
    entry.source = result.source
    -- `infer_breaking_status` needs `path` for its commit-range git calls.
    entry.path = result.path
    entry.rev_before = result.rev_before
    entry.rev_after = result.rev_after
    -- Clear every field `infer_breaking_status` populates so a prior run's
    -- stale pending/delta/signal/reason never survives into this verdict.
    entry.breaking = nil
    entry.diff_url = nil
    -- vim.pack's report shows the version label on `Revision:` for a current
    -- plugin and on `Revision after:` for a pending one; mirror that.
    entry.current_version = result.status == "same" and result.version_label or nil
    entry.target_version = result.status == "update" and result.version_label or nil
    entry.pending_updates = nil
    entry.semver_delta = nil
    entry.commit_signal = nil
    entry.risk_reason = nil
    state.pack_report_cache.plugins[name] = entry
    counts[result.status] = (counts[result.status] or 0) + 1
    result.counted = result.status
  end

  ctx.refreshing[name] = nil

  -- Rebuild this one row from the updated cache and swap it into the visible
  -- table in place (line position is held stable during the refresh).
  local line_no = ctx.line_by_name and ctx.line_by_name[name]
  if line_no then
    local row = report.collect_dashboard_row(name)
    if row then
      ctx.row_by_line[line_no] = row
      for i, existing in ipairs(ctx.rows or {}) do
        if existing.name == name then
          ctx.rows[i] = row
          break
        end
      end
    end
  end
  view.render_row(ctx, name)
end

-- Refresh targets are explicit names or all visible rows. Exclude synthetic dev
-- rows: passing one to vim.pack.get(names) rejects the entire batch.
local function mark_targets(ctx, names)
  ctx.refreshing = {}
  local resolved = {}
  if names == nil then
    for _, row in ipairs(rows.visible(ctx)) do
      if not row.is_dev then
        ctx.refreshing[row.name] = true
        resolved[#resolved + 1] = row.name
      end
    end
  else
    for _, name in ipairs(names) do
      if type(name) == "string" and name ~= "" and not state.dev_plugin_paths_cache[name] then
        ctx.refreshing[name] = true
        resolved[#resolved + 1] = name
      end
    end
  end
  return resolved
end

-- Drop a set of plugins from the cache + visible table (used by the clean
-- op, whose rows disappear rather than flip to a new status).
local function remove_rows(ctx, names)
  for _, name in ipairs(names) do
    if type(state.pack_report_cache.plugins) == "table" then
      state.pack_report_cache.plugins[name] = nil
    end
    ctx.selected[name] = nil
    ctx.refreshing[name] = nil
  end
end

-- Refresh or mutate target rows, keeping their positions stable until completion.
-- spec fields:
--   names: nil means all visible rows; dev rows are excluded
--   label: action shown with the completed-row count
--   online: fetch before resolving status
--   apply: scheduled bulk mutation before status; raises abort the operation
--   remove_on_done: remove rows instead of resolving their status
--   before_apply(results): approve fetched updates before any checkout
--   apply_rows(names, results): blocking checkout; returns per-name status/error
--   apply_batch_size: maximum rows per checkout call (default 1)
--   on_finalize(counts): cache updates before final rendering
local function execute_row_op(ctx, spec)
  -- Set once the op has ended (finalized or aborted): late pipeline callbacks
  -- and drain steps then return without touching the dashboard.
  local finished = false

  -- Release everything this op claimed, so a raise never leaves the dashboard
  -- stuck busy (`online_check_running` true forever, spinner running).
  local function release()
    finished = true
    stop_spinner(ctx)
    ctx.refreshing = {}
    ctx.online_check_running = false
    ctx.online_check_progress = nil
  end

  -- Refresh the row set from cache, mark targets in-flight, and render once so
  -- every target row shows its spinner immediately. `target_names` is the
  -- concrete list the op resolved (visible rows when spec.names is nil) and is
  -- what the pipeline scans, so the in-flight set and the progress denominator
  -- match what is refreshed.
  local target_names, total, current_name
  local counts = { update = 0, same = 0, error = 0 }
  local ok_setup, err_setup = pcall(function()
    ctx.rows = report.collect_dashboard_rows()
    target_names = mark_targets(ctx, spec.names)
    total = vim.tbl_count(ctx.refreshing)
    ctx.online_check_progress = { total = total, label = spec.label or "Refreshing" }
    view.render(ctx)
    start_spinner(ctx)
    local current = rows.row_at_cursor(ctx)
    current_name = current and current.name or nil
  end)
  if not ok_setup then
    release()
    operation_done()
    error(err_setup, 0)
  end

  -- Runs an op-supplied hook; a raise there must not skip the rest of finalize.
  local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
      vim.notify("dash-paq: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  local function finalize()
    finished = true
    gitcmd.invalidate_tags()
    state.invalidate_version_flags()
    version.refresh_version_flags_async(function()
      release()
      guarded(function()
        if spec.on_finalize then
          guarded(spec.on_finalize, counts)
        end
        state.write_persisted_state()
        M.update_after_scan(ctx, current_name)
        if counts.error > 0 then
          vim.notify(
            string.format("%d plugin(s) failed to refresh; see the failed rows", counts.error),
            vim.log.levels.WARN
          )
        end
      end)
      operation_done()
    end)
  end

  -- The status phase resolves each target row independently. For removals we
  -- skip it: the rows just vanish at finalize.
  local function status_phase()
    if spec.remove_on_done then
      remove_rows(ctx, target_names)
      finalize()
      return
    end

    -- `spec.apply_rows` blocks on `vim.pack.update`, which pumps the event
    -- loop and can re-enter this callback for other rows before the current
    -- apply returns. Queue rows and drain them one batch at a time, yielding to
    -- the event loop between applies (`vim.defer_fn`, see APPLY_YIELD_MS above)
    -- instead of a back-to-back `while` loop, so a long queue never blocks in
    -- one event-loop turn. `draining` covers both "an apply is in flight" and
    -- "a step timer is pending": a re-entrant pipeline callback must only
    -- enqueue, never start a second apply/step while either holds. Finalize
    -- waits for pipeline-done, an empty queue, and no apply/step in flight.
    local batch_size = math.max(1, math.floor(tonumber(spec.apply_batch_size) or 1))
    local apply_queue = {}
    local draining = false
    local pipeline_done = false

    local function maybe_finalize()
      if pipeline_done and not draining and #apply_queue == 0 then
        finalize()
      end
    end

    -- `pcall` every per-row body: `apply_pipeline_result` must never be
    -- skipped, even if `apply_rows` raises instead of returning. Note:
    -- `apply_pipeline_result`/`view.render_*` already no-op against an invalid
    -- `ctx.bufnr` (dashboard closed mid-op, same case the spinner guards
    -- against) — closing it only skips redraws, never this chain, which must
    -- keep draining and reach `finalize` regardless, or `online_check_running`
    -- would stay stuck true forever.
    local function drain_step()
      if finished then
        return
      end
      if #apply_queue == 0 then
        draining = false
        maybe_finalize()
        return
      end
      local idle_ms = state.last_cursor_move and (vim.uv.hrtime() - state.last_cursor_move) / 1e6
      if idle_ms and idle_ms < CURSOR_IDLE_MS then
        vim.defer_fn(drain_step, math.ceil(CURSOR_IDLE_MS - idle_ms))
        return
      end
      local batch, names = {}, {}
      while #batch < batch_size and #apply_queue > 0 do
        local result = table.remove(apply_queue, 1)
        batch[#batch + 1] = result
        names[#names + 1] = result.name
      end
      local ok_call, outcomes = pcall(spec.apply_rows, names, batch)
      for _, result in ipairs(batch) do
        local ok_row, err_row = pcall(function()
          local outcome = ok_call and type(outcomes) == "table" and outcomes[result.name]
          if outcome and outcome.status == "same" then
            result.status = "same"
            result.rev_before = result.rev_after
          else
            result.status = "error"
            result.error = outcome and outcome.error or (not ok_call and tostring(outcomes)) or "checkout failed"
          end
          apply_pipeline_result(ctx, result, counts)
        end)
        if not ok_row then
          result.status = "error"
          result.error = tostring(err_row)
          pcall(apply_pipeline_result, ctx, result, counts)
        end
      end
      -- Always yield after an apply, even with nothing queued: a result that
      -- arrives in a later `vim.schedule` callback of this same event-loop pass
      -- only enqueues and is applied by the next step, after input/redraw ran,
      -- instead of starting another blocking apply back-to-back. The step that
      -- finds the queue empty settles `draining` and finalizes.
      vim.defer_fn(drain_step, APPLY_YIELD_MS)
    end

    local function drain_queue()
      if draining then
        return
      end
      draining = true
      drain_step()
    end

    report.run_refresh_pipeline(target_names, spec.online == true, function(result)
      if finished then
        return
      end
      -- Keep fetched rows pending until their checkout finishes.
      if spec.apply_rows and result.status == "update" then
        apply_queue[#apply_queue + 1] = result
        if not spec.before_apply then
          drain_queue()
        end
      else
        apply_pipeline_result(ctx, result, counts)
      end
      -- Finalize can run synchronously inside the drain above; the op is over then.
      if finished then
        return
      end
      view.render_header(ctx)
    end, function()
      if finished then
        return
      end
      pipeline_done = true
      if spec.before_apply and #apply_queue > 0 then
        local ok, approved = pcall(spec.before_apply, apply_queue)
        if not ok or not approved then
          for _, result in ipairs(apply_queue) do
            if not ok then
              result.status, result.error = "error", tostring(approved)
            end
            apply_pipeline_result(ctx, result, counts)
          end
          apply_queue = {}
        else
          drain_queue()
        end
      end
      maybe_finalize()
    end)
  end

  -- An op that failed before its pipeline could run: release the dashboard and
  -- show the error, leaving the pre-op rows visible.
  local function fail_op(err)
    release()
    vim.notify("Operation failed: " .. tostring(err), vim.log.levels.ERROR)
    pcall(function()
      ctx.rows = report.collect_dashboard_rows()
      view.render(ctx)
    end)
    operation_done()
  end

  -- Defer so the spinner render paints before any blocking bulk mutation runs.
  if spec.apply then
    vim.schedule(function()
      local ok, err = pcall(spec.apply)
      if not ok then
        fail_op(err)
        return
      end
      local ok_phase, err_phase = pcall(status_phase)
      if not ok_phase then
        fail_op(err_phase)
      end
    end)
  else
    local ok_phase, err_phase = pcall(status_phase)
    if not ok_phase then
      fail_op(err_phase)
    end
  end
end

function M.run_row_op(ctx, spec)
  if ctx.online_check_running then
    return
  end
  ctx.online_check_running = true
  local function run()
    execute_row_op(ctx, spec or {})
  end
  if operation_running then
    pending_operations[#pending_operations + 1] = run
  else
    operation_running = true
    run()
  end
end

-- No start/result toasts: the dashboard itself shows per-row spinners and the
-- header counters/stamps, so progress and outcome are already visible. Only
-- genuine failures still surface (via finalize's default error warn).
function M.refresh(ctx, online)
  M.run_row_op(ctx, {
    online = online,
    label = online and "Refreshing online" or "Refreshing offline",
    on_finalize = function()
      local cache = state.pack_report_cache
      cache.mode = online and "online" or "offline"
      cache.updated_at = os.time()
    end,
  })
end

function M.persist_ui_state(ctx)
  if not ctx.bufnr or not vim.api.nvim_buf_is_valid(ctx.bufnr) then
    return
  end
  state.dashboard_ui_cache.filter_mode =
    state.normalize_mode(ctx.filter_mode, { all = true, updates = true, issues = true }, "all")
  state.dashboard_ui_cache.sort_mode = state.normalize_mode(ctx.sort_mode, { status = true, name = true }, "status")
  state.dashboard_ui_cache.search_text = (type(ctx.search_text) == "string" and ctx.search_text ~= "")
      and ctx.search_text
    or nil
  state.write_persisted_state()
end

return M
