local t = require("runner")
local fixture = require("support.gitfixture")
local remote = fixture.new_remote("window")
fixture.commit(remote, "fix: v1", { ["README.md"] = "v1" })
fixture.push(remote)
require("dash_paq").setup({
  dashboard = { refresh_on_open = false },
  version_policy = false,
  spec = { { src = remote.src, name = "windowed" } },
})
local ui = require("dash_paq.dashboard.ui")

local function open_width(columns)
  vim.o.columns = columns
  ui.open(true)
  local width = vim.api.nvim_win_get_width(0)
  vim.api.nvim_win_close(0, true)
  return width
end

t.describe("WHEN the dashboard window opens", function()
  t.it("SHOULD be as wide as the table and its margins in a wide editor", function()
    t.assert.equals(88, open_width(200))
  end)

  t.it("SHOULD keep the margin in a narrow editor", function()
    t.assert.equals(60 - 6, open_width(60))
  end)
end)

t.describe("WHEN a row is collected", function()
  local state = require("dash_paq.dashboard.state")
  local rows = require("dash_paq.dashboard.report.rows")
  local head = vim.trim(fixture.run({ "git", "-C", vim.pack.get({ "windowed" })[1].path, "rev-parse", "HEAD" }))

  local analysis = require("dash_paq.dashboard.analysis")

  -- `file://` fixtures have no forge URL, so stand in for the URL builder and
  -- check which revisions reach it.
  local function diff_url(rev_before, rev_after)
    local original = analysis.source_to_compare_url
    analysis.source_to_compare_url = function(_, from, to)
      return "compare/" .. from .. "..." .. to
    end
    state.pack_report_cache.plugins.windowed = {
      status = rev_before == rev_after and "same" or "update",
      source = remote.src,
      rev_before = rev_before,
      rev_after = rev_after,
    }
    local ok, row = pcall(rows.collect_dashboard_row, "windowed")
    analysis.source_to_compare_url = original
    assert(ok, row)
    return row.diff_url
  end

  t.it("SHOULD give an up-to-date plugin no compare link", function()
    t.assert.equals(nil, diff_url(head, head))
  end)

  t.it("SHOULD link the compare page when the revisions differ", function()
    t.assert.equals("compare/" .. head .. "...abc1234", diff_url(head, "abc1234"))
  end)
end)

t.describe("WHEN o opens a row without a compare link", function()
  local operations = require("dash_paq.dashboard.ui.operations")

  local function open(row)
    local opened, notices = {}, {}
    local orig_open, orig_notify = vim.ui.open, vim.notify
    vim.ui.open = function(url)
      opened[#opened + 1] = url
    end
    vim.notify = function(msg)
      notices[#notices + 1] = msg
    end
    local ok, err = pcall(operations.open_diff_or_repo_for_row, row)
    vim.ui.open, vim.notify = orig_open, orig_notify
    assert(ok, err)
    return opened, notices
  end

  t.it("SHOULD open the repository quietly for an up-to-date plugin", function()
    local opened, notices = open({ status = "same", repo_url = "https://example.com/repo" })
    t.assert.same({ "https://example.com/repo" }, opened)
    t.assert.same({}, notices)
  end)

  t.it("SHOULD say the compare page is missing for a pending update", function()
    local opened, notices = open({ status = "update", repo_url = "https://example.com/repo" })
    t.assert.same({ "https://example.com/repo" }, opened)
    t.assert.equals(1, #notices)
  end)
end)

t.finish()
