local state = require("dash_paq.dashboard.state")
local analysis = require("dash_paq.dashboard.analysis")
local report = require("dash_paq.dashboard.report")
local view = require("dash_paq.dashboard.ui.view")
local bindings = require("dash_paq.dashboard.ui.bindings")
local refresh = require("dash_paq.dashboard.ui.refresh")
local defaults = require("dash_paq.config").defaults.dashboard

local M = {}

-- Module-level singleton ref so repeated `:DashPaq` calls reuse the same
-- floating window instead of stacking instances. Cleared by the WinClosed autocmd.
local dashboard_winid = nil

local function create_dashboard_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = "dashpaq"
  return bufnr
end

local function open_popup_window(ctx)
  local cfg = state.dashboard_config
  local total_lines = vim.o.lines - vim.o.cmdheight
  local width_ratio = math.max(0.45, math.min(0.98, tonumber(cfg.width_ratio) or defaults.width_ratio))
  local height_ratio = math.max(0.45, math.min(0.98, tonumber(cfg.height_ratio) or defaults.height_ratio))
  local min_width = tonumber(cfg.min_width) or defaults.min_width
  local min_height = tonumber(cfg.min_height) or defaults.min_height
  local margin = math.max(2, tonumber(cfg.margin) or defaults.margin)

  local width =
    math.max(1, math.min(math.max(min_width, math.floor(vim.o.columns * width_ratio)), vim.o.columns - margin))
  local height =
    math.max(1, math.min(math.max(min_height, math.floor(total_lines * height_ratio)), total_lines - margin))
  local row = math.floor((total_lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  ctx.winid = vim.api.nvim_open_win(ctx.bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " dash-paq dashboard ",
    title_pos = "center",
    row = row,
    col = col,
    width = width,
    height = height,
  })

  vim.wo[ctx.winid].number = false
  vim.wo[ctx.winid].relativenumber = false
  vim.wo[ctx.winid].signcolumn = "no"
  vim.wo[ctx.winid].foldcolumn = "0"
  vim.wo[ctx.winid].wrap = false
  vim.wo[ctx.winid].cursorline = false
  vim.wo[ctx.winid].smoothscroll = false

  dashboard_winid = ctx.winid
  vim.api.nvim_create_autocmd("WinClosed", {
    -- clear = false: reuse the plugin augroup.
    group = vim.api.nvim_create_augroup("dash_paq", { clear = false }),
    once = true,
    pattern = tostring(ctx.winid),
    callback = function()
      if dashboard_winid == ctx.winid then
        dashboard_winid = nil
      end
    end,
  })
end

function M.open(force_scan)
  if dashboard_winid and vim.api.nvim_win_is_valid(dashboard_winid) then
    if force_scan then
      pcall(vim.api.nvim_win_close, dashboard_winid, true)
      dashboard_winid = nil
    else
      pcall(vim.api.nvim_set_current_win, dashboard_winid)
      return
    end
  end

  report.ensure_dashboard_cache()

  local ctx = view.new_context({
    bufnr = create_dashboard_buffer(),
    rows = report.collect_dashboard_rows(),
    selected = {},
    filter_mode = state.dashboard_ui_cache.filter_mode or "all",
    sort_mode = state.dashboard_ui_cache.sort_mode or "status",
    search_text = state.dashboard_ui_cache.search_text,
  })

  open_popup_window(ctx)
  bindings.attach(ctx)
  view.render(ctx)
  analysis.refresh_version_flags_async(function()
    -- Skip the standalone re-render while an online refresh is in flight; its
    -- finalize re-collects rows (with the now-populated flags) and re-renders.
    if ctx.online_check_running then
      return
    end
    ctx.rows = report.collect_dashboard_rows()
    view.render(ctx)
  end)
  -- Opening uses the same refresh path as R.
  if state.dashboard_config.refresh_on_open ~= false then
    refresh.refresh(ctx, true)
  end
end

return M
