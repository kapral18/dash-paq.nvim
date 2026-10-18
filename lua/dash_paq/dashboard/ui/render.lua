local state = require("dash_paq.dashboard.state")
local fmt = require("dash_paq.dashboard.ui.format")
local rows = require("dash_paq.dashboard.ui.rows")

local M = {}

local dashboard_ns = vim.api.nvim_create_namespace("dash_paq.dashboard")

function M.ensure_highlights()
  local set_hl = vim.api.nvim_set_hl
  set_hl(0, "DashPaqTitle", { default = true, link = "Title" })
  set_hl(0, "DashPaqFiltered", { default = true, link = "WarningMsg" })
  set_hl(0, "DashPaqProgress", { default = true, link = "DiagnosticInfo" })
  set_hl(0, "DashPaqKey", { default = true, link = "Function" })
  set_hl(0, "DashPaqMeta", { default = true, link = "Comment" })
  set_hl(0, "DashPaqLabel", { default = true, link = "Comment" })
  set_hl(0, "DashPaqValue", { default = true, link = "Normal" })
  set_hl(0, "DashPaqBar", { default = true, link = "NonText" })
  set_hl(0, "DashPaqRule", { default = true, link = "NonText" })
  set_hl(0, "DashPaqHeader", { default = true, link = "Identifier" })
  set_hl(0, "DashPaqStatusUpdate", { default = true, link = "DiagnosticInfo" })
  set_hl(0, "DashPaqStatusSame", { default = true, link = "String" })
  set_hl(0, "DashPaqStatusError", { default = true, link = "DiagnosticError" })
  set_hl(0, "DashPaqStatusUnknown", { default = true, link = "Comment" })
  set_hl(0, "DashPaqStatusOrphan", { default = true, link = "DiagnosticWarn" })
  set_hl(0, "DashPaqStatusDrift", { default = true, link = "DiagnosticWarn" })
  set_hl(0, "DashPaqStatusRisky", { default = true, link = "DiagnosticWarn" })
  set_hl(0, "DashPaqStatusLocal", { default = true, link = "Comment" })
  set_hl(0, "DashPaqRiskBreak", { default = true, link = "DiagnosticWarn" })
  set_hl(0, "DashPaqRiskSafe", { default = true, link = "DiffAdd" })
  set_hl(0, "DashPaqRiskUnknown", { default = true, link = "Comment" })
  set_hl(0, "DashPaqLink", { default = true, link = "Underlined" })
  set_hl(0, "DashPaqSelected", { default = true, link = "Special" })
end

local function progress_segments(ctx)
  local progress = ctx.online_check_progress or {}
  local total = progress.total or 0
  local done = math.max(0, total - vim.tbl_count(ctx.refreshing or {}))
  return {
    {
      key = progress.label or "Refreshing",
      value = string.format("%d/%d", done, total),
      key_hl = "DashPaqProgress",
      value_hl = "DashPaqValue",
    },
  }
end

local function stats_segments(counts)
  local segments = { { text = "All:", hl = "DashPaqMeta" } }
  for _, status in ipairs({ "update", "same", "error", "unknown", "orphan", "drift", "risky", "local" }) do
    segments[#segments + 1] = {
      key = status,
      value = tostring(counts[status]),
      key_hl = "DashPaqLabel",
      value_hl = M.status_hl[status],
    }
  end
  segments[#segments + 1] = {
    key = "breaking signals",
    value = tostring(counts.breaking),
    key_hl = "DashPaqLabel",
    value_hl = "DashPaqRiskBreak",
  }
  return segments
end

