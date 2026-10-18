local state = require("dash_paq.dashboard.state")
local analysis = require("dash_paq.dashboard.analysis")
local render = require("dash_paq.dashboard.ui.render")

local M = {}

local details_ns = vim.api.nvim_create_namespace("dash_paq.dashboard.details")

-- Color a `Label: value` line: the label up to and including the colon gets the
-- header group, and the value (if a group is given) gets `value_hl`.
local function hl_field(bufnr, line_no, line, value_hl)
  local colon = line:find(":")
  if not colon then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, details_ns, line_no - 1, 0, {
    end_col = colon,
    hl_group = "DashPaqHeader",
    priority = 150,
  })
  if value_hl then
    -- Skip the spaces between the colon and the value so only the value colors.
    local vstart = line:find("%S", colon + 1)
    if vstart and vstart <= #line then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, details_ns, line_no - 1, vstart - 1, {
        end_col = #line,
        hl_group = value_hl,
        priority = 160,
      })
    end
  end
end

local function hl_line(bufnr, line_no, line, group)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, details_ns, line_no - 1, 0, {
    end_col = #line,
    hl_group = group,
    priority = 150,
  })
end

-- Extract the leading short hash from a `vim.pack` pending line, e.g.
-- "> f3af041ea9f8 │ chore: bump" -> "f3af041ea9f8". Returns nil for lines
-- without a hash (placeholders, blanks).
local function pending_line_hash(line)
  return line:match("^>%s*(%x+)") or line:match("^%s*(%x%x%x%x%x%x%x+)%s")
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
  if type(pending) ~= "string" or pending == "" then
    pending = "(No pending update details available)"
  end

  -- line role maps keyed by 1-based line number, consumed in the highlight pass.
  local breaking_lines = {} -- full-line breaking emphasis
  local field_lines = {} -- value_hl (or true for label-only) for `Label: value`
  local section_lines = {} -- section headers ("Pending updates:")
  local meta_lines = {} -- dimmed lines (footer hint)
  local commit_lines = {} -- pending commit lines (hash gets accent)

  local status_value_hl = render.status_hl[row.status] or "DashPaqStatusUnknown"
  local risk_value_hl = (row.status == "update")
      and (row.breaking == true and "DashPaqRiskBreak" or (row.breaking == false and "DashPaqRiskSafe" or "DashPaqStatusUnknown"))
    or nil
  local repo_value_hl = row.repo_url and "DashPaqLink" or nil
  local diff_value_hl = row.diff_url and "DashPaqLink" or nil

  local lines = {
    ("Plugin: %s"):format(row.name),
    ("Status: %s"):format(row.status),
    ("Risk:   %s"):format(
      row.status ~= "update" and "not assessed"
        or (
          row.breaking == true and "potential breaking change"
          or (row.breaking == false and "no breaking signal detected" or "unknown")
        )
    ),
    ("Risk reason: %s"):format(row.risk_reason or "-"),
    ("Semver delta: %s"):format(row.semver_delta or "n/a"),
    ("Commit signals: %s"):format(row.commit_signal or "none"),
    ("Source: %s"):format(row.source or "-"),
    ("Repo:   %s"):format(row.repo_url or "-"),
    ("Diff:   %s"):format(row.diff_url or "-"),
    ("Current:%s"):format(
      " " .. (row.current_version or analysis.short_rev(row.rev_before) or analysis.short_rev(row.rev) or "-")
    ),
    ("Target: %s"):format(row.target_version or analysis.short_rev(row.rev_after) or "-"),
  }
  -- Map each header line to the highlight its value should carry, in the
  -- same order as the `lines` list above.
  field_lines[1] = "DashPaqTitle"
  field_lines[2] = status_value_hl
  field_lines[3] = risk_value_hl or true
  field_lines[4] = true
  field_lines[5] = true
  field_lines[6] = true
  field_lines[7] = true
  field_lines[8] = repo_value_hl or true
  field_lines[9] = diff_value_hl or true
  field_lines[10] = true
  field_lines[11] = true

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

  lines[#lines + 1] = ""
  -- For error rows the "pending" body holds the error text; label the section
  -- accordingly and color the body as an error so failures stand out.
  local is_error = row.status == "error"
  lines[#lines + 1] = is_error and "Error:" or "Pending updates:"
  section_lines[#lines] = is_error and "DashPaqStatusError" or "DashPaqHeader"
  for _, line in ipairs(vim.split(pending, "\n", { trimempty = false })) do
    lines[#lines + 1] = line
    if is_error then
      breaking_lines[#lines] = nil
      commit_lines[#lines] = "DashPaqStatusError"
    else
      local hash = pending_line_hash(line)
      if hash and breaking_hashes[hash] then
        breaking_lines[#lines] = true
      elseif hash then
        commit_lines[#lines] = "hash"
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "q / <Esc> close | o open commit under cursor | O open all commits (diff) | r open repo"
  meta_lines[#lines] = true

  ctx.details_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[ctx.details_bufnr].buftype = "nofile"
  vim.bo[ctx.details_bufnr].bufhidden = "wipe"
  vim.bo[ctx.details_bufnr].buflisted = false
  vim.bo[ctx.details_bufnr].swapfile = false
  -- Plain buffer (not markdown): the body is `Label: value` log text, so markdown
  -- syntax would mis-color commit subjects containing `*`/`#`/`_`. Our extmarks
  -- supply all the structure coloring instead.
  vim.bo[ctx.details_bufnr].filetype = "dashpaq-details"
  vim.api.nvim_buf_set_lines(ctx.details_bufnr, 0, -1, false, lines)
  vim.bo[ctx.details_bufnr].modifiable = false
  render.ensure_highlights()

  local bufnr = ctx.details_bufnr
  for line_no, value_hl in pairs(field_lines) do
    hl_field(bufnr, line_no, lines[line_no] or "", value_hl ~= true and value_hl or nil)
  end
  for line_no, group in pairs(section_lines) do
    hl_line(bufnr, line_no, lines[line_no] or "", group)
  end
  for line_no, group in pairs(commit_lines) do
    local line = lines[line_no] or ""
    if group == "hash" then
      -- Accent just the leading short hash; leave the subject default-colored.
      local hash = pending_line_hash(line)
      if hash then
        local hstart = line:find(hash, 1, true)
        if hstart then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, details_ns, line_no - 1, hstart - 1, {
            end_col = hstart - 1 + #hash,
            hl_group = "DashPaqStatusUpdate",
            priority = 160,
          })
        end
      end
    else
      hl_line(bufnr, line_no, line, group)
    end
  end
  for line_no in pairs(meta_lines) do
    hl_line(bufnr, line_no, lines[line_no] or "", "DashPaqMeta")
  end
  -- Breaking lines last, at a higher priority so they win over the per-field and
  -- per-commit colors stamped above on the same line.
  for line_no in pairs(breaking_lines) do
    local line = lines[line_no] or ""
    pcall(vim.api.nvim_buf_set_extmark, bufnr, details_ns, line_no - 1, 0, {
      end_col = #line,
      hl_group = "DashPaqRiskBreak",
      priority = 200,
    })
  end

  local editor_w = vim.o.columns
  local editor_h = vim.o.lines - vim.o.cmdheight
  local width = math.max(1, math.min(math.max(90, math.floor(editor_w * 0.75)), editor_w - 4))
  local height = math.max(1, math.min(math.max(22, math.floor(editor_h * 0.70)), editor_h - 4))
  ctx.details_winid = vim.api.nvim_open_win(ctx.details_bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = (" %s details "):format(row.name),
    title_pos = "center",
    row = math.floor((editor_h - height) / 2),
    col = math.floor((editor_w - width) / 2),
    width = width,
    height = height,
  })
  vim.wo[ctx.details_winid].wrap = true

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
      vim.notify("Move the cursor onto a pending commit line to open it", vim.log.levels.WARN)
      return
    end
    local commit_url = analysis.repo_to_commit_url(row.repo_url, hash)
    if commit_url then
      vim.ui.open(commit_url)
    else
      vim.notify("No commit URL for this plugin", vim.log.levels.WARN)
    end
  end, { buffer = ctx.details_bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "O", function()
    if row.diff_url then
      vim.ui.open(row.diff_url)
    else
      vim.notify("No diff URL for this plugin", vim.log.levels.WARN)
    end
  end, { buffer = ctx.details_bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "r", function()
    if row.repo_url then
      vim.ui.open(row.repo_url)
    else
      vim.notify("No repo URL for this plugin", vim.log.levels.WARN)
    end
  end, { buffer = ctx.details_bufnr, nowait = true, silent = true })
end

function M.open_help()
  local help_lines = {
    "dash-paq.nvim dashboard keys",
    "",
    "q / <Esc>  close dashboard",
    "R          refresh online (fetches remotes)",
    "r          offline status (no fetch; may not show remote updates)",
    "f          cycle filter (all -> updates -> issues -> selected)",
    "s          cycle sort (status <-> name)",
    "/ / c      set search / clear search",
    "<Space>/x  toggle row selection (also works in visual mode)",
    "a / A      toggle select all visible / clear all selection",
    "<CR>       update plugin at cursor",
    "u / U      update pending selected (or cursor if none) / all pending listed",
    "C          clean orphan plugins (selected orphans, else all orphans)",
    "V          heal drift: re-checkout drifted plugins to spec version (offline)",
    "o          open diff URL (fallback: repository)",
    "O          open repository URL",
    "K          open details popup",
    "L          toggle local dev checkout (upstream/local worktree), offers restart",
    "T          open load trace (current plugin)",
    "",
    "Risk: ! potential breaking change; + no breaking signal; - unknown/not assessed.",
    "Signals come from versions and commit messages; they do not prove compatibility.",
  }
  local hbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[hbuf].buftype = "nofile"
  vim.bo[hbuf].bufhidden = "wipe"
  vim.bo[hbuf].swapfile = false
  vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, help_lines)
  vim.bo[hbuf].modifiable = false

  local editor_w = vim.o.columns
  local editor_h = vim.o.lines - vim.o.cmdheight
  local width = math.max(1, math.min(88, editor_w - 4))
  local height = math.max(1, math.min(#help_lines + 2, editor_h - 4))
  local hwin = vim.api.nvim_open_win(hbuf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " dashboard help ",
    title_pos = "center",
    row = math.floor((editor_h - height) / 2),
    col = math.floor((editor_w - width) / 2),
    width = width,
    height = height,
  })
  vim.wo[hwin].wrap = true
  local close = function()
    if hwin and vim.api.nvim_win_is_valid(hwin) then
      vim.api.nvim_win_close(hwin, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = hbuf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = hbuf, nowait = true, silent = true })
end

return M
