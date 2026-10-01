-- An active-but-undeclared plugin must not be flagged orphan; an
-- installed, inactive, undeclared plugin must be. A wrong flag lets the
-- clean-orphans key delete an active plugin.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local inactive_remote = gitfixture.new_remote("undeclared")
gitfixture.commit(inactive_remote, "feat: initial", { ["README.md"] = "hello" })
gitfixture.push(inactive_remote)

-- `vim.pack.get`'s `active` field means "added this session", not "on disk". A genuine
-- `active = false` row needs installing from a separate process, before this one's first vim.pack call.
local install_script = vim.fn.tempname() .. ".lua"
vim.fn.writefile({
  string.format(
    "vim.pack.add({ { src = %q, name = %q } }, { confirm = false, load = function() end })",
    inactive_remote.src,
    "undeclared"
  ),
  "vim.cmd('qa!')",
}, install_script)
local install_result = vim
  .system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", install_script }, { text = true })
  :wait()
assert(install_result.code == 0, "child install failed: " .. tostring(install_result.stderr))

local remote = gitfixture.new_remote("bootstrapped")
gitfixture.commit(remote, "feat: initial", { ["README.md"] = "hello" })
gitfixture.push(remote)

-- Bootstrapped directly (bypassing setup()'s spec list), like a user adding dash-paq.nvim itself.
vim.pack.add({ { src = remote.src, name = "bootstrapped" } }, { confirm = false, load = function() end })

local state = require("dash_paq.dashboard.state")
local rows = require("dash_paq.dashboard.report.rows")

-- Orphan flagging needs a published declared set (rows.lua), so this simulates a run that declared some other plugin.
state.set_declared_plugin_names({ ["some-other-declared-plugin"] = true })

local dash_rows = rows.collect_dashboard_rows()
local bootstrapped_row = nil
local undeclared_row = nil
for _, row in ipairs(dash_rows) do
  if row.name == "bootstrapped" then
    bootstrapped_row = row
  elseif row.name == "undeclared" then
    undeclared_row = row
  end
end

t.describe("a plugin is active (bootstrapped by the user) but not declared by any spec", function()
  t.it("appears in the dashboard rows", function()
    t.assert.truthy(bootstrapped_row ~= nil)
  end)

  t.it("is not flagged as an orphan", function()
    t.assert.falsy(bootstrapped_row.is_orphan)
    t.assert.falsy(bootstrapped_row.status == "orphan")
  end)
end)

t.describe("a plugin is installed but neither active nor declared by any spec", function()
  t.it("appears in the dashboard rows", function()
    t.assert.truthy(undeclared_row ~= nil)
  end)

  t.it("is flagged as an orphan", function()
    t.assert.truthy(undeclared_row.is_orphan)
    t.assert.equals("orphan", undeclared_row.status)
  end)
end)

t.finish()
