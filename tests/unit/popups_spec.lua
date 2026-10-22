local t = require("runner")
local view = require("dash_paq.dashboard.ui.view")
local render = require("dash_paq.dashboard.ui.render")
local popups = require("dash_paq.dashboard.ui.popups")

vim.o.columns = 160
vim.o.lines = 60

local function new_ctx()
  return view.new_context({
    bufnr = vim.api.nvim_create_buf(false, true),
    rows = {},
    selected = {},
    filter_mode = "all",
    sort_mode = "status",
  })
end

local function hl_at(bufnr, line_no, col)
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, { line_no - 1, 0 }, { line_no - 1, -1 }, {
      details = true,
    }))
  do
    if mark[3] == col then
      return mark[4].hl_group
    end
  end
end

local row = {
  name = "bufferline.nvim",
  status = "update",
  breaking = false,
  repo_url = "https://github.com/akinsho/bufferline.nvim",
  current_version = "v4.9.0",
  target_version = "v5.0.0",
  pending_updates = "> 1a2b3c4d │ feat: tabs\n> 5e6f7a8b │ fix: tabs",
}

t.describe("WHEN the details popup opens", function()
  local c = new_ctx()
  popups.open_details(c, row)
  local lines = vim.api.nvim_buf_get_lines(c.details_bufnr, 0, -1, false)

  t.it("SHOULD lay out a title pill, aligned properties, and the pending commits", function()
    t.assert.equals("   bufferline.nvim   " .. c.icons.update .. " update", lines[2])
    t.assert.equals("  Risk     no breaking signal detected", lines[4])
    t.assert.truthy(vim.tbl_contains(lines, "  Version  v4.9.0 -> v5.0.0"))
    t.assert.truthy(vim.tbl_contains(lines, "  Pending updates (2)"))
    t.assert.truthy(vim.tbl_contains(lines, "    > 1a2b3c4d │ feat: tabs"))
    t.assert.equals(
      "  q close · o open commit, else compare page or repo · O open repository · r refresh",
      lines[#lines]
    )
  end)

  t.it("SHOULD be as wide as the dashboard and as tall as its content", function()
    t.assert.equals(render.CONTENT_WIDTH, vim.api.nvim_win_get_width(c.details_winid))
    t.assert.equals(#lines, vim.api.nvim_win_get_height(c.details_winid))
  end)

  t.it("SHOULD highlight the title, the dimmed labels, and each commit hash", function()
    t.assert.equals("DashPaqH1", hl_at(c.details_bufnr, 2, 2))
    t.assert.equals("DashPaqMeta", hl_at(c.details_bufnr, 4, 2))
    local commit = 0
    for i, line in ipairs(lines) do
      if line == "    > 1a2b3c4d │ feat: tabs" then
        commit = i
      end
    end
    t.assert.equals("DashPaqStatusUpdate", hl_at(c.details_bufnr, commit, 6))
  end)

  t.it("SHOULD open the commit under the cursor despite the indentation", function()
    local opened
    local original = vim.ui.open
    vim.ui.open = function(url)
      opened = url
    end
    local commit = 0
    for i, line in ipairs(lines) do
      if line == "    > 5e6f7a8b │ fix: tabs" then
        commit = i
      end
    end
    vim.api.nvim_set_current_win(c.details_winid)
    vim.api.nvim_win_set_cursor(c.details_winid, { commit, 0 })
    vim.api.nvim_feedkeys("o", "x", false)
    vim.ui.open = original
    t.assert.match("5e6f7a8b", opened or "")
  end)
end)

t.describe("WHEN o, O, or r is pressed off a commit line in the details popup", function()
  local function press(key, details_row)
    local c = new_ctx()
    popups.open_details(c, details_row)
    local opened
    local original = vim.ui.open
    vim.ui.open = function(url)
      opened = url
    end
    local ok, err = pcall(function()
      vim.api.nvim_set_current_win(c.details_winid)
      vim.api.nvim_win_set_cursor(c.details_winid, { 2, 0 })
      vim.api.nvim_feedkeys(key, "x", false)
    end)
    vim.ui.open = original
    popups.close_details(c)
    assert(ok, err)
    return opened
  end
  local with_compare = vim.tbl_extend("force", row, { diff_url = "https://example.com/compare" })

  t.it("SHOULD open the compare page with o, as in the dashboard", function()
    t.assert.equals("https://example.com/compare", press("o", with_compare))
  end)

  t.it("SHOULD open the repository with O, as in the dashboard", function()
    t.assert.equals(row.repo_url, press("O", with_compare))
  end)

  t.it("SHOULD close and refresh offline with r, as in the dashboard", function()
    local refresh = require("dash_paq.dashboard.ui.refresh")
    local c = new_ctx()
    popups.open_details(c, row)
    local called
    local original = refresh.refresh
    refresh.refresh = function(ctx, online)
      called = { ctx = ctx, online = online }
    end
    local ok, err = pcall(function()
      vim.api.nvim_set_current_win(c.details_winid)
      vim.api.nvim_feedkeys("r", "x", false)
    end)
    refresh.refresh = original
    local still_open = c.details_winid ~= nil and vim.api.nvim_win_is_valid(c.details_winid)
    popups.close_details(c)
    assert(ok, err)
    t.assert.truthy(called and called.ctx == c and called.online == false)
    t.assert.falsy(still_open)
  end)
end)

t.describe("WHEN details have lines wider than the window", function()
  local c = new_ctx()
  popups.open_details(
    c,
    vim.tbl_extend("force", row, {
      diff_url = "https://github.com/akinsho/bufferline.nvim/compare/" .. string.rep("a", 40) .. "..." .. string.rep(
        "b",
        40
      ),
    })
  )

  t.it("SHOULD be tall enough to show every wrapped line", function()
    t.assert.equals(vim.api.nvim_win_text_height(c.details_winid, {}).all, vim.api.nvim_win_get_height(c.details_winid))
    t.assert.truthy(
      vim.api.nvim_win_get_height(c.details_winid) > vim.api.nvim_buf_line_count(c.details_bufnr),
      "the compare URL should wrap"
    )
  end)

  t.it("SHOULD continue a wrapped value under the value column", function()
    t.assert.equals(true, vim.wo[c.details_winid].breakindent)
    -- `Compare` is the longest label: 7 cells plus 2 spaces.
    t.assert.equals("shift:9", vim.wo[c.details_winid].breakindentopt)
  end)
end)

t.describe("WHEN details open on a drifted plugin", function()
  local c = new_ctx()
  popups.open_details(c, { name = "gitlinker.nvim", status = "drift" })

  t.it("SHOULD name the status in words", function()
    t.assert.equals(
      "   gitlinker.nvim   " .. c.icons.drift .. " drifted",
      vim.api.nvim_buf_get_lines(c.details_bufnr, 1, 2, false)[1]
    )
  end)
end)

t.describe("WHEN the help popup opens", function()
  popups.open_help()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  t.it("SHOULD group the keys under section titles with aligned keys", function()
    t.assert.equals("   dash-paq   Help ", lines[2])
    t.assert.truthy(vim.tbl_contains(lines, "  View"))
    t.assert.truthy(vim.tbl_contains(lines, "  - <Space> x  toggle the row (also in visual mode)"))
    t.assert.truthy(vim.tbl_contains(lines, "  - K          open details"))
    t.assert.truthy(vim.tbl_contains(lines, "  Status icons"))
    local icons = require("dash_paq.dashboard.ui.format").icons(true)
    t.assert.truthy(vim.tbl_contains(lines, "  - " .. icons.drift .. "   checkout differs from the spec's version"))
  end)

  t.it("SHOULD be as wide as the dashboard", function()
    t.assert.equals(render.CONTENT_WIDTH, vim.api.nvim_win_get_width(0))
  end)

  t.it("SHOULD highlight section titles and keys", function()
    local view_line, key_line
    for i, line in ipairs(lines) do
      if line == "  View" then
        view_line = i
      elseif line:find("^  %- K ") then
        key_line = i
      end
    end
    t.assert.equals("DashPaqH2", hl_at(bufnr, view_line, 2))
    t.assert.equals("DashPaqKey", hl_at(bufnr, key_line, 4))
  end)
end)

t.describe("WHEN details open in a narrow editor", function()
  t.it("SHOULD keep the dashboard's margin", function()
    vim.o.columns = 60
    local c = new_ctx()
    popups.open_details(c, row)
    local width = vim.api.nvim_win_get_width(c.details_winid)
    vim.api.nvim_win_close(c.details_winid, true)
    vim.o.columns = 160
    t.assert.equals(60 - require("dash_paq.config").defaults.dashboard.margin, width)
  end)
end)

t.finish()
