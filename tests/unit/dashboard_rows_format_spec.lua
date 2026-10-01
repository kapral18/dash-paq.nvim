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
    local icons = fmt.status_icons(fmt.icons(true))
    for status, glyph in pairs(icons) do
      t.assert.truthy(type(glyph) == "string" and glyph ~= "", "status " .. status .. " has an empty icon")
    end
  end)
end)

t.describe("deriving a risk label", function()
  local icons = fmt.icons(false)

  t.it("renders '-' for a non-update row", function()
    t.assert.equals("-", fmt.risk_label({ icons = icons }, { status = "same" }))
  end)

  t.it("renders the break icon when breaking = true", function()
    t.assert.equals(icons.risk_break, fmt.risk_label({ icons = icons }, { status = "update", breaking = true }))
  end)

  t.it("renders the safe icon when breaking = false", function()
    t.assert.equals(icons.risk_safe, fmt.risk_label({ icons = icons }, { status = "update", breaking = false }))
  end)

  t.it("renders the unknown icon when breaking = nil", function()
    t.assert.equals(icons.risk_unknown, fmt.risk_label({ icons = icons }, { status = "update", breaking = nil }))
  end)
end)

t.finish()
