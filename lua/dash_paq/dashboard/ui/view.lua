local state = require("dash_paq.dashboard.state")
local fmt = require("dash_paq.dashboard.ui.format")

local M = {}

function M.new_context(opts)
  local cfg = state.dashboard_config
  local use_nerd_font = cfg.ascii ~= true
  local icons = fmt.icons(use_nerd_font)
  return vim.tbl_extend("force", opts or {}, {
    use_nerd_font = use_nerd_font,
    fast_scroll_mode = cfg.fast_scroll ~= false,
    icons = icons,
    row_by_line = {},
    line_by_name = {},
    first_data_line = 1,
    online_check_running = false,
    online_check_progress = nil,
    refreshing = {},
    spinner_frame = 0,
    spinner_frames = fmt.spinner_frames(use_nerd_font),
    details_winid = nil,
    details_bufnr = nil,
  })
end

return M
