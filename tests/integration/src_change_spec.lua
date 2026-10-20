-- Source strings identify repositories, as in vim.pack. A changed source
-- replaces the checkout without losing local work, even for an alias.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local same = gitfixture.new_remote("sameplug")
gitfixture.commit(same, "feat: initial", { ["README.md"] = "same" })
gitfixture.push(same)

local old = gitfixture.new_remote("movedold")
gitfixture.commit(old, "feat: initial", { ["README.md"] = "old" })
gitfixture.push(old)

local new = gitfixture.new_remote("movednew")
gitfixture.commit(new, "feat: initial", { ["README.md"] = "new" })
gitfixture.push(new)

local collision = gitfixture.new_remote("collision")
gitfixture.commit(collision, "feat: previous", { ["README.md"] = "previous" })
gitfixture.push(collision)
local collision_path = collision.bare:gsub("%.git$", "")
gitfixture.run({ "git", "clone", "--quiet", "--bare", new.bare, collision_path })
local collision_src = "file://" .. collision_path

local install_script = vim.fn.tempname() .. ".lua"
vim.fn.writefile({
  string.format(
    "vim.pack.add({{ src = %q, name = 'coldplug' }, { src = %q, name = 'suffixplug' }}, { confirm = false, load = false })",
    old.src,
    collision.src
  ),
}, install_script)
local installed = vim
  .system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", install_script }, { text = true })
  :wait(10000)
assert(installed.code == 0, installed.stderr)

local function noop() end
vim.pack.add({
  { src = (same.src:gsub("%.git$", "")), name = "sameplug" },
  { src = same.src, name = "unchangedplug" },
  { src = old.src, name = "movedplug" },
  { src = old.src, name = "failedplug" },
}, { confirm = false, load = noop })

-- Survives only if setup() leaves the existing clone in place.
local same_path = vim.pack.get({ "sameplug" }, { info = false })[1].path
local marker = vim.fs.joinpath(same_path, "kept.marker")
vim.fn.writefile({ "x" }, marker)
local unchanged_path = vim.pack.get({ "unchangedplug" }, { info = false })[1].path
local unchanged_marker = unchanged_path .. "/kept.marker"
vim.fn.writefile({ "x" }, unchanged_marker)

local moved_path = vim.pack.get({ "movedplug" }, { info = false })[1].path
vim.fn.writefile({ "local work" }, moved_path .. "/keep.marker")

