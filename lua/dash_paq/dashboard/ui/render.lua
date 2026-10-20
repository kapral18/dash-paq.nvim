local state = require("dash_paq.dashboard.state")
local fmt = require("dash_paq.dashboard.ui.format")
local rows = require("dash_paq.dashboard.ui.rows")

local M = {}

local dashboard_ns = vim.api.nvim_create_namespace("dash_paq.dashboard")

function M.ensure_highlights()
  local set_hl = vim.api.nvim_set_hl
  set_hl(0, "DashPaqFiltered", { default = true, link = "WarningMsg" })
  set_hl(0, "DashPaqProgress", { default = true, link = "DiagnosticInfo" })
  set_hl(0, "DashPaqKey", { default = true, link = "Function" })
  set_hl(0, "DashPaqMeta", { default = true, link = "Comment" })
  set_hl(0, "DashPaqH1", { default = true, link = "IncSearch" })
  set_hl(0, "DashPaqH2", { default = true, bold = true })
  set_hl(0, "DashPaqButton", { default = true, link = "CursorLine" })
  set_hl(0, "DashPaqButtonActive", { default = true, link = "Visual" })
  set_hl(0, "DashPaqRule", { default = true, link = "NonText" })
  set_hl(0, "DashPaqHeader", { default = true, bold = true })
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
  set_hl(0, "DashPaqLink", { default = true, link = "Underlined" })
  set_hl(0, "DashPaqSelected", { default = true, link = "Special" })
end

-- Left margin before the header and every row, as lazy.nvim and mason.nvim
-- leave; the window adds the same on the right.
local PAD = "  "

local function join_cells(cells)
  local parts = { PAD }
  local ranges = {}
  local byte_col = #PAD
  for i, cell in ipairs(cells) do
    if i > 1 then
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
-- The status cell is two cells wide so a Nerd Font glyph drawn double-width
-- (`ambiwidth=double`, `setcellwidths`) still fits.
local STATUS_COL = 2
local NAME_COL, VERSION_COL, NOTE_COL = 31, 27, 17