local function join_cells(cells)
  local parts = {}
  local ranges = {}
  local byte_col = 0
  for _, cell in ipairs(cells) do
    if #parts > 0 then
      parts[#parts + 1] = " "
      byte_col = byte_col + 1
    end
    local start_col = byte_col
    parts[#parts + 1] = cell.text
    byte_col = byte_col + #cell.text
    if cell.key then
      ranges[cell.key] = { start_col = start_col, end_col = byte_col }
    end
  end
  return table.concat(parts), ranges
end

-- Column widths shared by the header and every data row so a single-row rewrite
-- aligns with the full-table render.
local NAME_COL, VERSION_COL, LINKS_COL = 34, 26, 12

-- The glyph shown in the status cell. While a row is mid-refresh
-- (`ctx.refreshing[name]`), it shows the animated spinner frame instead of the
-- cached status icon so each row advertises its own in-flight state.
local function status_cell_text(ctx, row)
  if ctx.refreshing and ctx.refreshing[row.name] then
    local frames = ctx.spinner_frames or { "|", "/", "-", "\\" }
    local frame = frames[((ctx.spinner_frame or 0) % #frames) + 1]
    return fmt.pad_cell(frame, 2)
  end
  return fmt.pad_cell(ctx.status_icon[row.status] or "?", 2)
end

-- Build the buffer line + cell byte ranges for a single data row. Used by both
-- the full-table builder and the per-row in-place updater.
local function build_row_line(ctx, row)
  return join_cells({
    { key = "sel", text = fmt.pad_cell(ctx.selected[row.name] and "[x]" or "[ ]", 3) },
    { key = "status", text = status_cell_text(ctx, row) },
    { key = "risk", text = fmt.pad_cell(fmt.risk_label(ctx, row), 2) },
    { text = fmt.pad_cell(row.name, NAME_COL) },
    { text = fmt.pad_cell(fmt.version_cell(row), VERSION_COL) },
    { text = fmt.pad_cell(fmt.links_cell(ctx, row), LINKS_COL) },
  })
end

-- Status -> highlight group, shared with the details popup.
local status_hl = {
  update = "DashPaqStatusUpdate",
  same = "DashPaqStatusSame",
  error = "DashPaqStatusError",
  unknown = "DashPaqStatusUnknown",
  orphan = "DashPaqStatusOrphan",
  drift = "DashPaqStatusDrift",
  risky = "DashPaqStatusRisky",
  ["local"] = "DashPaqStatusLocal",
}
M.status_hl = status_hl

-- Apply the selection/status/risk extmarks for a single data row at `line_no`
-- (1-based). Shared by the full-table and per-row render paths.
local function apply_row_highlights(ctx, line_no, row, ranges)
  ranges = ranges or {}
  if ctx.selected[row.name] and ranges.sel then
    pcall(vim.api.nvim_buf_set_extmark, ctx.bufnr, dashboard_ns, line_no - 1, ranges.sel.start_col, {
      hl_group = "DashPaqSelected",
      end_col = ranges.sel.end_col,
    })
  end
  if ranges.status then
    local group = (ctx.refreshing and ctx.refreshing[row.name]) and "DashPaqStatusUnknown"
      or (status_hl[row.status] or "DashPaqStatusUnknown")
    pcall(vim.api.nvim_buf_set_extmark, ctx.bufnr, dashboard_ns, line_no - 1, ranges.status.start_col, {
      hl_group = group,
      end_col = ranges.status.end_col,
    })
  end
  if row.status == "update" and not (ctx.refreshing and ctx.refreshing[row.name]) then
    local risk_group = row.breaking == true and "DashPaqRiskBreak"
      or (row.breaking == false and "DashPaqRiskSafe" or "DashPaqRiskUnknown")
    if ranges.risk then
      pcall(vim.api.nvim_buf_set_extmark, ctx.bufnr, dashboard_ns, line_no - 1, ranges.risk.start_col, {
        hl_group = risk_group,
        end_col = ranges.risk.end_col,
      })
    end
  end
end

-- Render one segment to its display text and the relative byte spans coloring
-- its parts. A segment is one of:
--   { text = "...", hl = "Group" }                       -- a plain item
--   { key = "mode", value = "online",                    -- a key:value item
--     key_hl = "G1", value_hl = "G2", sep = ":" }         -- (sep defaults ":")
-- Returns `text, spans` where spans are `{start_col,end_col,hl}` (0-based, byte)
-- relative to the start of this segment's text.
local function render_segment(seg)
  if seg.key ~= nil then
    local sep = seg.sep or ":"
    local key = tostring(seg.key)
    local value = tostring(seg.value)
    local text = key .. sep .. value
    local spans = {
      { start_col = 0, end_col = #key, hl = seg.key_hl },
    }
    local value_start = #key + #sep
    spans[#spans + 1] = { start_col = value_start, end_col = value_start + #value, hl = seg.value_hl }
    return text, spans
  end
  local text = seg.text or ""
  return text, { { start_col = 0, end_col = #text, hl = seg.hl } }
end

-- Lays out segments (see render_segment) into lines no wider than `width`,
-- joined by bar separators; wraps at a segment boundary so a `key:value` item
-- is never split mid-token. Oversized segments end with an ellipsis.
-- Returns lines and their highlight spans (0-based byte offsets).
local function layout_segments(segments, width, bar_hl, use_nerd_font)
  local bar = use_nerd_font and "│" or "|"
  local joiner = " " .. bar .. " "
  local out_lines = {}
  local out_spans = {}

  local cur_text = ""
  local cur_spans = {}

  local function flush()
    out_lines[#out_lines + 1] = cur_text
    out_spans[#out_spans + 1] = cur_spans
    cur_text = ""
    cur_spans = {}
  end

  local function add_spans_at(offset, spans)
    for _, s in ipairs(spans) do
      cur_spans[#cur_spans + 1] = { start_col = offset + s.start_col, end_col = offset + s.end_col, hl = s.hl }
    end
  end

  for _, seg in ipairs(segments) do
    local text, spans = render_segment(seg)
    text = fmt.truncate_display(text, width)
    if text ~= "" then
      if cur_text == "" then
        add_spans_at(0, spans)
        cur_text = text
      else
        local candidate = cur_text .. joiner .. text
        if vim.fn.strdisplaywidth(candidate) <= width then
          local bar_start = #cur_text + 1 -- one byte for the leading space
          cur_spans[#cur_spans + 1] = { start_col = bar_start, end_col = bar_start + #bar, hl = bar_hl }
          add_spans_at(#cur_text + #joiner, spans)
          cur_text = candidate
        else
          flush()
          add_spans_at(0, spans)
          cur_text = text
        end
      end
    end
  end
  if cur_text ~= "" or #out_lines == 0 then
    flush()
  end

  return { lines = out_lines, spans = out_spans }
end

local function active_filter_desc(ctx)
  local parts = {}
  if ctx.filter_mode ~= "all" then
    parts[#parts + 1] = "filter:" .. ctx.filter_mode
  end
  if type(ctx.search_text) == "string" and ctx.search_text ~= "" then
    parts[#parts + 1] = "search:'" .. ctx.search_text .. "'"
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, ", ")
end

local function help_segments(ctx)
  local function item(keys, action)
    return { key = keys, value = action, sep = " ", key_hl = "DashPaqKey", value_hl = "DashPaqMeta" }
  end
  return {
    item("r/R", "refresh offline/online"),
    item("u/U", "update selected/visible"),
    item("<Space>", "select"),
    item("/", "search"),
    item("f", "filter:" .. ctx.filter_mode),
    item("s", "sort:" .. ctx.sort_mode),
    item("K", "details"),
    item("?", "keys"),
    item("q", "close"),
  }
end

-- Header spans use byte offsets; widths use display cells, as do data rows.
local function build_header_lines(ctx)
  local visible_count = #rows.visible(ctx)
  local selected = rows.selected_count(ctx, false)
  local hidden_selected = selected - rows.selected_count(ctx, true)
  local win_width = (ctx.winid and vim.api.nvim_win_is_valid(ctx.winid)) and vim.api.nvim_win_get_width(ctx.winid)
    or vim.o.columns
  local width = math.max(1, win_width)
  local lines, line_spans = {}, {}

  local function push_raw(text, hl)
    lines[#lines + 1] = text
    line_spans[#lines] = { { start_col = 0, end_col = #text, hl = hl } }
  end

  local function push_section(segments)
    if #segments == 0 then
      return
    end
    local laid = layout_segments(segments, width, "DashPaqBar", ctx.use_nerd_font)
    vim.list_extend(lines, laid.lines)
    vim.list_extend(line_spans, laid.spans)
  end

  push_section({
    { text = string.format("%d of %d plugins", visible_count, #ctx.rows), hl = "DashPaqTitle" },
    {
      key = "selected",
      value = tostring(selected) .. (hidden_selected > 0 and string.format(" (%d hidden)", hidden_selected) or ""),
      key_hl = "DashPaqLabel",
      value_hl = "DashPaqValue",
    },
    {
      key = "checked " .. (state.pack_report_cache.mode or "unknown"),
      value = state.format_cache_stamp(state.pack_report_cache.updated_at),
      key_hl = "DashPaqLabel",
      value_hl = "DashPaqValue",
    },
  })

  local filter = active_filter_desc(ctx)
  if filter then
    push_section({
      { text = filter, hl = "DashPaqFiltered" },
      { text = "f changes filter; c clears search", hl = "DashPaqMeta" },
    })
  end
  -- Counts cover all plugins; the first line names the visible subset.
  push_section(stats_segments(rows.summary_counts(ctx)))
  if ctx.online_check_running then
    push_section(progress_segments(ctx))
  end
  push_section(help_segments(ctx))

  -- The table keeps fixed columns and can scroll horizontally.
  local rule = string.rep(ctx.use_nerd_font and "─" or "-", width)
  push_raw(rule, "DashPaqRule")
  push_raw(
    table.concat({
      fmt.pad_cell("SEL", 3),
      fmt.pad_cell("ST", 2),
      fmt.pad_cell("RK", 2),
      fmt.pad_cell("PLUGIN", NAME_COL),
      fmt.pad_cell("VERSION", VERSION_COL),
      fmt.pad_cell("LINKS", LINKS_COL),
    }, " "),
    "DashPaqHeader"
  )
  push_raw(rule, "DashPaqRule")
  return lines, line_spans
end

local function build_lines(ctx)
  local visible = rows.visible(ctx)
  local lines, header_spans = build_header_lines(ctx)
  ctx.header_spans = header_spans
  ctx.header_line_count = #lines

  ctx.row_by_line = {}
  ctx.row_ranges_by_line = {}
  ctx.line_by_name = {}
  ctx.first_data_line = #lines + 1
  for _, row in ipairs(visible) do
    local line, ranges = build_row_line(ctx, row)
    lines[#lines + 1] = line
    ctx.row_by_line[#lines] = row
    ctx.row_ranges_by_line[#lines] = ranges
    ctx.line_by_name[row.name] = #lines
  end
  if #visible == 0 then
    -- Distinguish "nothing installed" from "everything filtered out": when a
    -- filter is active, say so and point at the keys that reset it.
    if #(ctx.rows or {}) == 0 then
      lines[#lines + 1] = "(No plugins installed)"
    else
      lines[#lines + 1] = string.format(
        "(0 of %d shown — %s hides the rest; press c to clear search, f to cycle filter)",
        #(ctx.rows or {}),
        active_filter_desc(ctx) or "filter"
      )
    end
  end
  return lines
end

-- Highlight the header region by applying the per-line byte spans produced with
-- the header lines. Line-count-agnostic so it stays correct as sections wrap to
-- a variable number of lines, and segment-level so each key/value/bar carries
-- its own color. Spans are clamped to the line length defensively.
local function highlight_static_headers(bufnr, lines, line_spans)
  if type(line_spans) ~= "table" then
    return
  end
  for line_no, spans in ipairs(line_spans) do
    local line = lines[line_no]
    if type(line) == "string" and type(spans) == "table" then
      local maxcol = #line
      for _, span in ipairs(spans) do
        if span.hl and span.start_col and span.end_col then
          local s = math.max(0, math.min(span.start_col, maxcol))
          local e = math.max(s, math.min(span.end_col, maxcol))
          if e > s then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, dashboard_ns, line_no - 1, s, {
              hl_group = span.hl,
              end_col = e,
            })
          end
        end
      end
    end
  end
end

local function highlight_rows(ctx)
  local row_count = 0
  for _ in pairs(ctx.row_by_line) do
    row_count = row_count + 1
  end
  if ctx.fast_scroll_mode and row_count > 120 then
    return
  end

  for line_no, row in pairs(ctx.row_by_line) do
    apply_row_highlights(ctx, line_no, row, ctx.row_ranges_by_line and ctx.row_ranges_by_line[line_no])
  end
end

-- Rewrite one row's buffer line and extmarks in place, leaving other rows
-- untouched; no-op if the row isn't currently visible or its line is unknown.
-- Used by the refresh pipeline so each row's status flips independently
-- without a full-table redraw.
function M.render_row(ctx, name)
  if not (ctx.bufnr and vim.api.nvim_buf_is_valid(ctx.bufnr)) then
    return
  end
  local line_no = ctx.line_by_name and ctx.line_by_name[name]
  if not line_no then
    return
  end
  local row = ctx.row_by_line and ctx.row_by_line[line_no]
  if not row then
    return
  end

  M.ensure_highlights()
  local line, ranges = build_row_line(ctx, row)
  ctx.row_ranges_by_line[line_no] = ranges
  vim.bo[ctx.bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, ctx.bufnr, line_no - 1, line_no, false, { line })
  vim.bo[ctx.bufnr].modifiable = false
  pcall(vim.api.nvim_buf_clear_namespace, ctx.bufnr, dashboard_ns, line_no - 1, line_no)
  apply_row_highlights(ctx, line_no, row, ranges)
end

-- Rewrite only the header lines, to refresh the live progress counter during
-- an incremental refresh without redrawing data rows. The header is
-- variable-height (wrapped help + optional FILTERED banner): if the rebuilt
-- header's line count differs from the buffer's current header, fall back to
-- a full render so data rows aren't clipped or duplicated.
function M.render_header(ctx)
  if not (ctx.bufnr and vim.api.nvim_buf_is_valid(ctx.bufnr)) then
    return
  end
  local prev_count = ctx.header_line_count
  local header, header_spans = build_header_lines(ctx)
  if type(prev_count) ~= "number" or #header ~= prev_count then
    M.render(ctx)
    return
  end
  M.ensure_highlights()
  vim.bo[ctx.bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, ctx.bufnr, 0, prev_count, false, header)
  vim.bo[ctx.bufnr].modifiable = false
  pcall(vim.api.nvim_buf_clear_namespace, ctx.bufnr, dashboard_ns, 0, prev_count)
  ctx.header_spans = header_spans
  highlight_static_headers(ctx.bufnr, header, header_spans)
end

function M.render(ctx)
  if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
    return
  end
  M.ensure_highlights()
  local lines = build_lines(ctx)
  vim.bo[ctx.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(ctx.bufnr, 0, -1, false, lines)
  vim.bo[ctx.bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(ctx.bufnr, dashboard_ns, 0, -1)
  highlight_static_headers(ctx.bufnr, lines, ctx.header_spans)
  highlight_rows(ctx)
end

return M
