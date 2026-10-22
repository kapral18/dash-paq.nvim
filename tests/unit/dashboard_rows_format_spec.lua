local t = require("runner")
local rows = require("dash_paq.dashboard.ui.rows")
local fmt = require("dash_paq.dashboard.ui.format")

local function ctx(overrides)
  local base = {
    rows = {
      { name = "aaa", status = "same" },
      { name = "bbb", status = "update" },
      { name = "ccc", status = "error" },
      { name = "ddd", status = "drift" },
      { name = "eee", status = "orphan" },
      { name = "fff", status = "risky" },
    },
    filter_mode = "all",
    sort_mode = "status",
    search_text = nil,
    selected = {},
  }
  return vim.tbl_extend("force", base, overrides or {})
end

t.describe("filtering visible rows", function()
  t.it("shows every row for filter_mode = all", function()
    t.assert.equals(6, #rows.visible(ctx()))
  end)

  t.it("shows only update rows for filter_mode = updates", function()
    local visible = rows.visible(ctx({ filter_mode = "updates" }))
    t.assert.equals(1, #visible)
    t.assert.equals("bbb", visible[1].name)
  end)

  t.it("shows update/error/orphan/drift/risky for filter_mode = issues", function()
    t.assert.equals(5, #rows.visible(ctx({ filter_mode = "issues" })))
  end)

  t.it("shows only selected rows for filter_mode = selected", function()
    local visible = rows.visible(ctx({ filter_mode = "selected", selected = { aaa = true } }))
    t.assert.equals(1, #visible)
    t.assert.equals("aaa", visible[1].name)
  end)

  t.it("applies a case-insensitive substring search filter", function()
    local visible = rows.visible(ctx({ search_text = "AA" }))
    t.assert.equals(1, #visible)
    t.assert.equals("aaa", visible[1].name)
  end)
end)

t.describe("sorting visible rows", function()
  t.it("sorts alphabetically for sort_mode = name", function()
    local visible = rows.visible(ctx({ sort_mode = "name" }))
    local names = {}
    for _, r in ipairs(visible) do
      names[#names + 1] = r.name
    end
    t.assert.same({ "aaa", "bbb", "ccc", "ddd", "eee", "fff" }, names)
  end)

  t.it(
    "ranks drift before orphan before risky before error before update before same for sort_mode = status",
    function()
      local visible = rows.visible(ctx({ sort_mode = "status" }))
      t.assert.equals("drift", visible[1].status)
      t.assert.equals("same", visible[#visible].status)
    end
  )
end)

t.describe("summarizing counts", function()
  t.it("counts every status bucket", function()
    local counts = rows.summary_counts(ctx())
    t.assert.equals(1, counts.update)
    t.assert.equals(1, counts.same)
    t.assert.equals(1, counts.error)
    t.assert.equals(1, counts.drift)
    t.assert.equals(1, counts.orphan)
    t.assert.equals(1, counts.risky)
  end)

  t.it("counts breaking = true rows separately", function()
    local counts = rows.summary_counts(ctx({ rows = { { name = "x", status = "update", breaking = true } } }))
    t.assert.equals(1, counts.breaking)
  end)
end)

t.describe("counting/listing selection", function()
  local c = ctx({ selected = { aaa = true, bbb = true } })

  t.it("counts every selected row across the full set", function()
    t.assert.equals(2, rows.selected_count(c, false))
  end)

  t.it("lists selected names sorted by the row iteration order", function()
    t.assert.same({ "aaa", "bbb" }, rows.selected_names(c, false))
  end)
end)

t.describe("toggling select-all over visible rows", function()
  t.it("selects every visible row when none are selected", function()
    local c = ctx()
    rows.toggle_all_visible(c)
    t.assert.equals(6, rows.selected_count(c, false))
  end)

  t.it("selects every visible row when only some are selected", function()
    local c = ctx({ selected = { aaa = true } })
    rows.toggle_all_visible(c)
    t.assert.equals(6, rows.selected_count(c, false))
  end)

  t.it("deselects every visible row when all are selected", function()
    local c = ctx()
    rows.toggle_all_visible(c)
    rows.toggle_all_visible(c)
    t.assert.equals(0, rows.selected_count(c, false))
  end)

  t.it("leaves selection on rows hidden by the filter untouched", function()
    local c = ctx({ filter_mode = "updates", selected = { aaa = true, bbb = true } })
    rows.toggle_all_visible(c)
    t.assert.same({ "aaa" }, rows.selected_names(c, false))
  end)

  t.it("does nothing when no row is visible", function()
    local c = ctx({ search_text = "zzz", selected = { aaa = true } })
    rows.toggle_all_visible(c)
    t.assert.same({ "aaa" }, rows.selected_names(c, false))
  end)
end)

t.describe("truncating display text (format.truncate_display)", function()
  t.it("returns text unchanged when it fits", function()
    t.assert.equals("short", fmt.truncate_display("short", 10))
  end)

  t.it("truncates and appends an ellipsis when it overflows", function()
    local truncated = fmt.truncate_display("a very long plugin name", 8)
    t.assert.equals(8, vim.fn.strdisplaywidth(truncated))
    t.assert.match("…$", truncated)
  end)

  t.it("returns an empty string for max_width <= 0", function()
    t.assert.equals("", fmt.truncate_display("x", 0))
  end)
end)

t.describe("padding a cell (format.pad_cell)", function()
  t.it("right-pads with spaces to the target width", function()
    t.assert.equals("ab  ", fmt.pad_cell("ab", 4))
  end)

  t.it("does not pad when the value already fills the width", function()
    t.assert.equals("abcd", fmt.pad_cell("abcd", 4))
  end)
end)

t.describe("formatting a version cell", function()
  t.it("renders 'local' for a dev-directory row", function()
    t.assert.equals("local", fmt.version_cell({ status = "local" }))
  end)

  t.it("renders current -> target for an update row", function()
    t.assert.equals(
      "v1.0.0 -> v1.1.0",
      fmt.version_cell({ status = "update", current_version = "v1.0.0", target_version = "v1.1.0" })
    )
  end)

  t.it("renders just the current version for a same row", function()
    t.assert.equals("v1.0.0", fmt.version_cell({ status = "same", current_version = "v1.0.0" }))
  end)

  t.it("renders '-' placeholders when nothing is known", function()
    t.assert.equals("- -> -", fmt.version_cell({ status = "update" }))
  end)
end)

t.describe("building nerd-font icons", function()
  t.it("gives every status icon a non-empty glyph", function()
    local icons = fmt.icons(true)
    for status in pairs(fmt.status_rank) do
      local glyph = icons[status]
      t.assert.truthy(type(glyph) == "string" and glyph ~= "", "status " .. status .. " has an empty icon")
    end
  end)
end)

t.describe("writing a row note", function()
  t.it("names a possible breaking change on an update row", function()
    t.assert.equals("possibly breaking", fmt.note_cell({ status = "update", breaking = true }))
  end)

  t.it("gives an update row its size: the semver step, else the commit count", function()
    t.assert.equals("minor release", fmt.note_cell({ status = "update", breaking = false, semver_delta = "minor" }))
    t.assert.equals("patch release", fmt.note_cell({ status = "update", semver_delta = "patch" }))
    local pending = "> 1a2b3c4d │ feat: a\n> 5e6f7a8b │ fix: b\n> 9c0d1e2f │ fix: c"
    t.assert.equals("3 commits", fmt.note_cell({ status = "update", pending_updates = pending }))
    t.assert.equals("1 commit", fmt.note_cell({ status = "update", pending_updates = "> 1a2b3c4d │ feat: a" }))
  end)

  t.it("calls a move to a lower version or back over commits a downgrade", function()
    t.assert.equals(
      "downgrade",
      fmt.note_cell({ status = "update", semver_delta = "minor", current_version = "v1.2.0", target_version = "v1.1.0" })
    )
    t.assert.equals("downgrade", fmt.note_cell({ status = "update", pending_updates = "< 1a2b3c4d │ feat: a" }))
  end)

  t.it("leaves an update with nothing known and up-to-date rows blank", function()
    t.assert.equals("", fmt.note_cell({ status = "update" }))
    t.assert.equals("", fmt.note_cell({ status = "same" }))
  end)

  t.it("explains statuses that need attention in words", function()
    t.assert.same(
      { "drifted from spec", "non-release tag", "not in spec", "failed", "not checked" },
      vim.tbl_map(function(status)
        return fmt.note_cell({ status = status })
      end, { "drift", "risky", "orphan", "error", "unknown" })
    )
  end)
end)

t.describe("rendering a dashboard with no visible rows", function()
  local view = require("dash_paq.dashboard.ui.view")
  local render = require("dash_paq.dashboard.ui.render")

  local function tail_lines(rows_list, search_text, filter_mode)
    local c = view.new_context({
      bufnr = vim.api.nvim_create_buf(false, true),
      rows = rows_list,
      selected = {},
      filter_mode = filter_mode or "all",
      sort_mode = "status",
      search_text = search_text,
    })
    render.render(c)
    return vim.api.nvim_buf_get_lines(c.bufnr, c.header_line_count, -1, false)
  end
  local two_rows = { { name = "aaa", status = "same" }, { name = "bbb", status = "update" } }

  t.it("says no plugins are installed when there are no rows", function()
    t.assert.same({ "  (No plugins installed)" }, tail_lines({}, nil))
  end)

  t.it("says the search hides every row when rows exist", function()
    t.assert.same(
      { "  (0 of 2 shown: search 'zzz' hides the rest)", "  c clears the search" },
      tail_lines(two_rows, "zzz")
    )
  end)

  t.it("shortens a long search inside its quotes", function()
    local line = tail_lines(two_rows, string.rep("z", 100))[1]
    t.assert.truthy(vim.fn.strdisplaywidth(line) <= 86, line)
    t.assert.match("search 'z+…' hides the rest%)$", line)
  end)

  t.it("names only the filter key when no search is active", function()
    t.assert.same(
      { "  (0 of 1 shown: the Updates filter hides the rest)", "  f cycles the filter" },
      tail_lines({ { name = "aaa", status = "same" } }, nil, "updates")
    )
  end)

  t.it("keeps the message within the table width for a long filter and search", function()
    local lines = tail_lines(two_rows, string.rep("z", 60), "updates")
    for _, line in ipairs(lines) do
      t.assert.truthy(vim.fn.strdisplaywidth(line) <= 86, "too wide: " .. line)
    end
    t.assert.match("^  %(0 of 2 shown: the Updates filter and search 'z+…' hide the rest%)$", lines[1])
  end)
end)

t.describe("WHEN the dashboard header renders", function()
  local view = require("dash_paq.dashboard.ui.view")
  local render = require("dash_paq.dashboard.ui.render")
  local state = require("dash_paq.dashboard.state")
  local small_rows = {
    { name = "aaa", status = "same" },
    { name = "bbb", status = "update", breaking = true },
    { name = "ccc", status = "error" },
  }

  -- Renders an ASCII dashboard at `width` cells; `prepare(c)` adjusts the
  -- context after `new_context` resets its runtime fields.
  local function render_header(width, prepare, groups_line)
    local c = view.new_context(ctx({ bufnr = vim.api.nvim_create_buf(false, true), rows = small_rows }))
    c.use_nerd_font = false
    c.icons = fmt.icons(false)
    c.spinner_frames = fmt.spinner_frames(false)
    if prepare then
      prepare(c)
    end
    -- Headless Neovim starts 80 columns wide; floats cannot exceed the editor.
    local saved_columns = vim.o.columns
    vim.o.columns = math.max(saved_columns, width)
    c.winid =
      vim.api.nvim_open_win(c.bufnr, false, { relative = "editor", row = 0, col = 0, width = width, height = 15 })
    local saved_mode = state.pack_report_cache.mode
    state.pack_report_cache.mode = nil
    local ok, err = pcall(render.render, c)
    state.pack_report_cache.mode = saved_mode
    vim.api.nvim_win_close(c.winid, true)
    vim.o.columns = saved_columns
    assert(ok, err)
    local header = vim.api.nvim_buf_get_lines(c.bufnr, 0, c.header_line_count, false)
    -- Highlight group by start column on `groups_line`.
    local groups = {}
    for _, mark in
      ipairs(
        vim.api.nvim_buf_get_extmarks(
          c.bufnr,
          -1,
          { groups_line or 0, 0 },
          { groups_line or 0, -1 },
          { details = true }
        )
      )
    do
      groups[mark[3]] = mark[4].hl_group
    end
    return header, c, groups
  end

  local function refreshing(c)
    c.online_check_running = true
    c.online_check_progress = { label = "Updating", total = 2, done = 2 }
    c.refreshing = { bbb = true }
  end

  local function filtered(c)
    c.filter_mode = "updates"
    c.search_text = "b"
  end

  -- Every header line and the rule share the column header's width.
  -- The table plus a two-cell left margin; the window adds the right margin.
  local LINE_WIDTH = 86

  t.it("SHOULD show title and filter pills, the summary, and dimmed meta", function()
    local header = render_header(120)
    t.assert.same({
      "",
      "   dash-paq   All   Updates   Issues   Selected  (f)" .. string.rep(" ", 18) .. "press ? for help",
      "",
      "  Total: 3 plugins   U 1 update   ! 1 possibly breaking   E 1 failed   = 1 up to date",
      "  not checked yet · sorted by status",
      "",
    }, vim.list_slice(header, 1, 6))
    t.assert.equals(LINE_WIDTH, vim.fn.strdisplaywidth(header[2]))
  end)

  t.it("SHOULD title the columns in plain words above a rule, aligned with the rows", function()
    local header, c = render_header(120)
    t.assert.match("^%s+Plugin%s+Version%s+Note%s*$", header[7])
    t.assert.equals("  " .. string.rep("-", 84), header[8])
    local first = vim.api.nvim_buf_get_lines(c.bufnr, c.header_line_count, c.header_line_count + 1, false)[1]
    t.assert.equals(LINE_WIDTH, vim.fn.strdisplaywidth(first))
    t.assert.equals(header[7]:find("Plugin"), first:find("ccc"))
    -- The version cell starts right after the 31-cell plugin cell and a space.
    t.assert.equals(header[7]:find("Version"), first:find("ccc") + 31 + 1)
    t.assert.equals(header[7]:find("Note"), first:find("failed"))
  end)

  t.it("SHOULD highlight the title and the active filter pill", function()
    local _, _, groups = render_header(120, nil, 1)
    t.assert.same({ "DashPaqH1", "DashPaqButtonActive", "DashPaqButton" }, { groups[2], groups[13], groups[19] })
  end)

  t.it("SHOULD hide a refreshing row's cached note until its result lands", function()
    local _, c = render_header(120, function(c)
      c.refreshing = { ccc = true }
    end)
    local lines = vim.api.nvim_buf_get_lines(c.bufnr, c.header_line_count, -1, false)
    for _, line in ipairs(lines) do
      if line:find("ccc", 1, true) then
        t.assert.falsy(line:find("failed", 1, true), line)
      end
    end
  end)

  t.it("SHOULD color a failed plugin's note like its status", function()
    local header, c, groups = render_header(120, nil, 8)
    local first = vim.api.nvim_buf_get_lines(c.bufnr, #header, #header + 1, false)[1]
    t.assert.equals(require("dash_paq.dashboard.ui.render").status_hl.error, groups[first:find("failed") - 1])
  end)

  t.it("SHOULD dim an update's size note and warn only for a possible break", function()
    local header, c, groups = render_header(120, function(c)
      c.rows = { { name = "sized", status = "update", semver_delta = "minor" } }
    end, 8)
    local first = vim.api.nvim_buf_get_lines(c.bufnr, #header, #header + 1, false)[1]
    t.assert.equals("DashPaqMeta", groups[first:find("minor release", 1, true) - 1])
    local header2, c2, groups2 = render_header(120, function(c)
      c.rows = { { name = "risky", status = "update", breaking = true } }
    end, 8)
    local row = vim.api.nvim_buf_get_lines(c2.bufnr, #header2, #header2 + 1, false)[1]
    t.assert.equals("DashPaqRiskBreak", groups2[row:find("possibly breaking", 1, true) - 1])
  end)

  t.it("SHOULD keep every count when large counts need narrower gaps", function()
    local header = render_header(120, function(c)
      c.rows = {}
      local mix = { update = 40, error = 15, drift = 15, risky = 15, orphan = 15, unknown = 15, same = 20 }
      mix["local"] = 15
      for status, n in pairs(mix) do
        for i = 1, n do
          c.rows[#c.rows + 1] =
            { name = "p" .. status .. i, status = status, breaking = status == "update" and i <= 20 }
        end
      end
      c.search_text = "p"
    end)
    t.assert.truthy(vim.fn.strdisplaywidth(header[4]) <= LINE_WIDTH, header[4])
    t.assert.match("^  Showing: 150 of 150 plugins  U 40  ! 20  E 15 .*  L 15$", header[4])
  end)

  t.it("SHOULD count a single plugin in the singular", function()
    local header = render_header(120, function(c)
      c.rows = { { name = "aaa", status = "same" } }
    end)
    t.assert.equals("  Total: 1 plugin   = 1 up to date", header[4])
  end)

  t.it("SHOULD keep the progress bar and rule within the table when lines draw two cells wide", function()
    local saved = vim.o.ambiwidth
    vim.o.ambiwidth = "double"
    local header, _, groups = render_header(120, function(c)
      c.use_nerd_font = true
      c.icons = fmt.icons(true)
      refreshing(c)
      c.online_check_progress.done = 1
    end, 2)
    local widths = { vim.fn.strdisplaywidth(header[3]), vim.fn.strdisplaywidth(header[8]) }
    vim.o.ambiwidth = saved
    t.assert.truthy(widths[1] <= LINE_WIDTH and widths[2] <= LINE_WIDTH, vim.inspect(widths))
    t.assert.truthy(vim.tbl_contains(vim.tbl_values(groups), "DashPaqRule"), "the unfilled part of the bar is shown")
  end)

  t.it("SHOULD keep Nerd Font status icons that draw two cells wide", function()
    local saved = vim.o.ambiwidth
    vim.o.ambiwidth = "double"
    local header, c = render_header(120, function(c)
      c.use_nerd_font = true
      c.icons = fmt.icons(true)
    end)
    vim.o.ambiwidth = saved
    local first = vim.api.nvim_buf_get_lines(c.bufnr, #header, #header + 1, false)[1]
    t.assert.truthy(first:find(c.icons.error, 1, true), first)
  end)

  t.it("SHOULD drop words from the least urgent counts when the line is too wide", function()
    local header = render_header(120, function(c)
      c.rows = {
        { name = "a", status = "update", breaking = true },
        { name = "b", status = "error" },
        { name = "c", status = "drift" },
        { name = "d", status = "risky" },
        { name = "e", status = "orphan" },
        { name = "f", status = "same" },
        { name = "g", status = "local" },
      }
    end)
    t.assert.truthy(vim.fn.strdisplaywidth(header[4]) <= LINE_WIDTH, header[4])
    t.assert.equals("  Total: 7 plugins   U 1 update   ! 1   E 1   D 1   W 1   O 1   = 1   L 1", header[4])
  end)

  t.it("SHOULD use plain words and plurals for the counts", function()
    local header = render_header(120, function(c)
      c.rows = {
        { name = "a", status = "unknown" },
        { name = "b", status = "unknown" },
        { name = "c", status = "drift" },
      }
    end)
    t.assert.equals("  Total: 3 plugins   D 1 drifted   ? 2 not checked", header[4])
  end)

  t.it("SHOULD keep the same height while refreshing or filtering", function()
    local _, idle = render_header(120)
    local _, busy = render_header(120, refreshing)
    local _, narrowed = render_header(120, filtered)
    t.assert.same(
      { idle.header_line_count, idle.header_line_count },
      { busy.header_line_count, narrowed.header_line_count }
    )
  end)

  t.it("SHOULD draw a progress bar and count completed rows while refreshing", function()
    local header, _, groups = render_header(120, refreshing, 2)
    t.assert.equals("  " .. string.rep("=", 42) .. string.rep("-", 42), header[3])
    t.assert.same({ "DashPaqProgress", "DashPaqRule" }, { groups[2], groups[2 + 42] })
    t.assert.match("^  Updating: 1/2   ", header[4])
  end)

  t.it("SHOULD mark an active filter and search", function()
    local header, _, groups = render_header(120, filtered, 1)
    t.assert.match("^  Showing: 1 of 3 plugins   ", header[4])
    t.assert.equals("  not checked yet · sorted by status · search 'b'", header[5])
    t.assert.same({ "DashPaqButton", "DashPaqButtonActive" }, { groups[13], groups[19] })
  end)

  t.it("SHOULD shorten a long search to fit the line", function()
    local header = render_header(120, function(c)
      c.search_text = string.rep("a", 60)
    end)
    t.assert.equals(LINE_WIDTH, vim.fn.strdisplaywidth(header[5]))
    t.assert.match("search '" .. string.rep("a", 37) .. "…'$", header[5])
  end)

  t.it("SHOULD keep every header line within the table width with everything active", function()
    local header = render_header(120, function(c)
      c.filter_mode = "selected"
      c.search_text = "telescope-fzf-native-and-more"
      for _, row in ipairs(small_rows) do
        c.selected[row.name] = true
      end
    end)
    for _, line in ipairs(header) do
      t.assert.truthy(vim.fn.strdisplaywidth(line) <= LINE_WIDTH, "too wide: " .. line)
    end
    t.assert.match("search 'tel[^']*…' · 3 selected %(3 hidden%)$", header[5])
  end)
end)

t.finish()