-- The glyph shown in the status cell. While a row is mid-refresh
-- (`ctx.refreshing[name]`), it shows the animated spinner frame instead of the
-- cached status icon so each row advertises its own in-flight state.
local function status_cell_text(ctx, row)
  if ctx.refreshing and ctx.refreshing[row.name] then
    local frames = ctx.spinner_frames or { "|", "/", "-", "\\" }
    local frame = frames[((ctx.spinner_frame or 0) % #frames) + 1]
    return fmt.pad_cell(frame, STATUS_COL)
  end
  return fmt.pad_cell(ctx.icons[row.status] or "?", STATUS_COL)
end

-- Build the buffer line + cell byte ranges for a single data row. Used by both
-- the full-table builder and the per-row in-place updater.
local function build_row_line(ctx, row)
  return join_cells({
    { key = "sel", text = fmt.pad_cell(ctx.selected[row.name] and "[x]" or "[ ]", 3) },
    { key = "status", text = status_cell_text(ctx, row) },
    { text = fmt.pad_cell(row.name, NAME_COL) },
    { text = fmt.pad_cell(fmt.version_cell(row), VERSION_COL) },
    -- A refreshing row's cached note may be stale until its result lands.
    {
      key = "note",
      text = fmt.pad_cell((ctx.refreshing and ctx.refreshing[row.name]) and "" or fmt.note_cell(row), NOTE_COL),
    },
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

-- Apply the selection/status/note extmarks for a single data row at `line_no`
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
  if ranges.note then
    pcall(vim.api.nvim_buf_set_extmark, ctx.bufnr, dashboard_ns, line_no - 1, ranges.note.start_col, {
      hl_group = row.status == "update" and "DashPaqRiskBreak" or status_hl[row.status] or "DashPaqMeta",
      end_col = ranges.note.end_col,
    })
  end
end

local FILTER_LABELS = { all = "All", updates = "Updates", issues = "Issues", selected = "Selected" }

-- "the Updates filter and search 'x'"; nil when nothing narrows the rows.
-- With `max_width`, the search text is shortened inside its quotes to fit.
local function has_search(ctx)
  return type(ctx.search_text) == "string" and ctx.search_text ~= ""
end

local function active_filter_desc(ctx, max_width)
  local parts = {}
  if ctx.filter_mode ~= "all" then
    parts[#parts + 1] = "the " .. (FILTER_LABELS[ctx.filter_mode] or ctx.filter_mode) .. " filter"
  end
  if has_search(ctx) then
    local text = ctx.search_text
    if max_width then
      local fixed = table.concat(parts) .. (#parts > 0 and " and " or "") .. "search ''"
      text = fmt.truncate_display(text, max_width - vim.fn.strdisplaywidth(fixed))
    end
    parts[#parts + 1] = "search '" .. text .. "'"
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " and ")
end

local TABLE_WIDTH = 3 + STATUS_COL + NAME_COL + VERSION_COL + NOTE_COL + 4
-- The dashboard window is sized to the table plus both margins.
M.CONTENT_WIDTH = TABLE_WIDTH + 2 * #PAD

-- One line from `{ text, hl }` chunks after the left margin, cut to the
-- table's width. Returns the line and its byte spans.
local function chunks_line(chunks)
  local text, spans = PAD, {}
  for _, chunk in ipairs(chunks) do
    if chunk[2] then
      spans[#spans + 1] = { start_col = #text, end_col = #text + #chunk[1], hl = chunk[2] }
    end
    text = text .. chunk[1]
  end
  if vim.fn.strdisplaywidth(text) > #PAD + TABLE_WIDTH then
    text = fmt.truncate_display(text, #PAD + TABLE_WIDTH)
    for _, span in ipairs(spans) do
      span.end_col = math.min(span.end_col, #text)
    end
  end
  return text, spans
end

local function progress_counts(ctx)
  local progress = ctx.online_check_progress or {}
  local total = progress.total or 0
  return math.max(0, total - vim.tbl_count(ctx.refreshing or {})), total, progress.label or "Refreshing"
end

-- The title and the filters as pills, the active filter highlighted, with the
-- help key flush right.
local function tabs_line(ctx)
  local chunks = { { " dash-paq ", "DashPaqH1" } }
  for _, mode in ipairs(fmt.filter_modes) do
    chunks[#chunks + 1] = { " " }
    chunks[#chunks + 1] = {
      " " .. (FILTER_LABELS[mode] or mode) .. " ",
      mode == ctx.filter_mode and "DashPaqButtonActive" or "DashPaqButton",
    }
  end
  chunks[#chunks + 1] = { " " }
  chunks[#chunks + 1] = { "(f)", "DashPaqKey" }
  local used = 0
  for _, chunk in ipairs(chunks) do
    used = used + vim.fn.strdisplaywidth(chunk[1])
  end
  local help = "press ? for help"
  chunks[#chunks + 1] = { string.rep(" ", math.max(1, TABLE_WIDTH - used - #help)) .. "press ", "DashPaqMeta" }
  chunks[#chunks + 1] = { "?", "DashPaqKey" }
  chunks[#chunks + 1] = { " for help", "DashPaqMeta" }
  return chunks_line(chunks)
end

-- The rule glyph and how many of it span the table; `─` is ambiguous-width,
-- so it draws two cells with `ambiwidth=double`.
local function rule_glyph(ctx)
  local glyph = ctx.use_nerd_font and "─" or "-"
  return glyph, math.floor(TABLE_WIDTH / math.max(1, vim.fn.strdisplaywidth(glyph)))
end

-- A bar across the table while an operation runs; blank otherwise, so the
-- header keeps its height.
local function progress_line(ctx)
  if not ctx.online_check_running then
    return "", {}
  end
  local done, total = progress_counts(ctx)
  local todo, span = rule_glyph(ctx)
  local filled = total > 0 and math.floor(done / total * span + 0.5) or 0
  -- ASCII fills with `=` so progress reads without color.
  return chunks_line({
    { (ctx.use_nerd_font and todo or "="):rep(filled), "DashPaqProgress" },
    { todo:rep(span - filled), "DashPaqRule" },
  })
end

-- Attention first; `breaking` qualifies the update count right before it.
local SUMMARY_ORDER = { "update", "breaking", "error", "drift", "risky", "orphan", "unknown", "same", "local" }

-- Plugin total (or task progress) and each non-zero status count with the
-- glyph the rows use. Counts cover all plugins, filtered or not.
local function summary_line(ctx)
  local chunks
  if ctx.online_check_running then
    local done, total, label = progress_counts(ctx)
    chunks = { { label .. ": ", "DashPaqH2" }, { string.format("%d/%d", done, total), "DashPaqMeta" } }
  elseif active_filter_desc(ctx) then
    chunks = {
      { "Showing: ", "DashPaqH2" },
      { string.format("%d of %d plugins", #rows.visible(ctx), #ctx.rows), "DashPaqFiltered" },
    }
  else
    chunks = {
      { "Total: ", "DashPaqH2" },
      { string.format("%d %s", #ctx.rows, #ctx.rows == 1 and "plugin" or "plugins"), "DashPaqMeta" },
    }
  end
  local counts = rows.summary_counts(ctx)
  local present = {}
  for _, status in ipairs(SUMMARY_ORDER) do
    if counts[status] > 0 then
      present[#present + 1] = status
    end
  end
  -- Icon and count for each status, then words left to right until one does
  -- not fit, so a later count never keeps words an earlier one lost; a count
  -- left without words is named in the help popup. Counts that do not fit
  -- with wide gaps get narrower ones.
  local function word(status)
    local label = fmt.status_labels[status]
    return " " .. (counts[status] == 1 and label[1] or label[2])
  end
  local function icon_of(status)
    return status == "breaking" and ctx.icons.risk_break or ctx.icons[status]
  end
  local function counts_width(gap)
    local width = 0
    for _, status in ipairs(present) do
      width = width + vim.fn.strdisplaywidth(gap .. icon_of(status) .. " " .. counts[status])
    end
    return width
  end
  local budget = TABLE_WIDTH
  for _, chunk in ipairs(chunks) do
    budget = budget - vim.fn.strdisplaywidth(chunk[1])
  end
  local gap = counts_width("   ") <= budget and "   " or "  "
  budget = budget - counts_width(gap)
  local worded = {}
  for _, status in ipairs(present) do
    local cost = vim.fn.strdisplaywidth(word(status))
    if cost > budget then
      break
    end
    worded[status] = true
    budget = budget - cost
  end
  for _, status in ipairs(present) do
    local breaking = status == "breaking"
    chunks[#chunks + 1] = { gap }
    chunks[#chunks + 1] = { icon_of(status), breaking and "DashPaqRiskBreak" or status_hl[status] }
    chunks[#chunks + 1] = { " " .. counts[status] .. (worded[status] and word(status) or ""), "DashPaqMeta" }
  end
  return chunks_line(chunks)
end

-- Check time, sort, search, and selection, dimmed. A long search
-- is shortened so the line fits the table's width.
local function meta_line(ctx)
  local cache = state.pack_report_cache
  local parts = {}
  if cache.mode and cache.updated_at then
    parts[#parts + 1] = { { "checked " .. cache.mode .. " " .. state.format_cache_stamp(cache.updated_at) } }
  else
    parts[#parts + 1] = { { "not checked yet" } }
  end
  parts[#parts + 1] = { { "sorted by " .. ctx.sort_mode } }
  local search_part
  if has_search(ctx) then
    search_part = { { "search " }, { "", "DashPaqFiltered" } }
    parts[#parts + 1] = search_part
  end
  local selected = rows.selected_count(ctx, false)
  if selected > 0 then
    local hidden = selected - rows.selected_count(ctx, true)
    parts[#parts + 1] =
      { { string.format("%d selected", selected) .. (hidden > 0 and string.format(" (%d hidden)", hidden) or "") } }
  end

  local sep = " · "
  if search_part then
    local used = vim.fn.strdisplaywidth(sep) * (#parts - 1) + vim.fn.strdisplaywidth("''")
    for _, part in ipairs(parts) do
      for _, chunk in ipairs(part) do
        used = used + vim.fn.strdisplaywidth(chunk[1])
      end
    end
    search_part[2][1] = "'" .. fmt.truncate_display(ctx.search_text, math.max(1, TABLE_WIDTH - used)) .. "'"
  end

  local chunks = {}
  for i, part in ipairs(parts) do
    if i > 1 then
      chunks[#chunks + 1] = { sep, "DashPaqMeta" }
    end
    for _, chunk in ipairs(part) do
      chunks[#chunks + 1] = { chunk[1], chunk[2] or "DashPaqMeta" }
    end
  end
  return chunks_line(chunks)
end

-- Fixed height, laid out like lazy.nvim and mason.nvim: a blank line, title and
-- filter pills, a progress bar (blank when idle), the summary, the dimmed
-- meta line, a blank line, then the column titles and their rule. Spans use
-- byte offsets; widths use display cells, as do data rows.
local function build_header_lines(ctx)
  local lines, line_spans = {}, {}

  local function push(text, spans)
    lines[#lines + 1] = text
    line_spans[#lines] = spans
  end

  push("", {})
  push(tabs_line(ctx))
  push(progress_line(ctx))
  push(summary_line(ctx))
  push(meta_line(ctx))
  push("", {})
  -- Plain-word column titles; the checkbox and icon columns need none.
  local columns = join_cells({
    { text = fmt.pad_cell("", 3) },
    { text = fmt.pad_cell("", STATUS_COL) },
    { text = fmt.pad_cell("Plugin", NAME_COL) },
    { text = fmt.pad_cell("Version", VERSION_COL) },
    { text = fmt.pad_cell("Note", NOTE_COL) },
  })
  push(columns, { { start_col = #PAD, end_col = #columns, hl = "DashPaqHeader" } })
  local glyph, span = rule_glyph(ctx)
  local rule = PAD .. glyph:rep(span)
  push(rule, { { start_col = #PAD, end_col = #rule, hl = "DashPaqRule" } })
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
      lines[#lines + 1] = PAD .. "(No plugins installed)"
    else
      -- Two lines, so both fit the window at the table's width.
      local prefix = string.format("(0 of %d shown: ", #(ctx.rows or {}))
      local suffix = (has_search(ctx) and ctx.filter_mode ~= "all" and " hide" or " hides") .. " the rest)"
      local desc = active_filter_desc(ctx, TABLE_WIDTH - vim.fn.strdisplaywidth(prefix .. suffix)) or "the filter"
      lines[#lines + 1] = PAD .. prefix .. desc .. suffix
      local hints = {}
      if has_search(ctx) then
        hints[#hints + 1] = "c clears the search"
      end
      if ctx.filter_mode ~= "all" then
        hints[#hints + 1] = "f cycles the filter"
      end
      lines[#lines + 1] = PAD .. table.concat(hints, ", ")
    end
  end
  return lines
end

-- Highlight the header region by applying the per-line byte spans built with
-- the header lines. Spans are clamped to the line length defensively.
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
-- an incremental refresh without redrawing data rows. The header has a fixed
-- height; if a rebuilt header's line count ever differs from the buffer's,
-- fall back to a full render so data rows aren't clipped or duplicated.
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
