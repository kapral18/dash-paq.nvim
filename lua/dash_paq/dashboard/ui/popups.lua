local state = require("dash_paq.dashboard.state")
local defaults = require("dash_paq.config").defaults.dashboard
local analysis = require("dash_paq.dashboard.analysis")
local render = require("dash_paq.dashboard.ui.render")
local fmt = require("dash_paq.dashboard.ui.format")

local M = {}

local details_ns = vim.api.nvim_create_namespace("dash_paq.dashboard.details")

-- Same left margin as the dashboard.
local PAD = "  "

-- Collects popup lines from `{ text, hl }` chunks, each non-empty line after
-- the margin, with the byte-range highlights to stamp once the buffer is set.
local function new_builder()
  local b = { lines = {}, marks = {} }
  function b.line(chunks)
    local text = #chunks > 0 and PAD or ""
    for _, chunk in ipairs(chunks) do
      if chunk[2] then
        b.marks[#b.marks + 1] = { #b.lines, #text, #text + #chunk[1], chunk[2], 150 }
      end
      text = text .. chunk[1]
    end
    b.lines[#b.lines + 1] = text
    return #b.lines
  end
  function b.blank()
    return b.line({})
  end
  -- Highlight a whole line (1-based) over the per-chunk colors.
  function b.whole(line_no, hl, priority)
    b.marks[#b.marks + 1] = { line_no - 1, 0, #b.lines[line_no], hl, priority or 150 }
  end
  return b
end

local function apply_marks(bufnr, b)
  for _, m in ipairs(b.marks) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, details_ns, m[1], m[2], {
      end_col = m[3],
      hl_group = m[4],
      priority = m[5],
    })
  end
end

-- `Label value` rows with the labels dimmed and padded to one column.
local function add_props(b, props)
  local width = 0
  for _, prop in ipairs(props) do
    width = math.max(width, #prop[1])
  end
  -- Wrapped values continue under the value column.
  b.wrap_shift = width + 2
  for _, prop in ipairs(props) do
    b.line({ { prop[1] .. string.rep(" ", width - #prop[1] + 2), "DashPaqMeta" }, { prop[2], prop[3] } })
  end
end

-- `k1 desc1 · k2 desc2`, dimmed with the keys accented.
local function add_key_hints(b, hints)
  local chunks = {}
  for i, hint in ipairs(hints) do
    if i > 1 then
      chunks[#chunks + 1] = { " · ", "DashPaqMeta" }
    end
    chunks[#chunks + 1] = { hint[1], "DashPaqKey" }
    chunks[#chunks + 1] = { " " .. hint[2], "DashPaqMeta" }
  end
  b.line(chunks)
end

-- A centered, wrapping float as wide as the dashboard window and as tall as
-- its wrapped text, so long URLs or subjects never push the last lines out of
-- view.
local function open_float(bufnr, wrap_shift)
  local editor_w = vim.o.columns
  local editor_h = vim.o.lines - vim.o.cmdheight
  local margin = math.max(2, tonumber((state.dashboard_config or {}).margin) or defaults.margin)
  local width = math.max(1, math.min(render.CONTENT_WIDTH, editor_w - margin))
  local config = {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    row = 0,
    col = math.floor((editor_w - width) / 2),
    width = width,
    height = 1,
  }
  local win = vim.api.nvim_open_win(bufnr, true, config)
  vim.wo[win].wrap = true
  vim.wo[win].breakindent = true
  vim.wo[win].breakindentopt = "shift:" .. (wrap_shift or 0)
  config.height = math.max(1, math.min(vim.api.nvim_win_text_height(win, {}).all, editor_h - 4))
  config.row = math.floor((editor_h - config.height) / 2)
  vim.api.nvim_win_set_config(win, config)
  return win
end

-- Extract the leading short hash from a `vim.pack` pending line, e.g.
-- "> f3af041ea9f8 │ chore: bump" -> "f3af041ea9f8", after the popup's
-- indentation. Returns nil for lines without a hash (placeholders, blanks).
local function pending_line_hash(line)
  return line:match("^%s*>%s*(%x+)") or line:match("^%s*(%x%x%x%x%x%x%x+)%s")
end

function M.close_details(ctx)
  if ctx.details_winid and vim.api.nvim_win_is_valid(ctx.details_winid) then
    pcall(vim.api.nvim_win_close, ctx.details_winid, true)
  end
  if ctx.details_bufnr and vim.api.nvim_buf_is_valid(ctx.details_bufnr) then
    pcall(vim.api.nvim_buf_delete, ctx.details_bufnr, { force = true })
  end
  ctx.details_winid = nil
  ctx.details_bufnr = nil
end

function M.open_details(ctx, row)
  if not row then
    return
  end
  M.close_details(ctx)
  local pending = row.pending_updates
  local has_pending = type(pending) == "string" and pending ~= ""

  local status_value_hl = render.status_hl[row.status] or "DashPaqStatusUnknown"
  local risk_value_hl = (row.status == "update")
      and (row.breaking == true and "DashPaqRiskBreak" or (row.breaking == false and "DashPaqRiskSafe" or "DashPaqStatusUnknown"))
    or nil
  local current = row.current_version or analysis.short_rev(row.rev_before) or analysis.short_rev(row.rev) or "-"
  local target = row.target_version or analysis.short_rev(row.rev_after)

  local b = new_builder()
  b.blank()
  b.line({
    { " " .. row.name .. " ", "DashPaqH1" },
    { "  " },
    { ctx.icons[row.status] or "?", status_value_hl },
    { " " .. (fmt.status_labels[row.status] or { row.status })[1], status_value_hl },
  })
  b.blank()
  add_props(b, {
    {
      "Risk",
      row.status ~= "update" and "not assessed"
        or (
          row.breaking == true and "possibly breaking"
          or (row.breaking == false and "no breaking signal detected" or "unknown")
        ),
      risk_value_hl,
    },
    { "Reason", row.risk_reason or "-" },
    { "Semver", row.semver_delta or "n/a" },
    { "Signals", row.commit_signal or "none" },
    { "Version", current .. (target and target ~= current and (" -> " .. target) or "") },
    { "Source", row.source or "-" },
    { "Repo", row.repo_url or "-", row.repo_url and "DashPaqLink" or nil },
    { "Compare", row.diff_url or "-", row.diff_url and "DashPaqLink" or nil },
  })

  -- Highlight exactly the pending commits whose full message (subject or body,
  -- any case) carries a breaking marker. The pending list shows subjects only,
  -- but breaking markers often live in the body, so we classify per commit hash
  -- rather than by the visible subject text. `o`/`O` open the commit/diff for the
  -- full detail.
  local p_cache = state.pack_report_cache.plugins[row.name]
  local p_path = p_cache and p_cache.path
  local breaking_hashes = {}
  if row.status == "update" and p_path and row.rev_before and row.rev_after then
    breaking_hashes = analysis.breaking_commit_hashes(p_path, row.rev_before, row.rev_after)
  end

  b.blank()
  -- For error rows the "pending" body holds the error text; label the section
  -- accordingly and color the body as an error so failures stand out.
  local is_error = row.status == "error"
  local body = has_pending and vim.split(pending, "\n", { trimempty = false }) or {}
  if is_error then
    b.line({ { "Error", "DashPaqStatusError" } })
  else
    local commits = 0
    for _, line in ipairs(body) do
      if pending_line_hash(line) then
        commits = commits + 1
      end
    end
    b.line({ { "Pending updates", "DashPaqH2" }, { commits > 0 and (" (" .. commits .. ")") or "", "DashPaqMeta" } })
  end
  if not has_pending then
    b.line({ { "  none available", "DashPaqMeta" } })
  end
  for _, line in ipairs(body) do
    local line_no = b.line({ { "  " .. line } })
    if is_error then
      b.whole(line_no, "DashPaqStatusError")
    else
      local hash = pending_line_hash(line)
      if hash and breaking_hashes[hash] then
        -- Above the hash accent so the whole commit reads as breaking.
        b.whole(line_no, "DashPaqRiskBreak", 200)
      elseif hash then
        local hstart = b.lines[line_no]:find(hash, 1, true)
        b.marks[#b.marks + 1] = { line_no - 1, hstart - 1, hstart - 1 + #hash, "DashPaqStatusUpdate", 160 }
      end
    end
  end

  b.blank()
  -- `o` and `O` mean what they mean in the dashboard, plus the commit under
  -- the cursor.
  add_key_hints(b, {
    { "q", "close" },
    { "o", "open commit, else compare page or repo" },
    { "O", "open repository" },
    { "r", "refresh" },
  })
  local lines = b.lines

  ctx.details_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[ctx.details_bufnr].buftype = "nofile"
  vim.bo[ctx.details_bufnr].bufhidden = "wipe"
  vim.bo[ctx.details_bufnr].buflisted = false
  vim.bo[ctx.details_bufnr].swapfile = false
  -- Plain buffer (not markdown): the body is `Label value` log text, so markdown
  -- syntax would mis-color commit subjects containing `*`/`#`/`_`. Our extmarks
  -- supply all the structure coloring instead.
  vim.bo[ctx.details_bufnr].filetype = "dashpaq-details"
  vim.api.nvim_buf_set_lines(ctx.details_bufnr, 0, -1, false, lines)
  vim.bo[ctx.details_bufnr].modifiable = false
  render.ensure_highlights()
  apply_marks(ctx.details_bufnr, b)

  ctx.details_winid = open_float(ctx.details_bufnr, b.wrap_shift)

  vim.keymap.set("n", "q", function()
    M.close_details(ctx)
  end, { buffer = ctx.details_bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    M.close_details(ctx)
  end, { buffer = ctx.details_bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "o", function()
    local cursor = vim.api.nvim_win_get_cursor(ctx.details_winid)
    local current = lines[cursor[1]] or ""
    local hash = pending_line_hash(current)
    if not hash then
      require("dash_paq.dashboard.ui.operations").open_diff_or_repo_for_row(row)
      return
    end
    local commit_url = analysis.repo_to_commit_url(row.repo_url, hash)
    if commit_url then
      vim.ui.open(commit_url)
    else
      vim.notify("No commit page for this plugin", vim.log.levels.WARN)
    end
  end, { buffer = ctx.details_bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "O", function()
    if row.repo_url then
      vim.ui.open(row.repo_url)
    else
      vim.notify("No repository for this plugin", vim.log.levels.WARN)
    end
  end, { buffer = ctx.details_bufnr, nowait = true, silent = true })
  -- As in the dashboard: the refresh redraws the rows this popup describes.
  vim.keymap.set("n", "r", function()
    M.close_details(ctx)
    require("dash_paq.dashboard.ui.refresh").refresh(ctx, false)
  end, { buffer = ctx.details_bufnr, nowait = true, silent = true })
end

-- What each row icon means.
local STATUS_LEGEND = {
  { "update", "update available" },
  { "error", "the check or update failed" },
  { "drift", "checkout differs from the spec's version" },
  { "risky", 'version = "*" would pick a non-release tag' },
  { "orphan", "installed but no longer in your spec" },
  { "unknown", "not checked yet" },
  { "same", "up to date" },
  { "local", "loaded from a local dev checkout" },
}

-- Help keys by section: `{ keys, description }`.
local HELP_SECTIONS = {
  {
    "View",
    {
      { "q <Esc>", "close the dashboard" },
      { "R", "refresh online (fetches remotes)" },
      { "r", "offline status (no fetch; may miss remote updates)" },
      { "f", "cycle filter: all, updates, issues, selected" },
      { "s", "cycle sort: status, name" },
      { "/", "search" },
      { "c", "clear the search" },
    },
  },
  {
    "Selection",
    {
      { "<Space> x", "toggle the row (also in visual mode)" },
      { "a", "toggle all visible rows" },
      { "A", "clear the selection" },
    },
  },
  {
    "Updates",
    {
      { "<CR>", "update the plugin at the cursor" },
      { "u", "update selected pending plugins (or the cursor row)" },
      { "U", "update every visible pending plugin" },
      { "C", "delete plugins not in spec (selected, else all)" },
      { "V", "heal drift: re-checkout to the spec version (offline)" },
    },
  },
  {
    "Plugin",
    {
      { "K", "open details" },
      { "o", "open the compare page of a pending update, else the repository" },
      { "O", "open the repository" },
      { "L", "toggle the local dev checkout (offers a restart)" },
      { "T", "open the load trace" },
    },
  },
}

function M.open_help()
  local b = new_builder()
  b.blank()
  b.line({ { " dash-paq ", "DashPaqH1" }, { " " }, { " Help ", "DashPaqButtonActive" } })
  local key_width = 0
  for _, section in ipairs(HELP_SECTIONS) do
    for _, key in ipairs(section[2]) do
      key_width = math.max(key_width, vim.fn.strdisplaywidth(key[1]))
    end
  end
  for _, section in ipairs(HELP_SECTIONS) do
    b.blank()
    b.line({ { section[1], "DashPaqH2" } })
    for _, key in ipairs(section[2]) do
      b.line({
        { "- ", "DashPaqMeta" },
        { key[1] .. string.rep(" ", key_width - vim.fn.strdisplaywidth(key[1]) + 2), "DashPaqKey" },
        { key[2] },
      })
    end
  end
  b.blank()
  b.line({ { "Status icons", "DashPaqH2" } })
  local icons = fmt.icons(state.dashboard_config.ascii ~= true)
  for _, legend in ipairs(STATUS_LEGEND) do
    b.line({
      { "- ", "DashPaqMeta" },
      -- Two cells, so descriptions align when glyphs draw double-width.
      { fmt.pad_cell(icons[legend[1]], 2), render.status_hl[legend[1]] },
      { "  " .. legend[2] },
    })
  end
  b.line({
    { "- ", "DashPaqMeta" },
    { fmt.pad_cell(icons.risk_break, 2), "DashPaqRiskBreak" },
    { "  possibly breaking" },
  })
  b.line({ { "Breaking signals come from versions and commit messages; they do not prove a break.", "DashPaqMeta" } })
  b.blank()
  add_key_hints(b, { { "q", "close" } })

  local hbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[hbuf].buftype = "nofile"
  vim.bo[hbuf].bufhidden = "wipe"
  vim.bo[hbuf].swapfile = false
  vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, b.lines)
  vim.bo[hbuf].modifiable = false
  render.ensure_highlights()
  apply_marks(hbuf, b)

  local hwin = open_float(hbuf)
  local close = function()
    if hwin and vim.api.nvim_win_is_valid(hwin) then
      vim.api.nvim_win_close(hwin, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = hbuf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = hbuf, nowait = true, silent = true })
end

return M