local failed_path = vim.pack.get({ "failedplug" }, { info = false })[1].path
local failed_marker = failed_path .. "/keep.marker"
vim.fn.writefile({ "keep this data" }, failed_marker)
local notes = {}
local state = require("dash_paq.dashboard.state")
local error_lines = vim.fn.readfile(DASH_PAQ_TEST_ROOT .. "/tests/fixtures/report_0.12.4_error.txt")
local error_report = { error_lines[1] }
for _, name in ipairs({ "movedplug", "coldplug", "suffixplug" }) do
  for index = 2, #error_lines do
    error_report[#error_report + 1] = error_lines[index]:gsub("## badref", "## " .. name)
  end
end
local error_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(error_buf, 0, -1, false, error_report)
require("dash_paq.dashboard.report.parser").parse_pack_report_buffer(error_buf)
local parsed_error_source = state.pack_report_cache.plugins.movedplug.source
local original_error_row = require("dash_paq.dashboard.report").collect_dashboard_row("movedplug")
state.pack_report_cache.plugins.sameplug = { source = same.src:gsub("%.git$", ""), status = "same" }
state.pack_report_cache.plugins.unchangedplug = { source = same.src, status = "same" }
state.write_persisted_state()
local orig_notify = vim.notify
vim.notify = function(msg)
  notes[#notes + 1] = msg
end

require("dash_paq").setup({
  spec = {
    { src = same.src, name = "sameplug" },
    { src = same.src, name = "unchangedplug" },
    { src = new.src, name = "movedplug" },
    { src = new.src, name = "coldplug" },
    { src = collision_src, name = "suffixplug" },
    { src = new.src .. "-missing", name = "failedplug" },
  },
  dashboard = false,
  version_policy = false,
})

local reinstall_note
t.wait_until(function()
  for _, msg in ipairs(notes) do
    if msg:find("Reinstalled (src changed)", 1, true) then
      reinstall_note = msg
    end
  end
  return reinstall_note ~= nil
end, 5000, "reinstall notification")
vim.notify = orig_notify

local function origin(name)
  local path = vim.pack.get({ name }, { info = false })[1].path
  return vim.trim(vim.fn.system({ "git", "-C", path, "remote", "get-url", "origin" }))
end

t.describe("setup() with an installed remote that differs from the spec src", function()
  t.it("SHOULD treat a different source spelling as a source change", function()
    t.assert.equals(0, vim.fn.filereadable(marker))
    t.assert.truthy(reinstall_note:find("sameplug", 1, true))
  end)

  t.it("SHOULD retain a checkout whose source string is unchanged", function()
    t.assert.equals(1, vim.fn.filereadable(unchanged_marker))
    t.assert.falsy(reinstall_note:find("unchangedplug", 1, true))
  end)

  t.it("re-clones a plugin whose remote moved", function()
    t.assert.truthy(reinstall_note:find("movedplug", 1, true))
    t.assert.equals(new.src, origin("movedplug"))
  end)
end)

t.describe("WHEN a changed source was installed in a previous session", function()
  t.it("SHOULD replace the actual clone before registering the new spec", function()
    t.assert.equals(new.src, origin("coldplug"))
  end)

  t.it("SHOULD replace distinct repositories whose paths differ only by .git", function()
    local path = vim.pack.get({ "suffixplug" }, { info = false })[1].path
    t.assert.equals(collision_src, origin("suffixplug"))
    t.assert.same({ "new" }, vim.fn.readfile(path .. "/README.md"))
  end)
end)

t.describe("WHEN replacement installation fails", function()
  t.it("SHOULD preserve the old checkout and its untracked files", function()
    t.assert.equals(1, vim.fn.filereadable(failed_marker))
    t.assert.same({ "keep this data" }, vim.fn.readfile(failed_marker))
  end)

  t.it("SHOULD not announce the failed replacement as successful", function()
    t.assert.falsy(reinstall_note:find("failedplug", 1, true))
  end)
end)

local function isolated_setup(code)
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(vim.split(code, "\n"), script)
  local result = vim
    .system(
      { vim.v.progpath, "--headless", "-u", DASH_PAQ_TEST_ROOT .. "/tests/minimal_init.lua", "-l", script },
      { text = true }
    )
    :wait(10000)
  t.assert.equals(0, result.code, result.stderr)
end

t.describe("WHEN native lock state has not been initialized", function()
  t.it("SHOULD restore a missing checkout without an install prompt", function()
    isolated_setup([[
      local fixture = require("support.gitfixture")
      local remote = fixture.new_remote("cold_restore")
      local rev = fixture.commit(remote, "fix: initial", { ["README.md"] = "initial" })
      fixture.push(remote)
      vim.fn.writefile({ vim.json.encode({ plugins = { cold_restore = { src = remote.src, rev = rev } } }) }, vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json"))
      local confirms = 0
      vim.fn.confirm = function() confirms = confirms + 1; return 1 end
      require("dash_paq").setup({ spec = { { src = remote.src, name = "cold_restore" } }, dashboard = false, version_policy = false })
      assert(confirms == 0, "unexpected install confirmation: " .. confirms)
    ]])
  end)

  t.it("SHOULD still load local plugins when native lock parsing fails", function()
    isolated_setup([[
      local dir = require("support.dirfixture").new("local_lock_failure", {})
      vim.fn.writefile({ "{invalid" }, vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json"))
      local loaded = false
      require("dash_paq").setup({ spec = {
        { src = "file:///missing-dash-paq-fixture", name = "remote" },
        { dir = dir, name = "local_lock_failure", config = function() loaded = true end },
      }, dashboard = false, version_policy = false })
      assert(loaded, "local plugin skipped after native lock error")
    ]])
  end)
end)

t.describe("WHEN source replacement succeeds", function()
  t.it("SHOULD bind native error reports without Source to the installed repository", function()
    t.assert.equals(old.src, parsed_error_source)
    t.assert.equals("error", original_error_row.status)
    t.assert.match("Could not read from remote repository", original_error_row.pending_updates)
  end)

  t.it("SHOULD discard reports from a different repository with a matching .git stem", function()
    local row = require("dash_paq.dashboard.report").collect_dashboard_row("suffixplug")
    t.assert.equals("unknown", row.status)
    t.assert.equals(collision_src, row.source)
    t.assert.falsy(row.pending_updates)
  end)

  t.it("SHOULD discard the old source report when collecting one row", function()
    local row = require("dash_paq.dashboard.report").collect_dashboard_row("movedplug")
    t.assert.equals(new.src, row.source)
    t.assert.equals("unknown", row.status)
    t.assert.falsy(row.pending_updates)
    local saved = require("dash_paq.fs").read_json(require("dash_paq.fs").state_path("dashboard_state.json"))
    t.assert.falsy(saved.plugins.movedplug)
  end)

  t.it("SHOULD discard changed-source reports and retain identical sources", function()
    local rows = require("dash_paq.dashboard.report").collect_dashboard_rows()
    local by_name = {}
    for _, row in ipairs(rows) do
      by_name[row.name] = row
    end
    t.assert.equals(new.src, by_name.coldplug.source)
    t.assert.equals("unknown", by_name.coldplug.status)
    t.assert.equals("unknown", by_name.sameplug.status)
    t.assert.equals("same", by_name.unchangedplug.status)
    local saved = require("dash_paq.fs").read_json(require("dash_paq.fs").state_path("dashboard_state.json"))
    t.assert.falsy(saved.plugins.coldplug)
  end)

  t.it("SHOULD retain local files in the reported previous-checkout backup", function()
    local backups = vim.fn.glob(vim.fs.dirname(vim.fs.dirname(moved_path)) .. "/movedplug.backup-*", true, true)
    t.assert.equals(1, #backups)
    t.assert.same({ "local work" }, vim.fn.readfile(backups[1] .. "/keep.marker"))
  end)

  t.it("SHOULD discard a persisted report whose repository identity is unknown", function()
    state.pack_report_cache.plugins.movedplug = { status = "error", pending_updates = "legacy failure" }
    state.write_persisted_state()
    local row = require("dash_paq.dashboard.report").collect_dashboard_row("movedplug")
    t.assert.equals("unknown", row.status)
    t.assert.falsy(row.pending_updates)
    local saved = require("dash_paq.fs").read_json(require("dash_paq.fs").state_path("dashboard_state.json"))
    t.assert.falsy(saved.plugins.movedplug)
  end)
end)

t.finish()
