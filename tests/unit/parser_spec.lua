-- Fixtures are real Neovim 0.12.4 vim.pack.update confirm buffers.
local t = require("runner")
local state = require("pack_companion.dashboard.state")
local parser = require("pack_companion.dashboard.report.parser")

local function fixture_lines(name)
  local root = _G.PACK_COMPANION_TEST_ROOT
  return vim.fn.readfile(vim.fs.joinpath(root, "tests", "fixtures", name))
end

local function parse_fixture(name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, fixture_lines(name))
  local counts = parser.parse_pack_report_buffer(bufnr)
  return counts, vim.deepcopy(state.pack_report_cache.plugins)
end

t.describe("parsing a real 0.12.4 report with an Update and a Same section", function()
  local counts, plugins = parse_fixture("report_0.12.4_update_and_same.txt")

  t.it("counts one update and one same", function()
    t.assert.equals(1, counts.update)
    t.assert.equals(1, counts.same)
    t.assert.equals(0, counts.error)
  end)

  t.it("captures the update plugin's path/source/revisions/target version", function()
    local p = plugins.tagged
    t.assert.truthy(p ~= nil)
    t.assert.equals("update", p.status)
    t.assert.match("/tagged$", p.path)
    t.assert.match("^file://", p.source)
    t.assert.equals("585246c70c959b1179d65c77aae2e259af78e9cd", p.rev_before)
    t.assert.equals("556154758d275dd9ea80b306aa2394fcac615ca1", p.rev_after)
    t.assert.equals("v1.1.0", p.target_version)
  end)

  t.it("captures the update plugin's pending-updates text", function()
    t.assert.match("feat: add feature", plugins.tagged.pending_updates)
  end)

  t.it("captures the same plugin's single revision and its ref name", function()
    local p = plugins.samestatic
    t.assert.truthy(p ~= nil)
    t.assert.equals("same", p.status)
    t.assert.equals("6aec41bfec5a91a3c126aa553ce780e8cd52fa35", p.rev)
    t.assert.equals("main", p.current_version)
  end)
end)

t.describe("parsing a real 0.12.4 report with an Error section", function()
  local counts, plugins = parse_fixture("report_0.12.4_error.txt")

  t.it("counts one error and no update/same", function()
    t.assert.equals(1, counts.error)
    t.assert.equals(0, counts.update)
    t.assert.equals(0, counts.same)
  end)

  t.it("records the errored plugin by name", function()
    t.assert.truthy(plugins.badref ~= nil)
    t.assert.equals("error", plugins.badref.status)
  end)
end)

t.describe("a plugin heading carries the '(not active)' suffix", function()
  t.it("strips the suffix so the plugin is still keyed by its bare name", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "# Same ---",
      "",
      "## notactive (not active)",
      "Path:     /tmp/notactive",
      "Source:   file:///tmp/notactive-remote.git",
      "Revision: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (main)",
    })
    local counts = parser.parse_pack_report_buffer(bufnr)
    t.assert.equals(1, counts.same)
    t.assert.truthy(state.pack_report_cache.plugins.notactive ~= nil)
  end)
end)

t.describe("locating the live confirm buffer among other buffers", function()
  t.it("finds the buffer named nvim-pack://confirm#<n>", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(scratch, "scratch-unrelated")
    local confirm = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(confirm, "nvim-pack://confirm#42")
    t.assert.equals(confirm, parser.find_pack_report_buffer())
  end)
end)

t.finish()
