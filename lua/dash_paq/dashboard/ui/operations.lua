local analysis = require("dash_paq.dashboard.analysis")
local state = require("dash_paq.dashboard.state")
local policy = require("dash_paq.policy")
local refresh = require("dash_paq.dashboard.ui.refresh")
local dev = require("dash_paq.loader.dev")
local fs = require("dash_paq.fs")
local git = require("dash_paq.git")

local M = {}

local function checkout_rows(_, results)
  local changed, outcomes = {}, {}
  local names = {}
  for _, result in ipairs(results) do
    local head = git.run({ "-C", result.path, "rev-parse", "HEAD" }, { text = true }):wait()
    if head.code == 0 and vim.trim(head.stdout) == result.rev_after then
      outcomes[result.name] = { status = "same" }
    else
      names[#names + 1] = result.name
    end
  end
  if #names == 0 then
    return outcomes, 0
  end
  local event = vim.api.nvim_create_autocmd("PackChanged", {
    callback = function(ev)
      if ev.data and ev.data.kind == "update" then
        changed[ev.data.spec.name] = true
      end
    end,
  })
  local ok, err = pcall(vim.pack.update, names, { offline = true, force = true })
  vim.api.nvim_del_autocmd(event)
  local applied = 0
  for _, result in ipairs(results) do
    if not outcomes[result.name] then
      local head = git.run({ "-C", result.path, "rev-parse", "HEAD" }, { text = true }):wait()
      if changed[result.name] and head.code == 0 and vim.trim(head.stdout) == result.rev_after then
        outcomes[result.name] = { status = "same" }
        applied = applied + 1
      else
        outcomes[result.name] =
          { status = "error", error = not ok and tostring(err) or "Checkout failed; target revision was not applied" }
      end
    end
  end
  return outcomes, applied
end

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

  -- Fetch asynchronously, then apply local checkouts in bounded batches.
  -- vim.pack.update still blocks input during each checkout.
  local applied = 0
  refresh.run_row_op(ctx, {
    names = filtered,
    online = true,
    label = "Updating",
    apply_batch_size = state.dashboard_config.apply_batch_size,
    before_apply = function(results)
      local risky = {}
      if state.dashboard_config.skip_risk_confirm ~= true then
        for _, result in ipairs(results) do
          if analysis.infer_breaking_status(result) == true then
            risky[#risky + 1] = result.name
          end
        end
      end
      if
        #risky > 0
        and vim.fn.confirm(
            string.format(
              "%d plugin(s) flagged as breaking (%s).\nProceed with the update?",
              #risky,
              table.concat(risky, ", ")
            ),
            "&Yes\n&No",
            2
          )
          ~= 1
      then
        vim.notify("Update cancelled", vim.log.levels.INFO)
        return false
      end
      return true
    end,
    apply_rows = function(batch, results)
      local outcomes, count = checkout_rows(batch, results)
      applied = applied + count
      return outcomes
    end,
    on_finalize = function()
      if applied > 0 and state.version_policy_enabled then
        -- Policy work yields between plugins and skips an overlapping refresh.
        pcall(policy.refresh_version_policy_async)
      end
    end,
  })
end

function M.clean_orphan_rows(ctx, targets, scope_label)
  if #targets == 0 then
    vim.notify("No plugins outside the spec to delete", vim.log.levels.INFO)
    return
  end

  if state.dashboard_config.skip_clean_confirm ~= true then
    local preview = table.concat(targets, ", ")
    if #preview > 240 then
      preview = preview:sub(1, 237) .. "..."
    end
    local msg = string.format(
      "Delete %d plugin(s) not in spec (%s) from disk and the lockfile?\n  %s",
      #targets,
      scope_label,
      preview
    )
    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
      vim.notify("Deletion cancelled", vim.log.levels.INFO)
      return
    end
  end

  refresh.run_row_op(ctx, {
    names = targets,
    label = "Deleting",
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

  refresh.run_row_op(ctx, {
    names = targets,
    online = false,
    label = "Restoring versions",
    apply_rows = checkout_rows,
  })
end

-- Build the `L`-toggle option list for `name`: an "upstream" option (only
-- when the entry has a `src` to fall back to) plus every candidate checkout
-- dir for its dev base, each flagged `current` against `active` (the name's
-- entry in `dev_plugin_paths_cache`, or "upstream" when it has none).
local function dev_toggle_options(info, active)
  local options = {}
  local active_path = active ~= "upstream" and fs.real_path(active) or nil
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
function M.toggle_dev(row, hooks)
  hooks = hooks or {}
  local select_fn = hooks.select or vim.ui.select

  local name = row and row.name
  local info = name and state.dev_capable_cache[name]
  if not info then
    vim.notify((name or "<unknown>") .. ": no dev checkout configured", vim.log.levels.WARN)
    return
  end

  local active = state.dev_plugin_paths_cache[name] or "upstream"
  -- A saved switch is pending until restart. Use it for repeat toggles too.
  local saved = dev.load_choices()[name]
  if saved == "upstream" and info.has_src then
    active = saved
  elseif saved and saved ~= "upstream" then
    active = dev.matching_candidate_path(info.base, saved) or active
  end
  local options = dev_toggle_options(info, active)
  if #options < 2 then
    vim.notify(name .. ": no alternate dev checkout available", vim.log.levels.WARN)
    return
  end

  local function apply(option)
    dev.set_choice(
      name,
      option.kind == "upstream" and "upstream" or option.path,
      vim.tbl_extend("force", hooks, { from = active, dev_dir = active ~= "upstream" and active or nil })
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
    if row.status == "update" then
      vim.notify("No compare page; opening the repository instead", vim.log.levels.INFO)
    end
    vim.ui.open(row.repo_url)
    return
  end
  vim.notify("No compare page or repository for this plugin", vim.log.levels.WARN)
end

return M
