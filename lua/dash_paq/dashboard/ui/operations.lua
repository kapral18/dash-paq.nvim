local analysis = require("dash_paq.dashboard.analysis")
local report = require("dash_paq.dashboard.report")
local state = require("dash_paq.dashboard.state")
local policy = require("dash_paq.policy")
local view = require("dash_paq.dashboard.ui.view")
local refresh = require("dash_paq.dashboard.ui.refresh")
local dev = require("dash_paq.loader.dev")

local M = {}

function M.update_by_names(ctx, names, empty_msg, noop_msg)
  if #names == 0 then
    vim.notify(empty_msg or "No plugins selected", vim.log.levels.WARN)
    return
  end

  local status_by_name = {}
  for _, row in ipairs(ctx.rows) do
    status_by_name[row.name] = row.status
  end

  local filtered, seen = {}, {}
  for _, name in ipairs(names) do
    if type(name) == "string" and name ~= "" and not seen[name] and status_by_name[name] == "update" then
      seen[name] = true
      filtered[#filtered + 1] = name
    end
  end

  if #filtered == 0 then
    vim.notify(noop_msg or "Selected plugins are already up to date", vim.log.levels.INFO)
    return
  end

  if state.dashboard_config.skip_risk_confirm ~= true then
    local risky, selected_set = {}, {}
    for _, name in ipairs(filtered) do
      selected_set[name] = true
    end
    for _, row in ipairs(ctx.rows) do
      if selected_set[row.name] and row.breaking == true then
        risky[#risky + 1] = row.name
      end
    end
    if #risky > 0 then
      local msg = string.format(
        "%d plugin(s) flagged as risky (%s).\nProceed with force update? [y/N] ",
        #risky,
        table.concat(risky, ", ")
      )
      if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
        vim.notify("Update cancelled", vim.log.levels.INFO)
        return
      end
    end
  end

  -- Unified per-row experience with no UI freeze: the slow network fetch runs
  -- asynchronously per plugin via the pipeline (online = true), and the moment
  -- each plugin's remote is fetched it is checked out locally with a fast
  -- `offline = true, force = true` call (no network, no long block), then its
  -- row flips to up-to-date. This avoids the monolithic, blocking
  -- `vim.pack.update(filtered, { force = true })` that freezes the UI and
  -- spams the command line with fetch progress.
  local applied = 0
  refresh.run_row_op(ctx, {
    names = filtered,
    online = true,
    apply_batch_size = state.dashboard_config.apply_batch_size,
    apply_rows = function(names)
      local ok, err = pcall(vim.pack.update, names, { offline = true, force = true })
      if ok then
        applied = applied + #names
      end
      return ok, err
    end,
    on_finalize = function()
      if applied > 0 then
        state.pack_report_cache.last_applied_at = os.time()
        state.pack_report_cache.last_applied_count = applied
        if state.version_policy_enabled then
          -- Fire-and-forget: `refresh_version_policy_async` yields between
          -- plugins (policy.lua), so it must never block finalize/the final
          -- render. It already no-ops safely if a refresh (e.g. the startup
          -- one) is already in progress (`policy_refresh_in_progress`).
          pcall(policy.refresh_version_policy_async)
        end
      end
    end,
  })
end

function M.clean_orphan_rows(ctx, targets, scope_label)
  if #targets == 0 then
    vim.notify("No orphan plugins to clean", vim.log.levels.INFO)
    return
  end

  if state.dashboard_config.skip_clean_confirm ~= true then
    local preview = table.concat(targets, ", ")
    if #preview > 240 then
      preview = preview:sub(1, 237) .. "..."
    end
    local msg = string.format("Clean %d %s orphan plugin(s)?\n  %s\nContinue? [y/N] ", #targets, scope_label, preview)
    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
      vim.notify("Clean cancelled", vim.log.levels.INFO)
      return
    end
  end

  -- Unified per-row experience: orphan rows show a spinner during the delete,
  -- then drop out of the table when the op completes.
  refresh.run_row_op(ctx, {
    names = targets,
    remove_on_done = true,
    apply = function()
      vim.pack.del(targets)
    end,
  })
end

function M.heal_drift_rows(ctx, targets)
  if #targets == 0 then
    vim.notify("No drifted plugins to heal", vim.log.levels.INFO)
    return
  end

  -- Unified per-row experience: drifted rows show a spinner while they are
  -- re-checked out to their declared spec, then flip to their healed status.
  -- `force = true, offline = true` re-checkouts local refs directly (no
  -- confirmation tabpage). The drift/risky flags are re-derived afterwards
  -- since they, not the update/same status, decide the healed row state.
  refresh.run_row_op(ctx, {
    names = targets,
    online = false,
    apply = function()
      vim.pack.update(targets, { offline = true, force = true })
      state.version_flags_cache = {}
      state.version_flags_scanned = false
    end,
    -- No success toast (the rows flip in place); done_notify is kept only to
    -- re-derive drift/risky flags and refresh the healed rows after the op.
    done_notify = function()
      analysis.refresh_version_flags_async(function()
        for _, name in ipairs(targets) do
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
              view.render_row(ctx, name)
            end
          end
        end
      end)
    end,
  })
end

-- Build the `L`-toggle option list for `name`: an "upstream" option (only
-- when the entry has a `src` to fall back to) plus every candidate checkout
-- dir for its dev base, each flagged `current` against `active` (the name's
-- entry in `dev_plugin_paths_cache`, or "upstream" when it has none).
local function dev_toggle_options(info, active)
  local options = {}
  local active_path = active ~= "upstream" and dev.normalize_path(active) or nil
  if info.has_src then
    options[#options + 1] = { kind = "upstream", current = active == "upstream" }
  end
  for _, candidate in ipairs(dev.candidates_for(info.base)) do
    options[#options + 1] = {
      kind = "path",
      path = candidate.path,
      label = candidate.label,
      current = active_path == candidate.path,
    }
  end
  return options
end

local function dev_option_label(option)
  local label = option.kind == "upstream" and "upstream" or option.label
  if option.current then
    label = label .. "  (current)"
  end
  return label
end

-- The first non-current option (used for the 2-option "flip" case); falls
-- back to the first option if none is marked current (a stale `active`
-- value no longer among the candidates).
local function dev_other_option(options)
  for _, option in ipairs(options) do
    if not option.current then
      return option
    end
  end
  return options[1]
end

-- `L` on a dev-capable row: 2 options flip directly; more open
-- `vim.ui.select`. The choice is saved and a restart offered by
-- `dev.set_choice`. `hooks` (select/confirm/restart) let tests stub the
-- UI/restart calls.
function M.toggle_dev(ctx, row, hooks)
  hooks = hooks or {}
  local select_fn = hooks.select or vim.ui.select

  local name = row and row.name
  local info = name and state.dev_capable_cache[name]
  if not info then
    vim.notify((name or "<unknown>") .. ": no dev checkout configured", vim.log.levels.WARN)
    return
  end

  local active = state.dev_plugin_paths_cache[name] or "upstream"
  local options = dev_toggle_options(info, active)
  if #options < 2 then
    vim.notify(name .. ": no alternate dev checkout available", vim.log.levels.WARN)
    return
  end

  local function apply(option)
    local from = active == "upstream" and "upstream" or active
    dev.set_choice(
      name,
      option.kind == "upstream" and "upstream" or option.path,
      vim.tbl_extend("force", hooks, { from = from, dev_dir = active ~= "upstream" and active or nil })
    )
  end

  if #options == 2 then
    apply(dev_other_option(options))
    return
  end

  select_fn(options, {
    prompt = name .. ": choose dev checkout",
    format_item = dev_option_label,
  }, function(choice)
    if choice then
      apply(choice)
    end
  end)
end

function M.open_diff_or_repo_for_row(row)
  if not row then
    return
  end
  if row.diff_url then
    vim.ui.open(row.diff_url)
    return
  end
  if row.repo_url then
    vim.notify("No direct compare URL; opening repository instead", vim.log.levels.INFO)
    vim.ui.open(row.repo_url)
    return
  end
  vim.notify("No diff/repo URL for this plugin", vim.log.levels.WARN)
end

return M
