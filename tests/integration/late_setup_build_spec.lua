-- setup() called after startup (v:vim_did_init ~= 0, as in `nvim -l`): an install during setup()'s own
-- `vim.pack.add` fires `PackChanged` before the loader can load entries. The build hook must be queued and run
-- once setup() has finished (nothing else would flush it: `VimEnter` already fired), not raise on a nil loader.
local t = require("runner")
local gitfixture = require("support.gitfixture")

_G.DASH_PAQ_TEST_LOG = {}

local remote = gitfixture.new_remote("late-build")
gitfixture.commit(remote, "feat: initial", {
  ["plugin/init.lua"] = [[table.insert(_G.DASH_PAQ_TEST_LOG, "late-build-plugin")]],
})
gitfixture.push(remote)

local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  notified[#notified + 1] = { msg = msg, level = level }
end

local ok, err = pcall(function()
  require("dash_paq").setup({
    spec = {
      {
        src = remote.src,
        name = "late_build",
        build = function()
          table.insert(_G.DASH_PAQ_TEST_LOG, "late-build-ran")
        end,
      },
    },
    dashboard = false,
    version_policy = false,
  })
end)
vim.notify = orig_notify

t.describe("setup() after startup installs a plugin that has a build hook", function()
  t.it("does not raise or report an error", function()
    t.assert.truthy(ok, tostring(err))
    for _, n in ipairs(notified) do
      t.assert.falsy(n.level == vim.log.levels.ERROR, tostring(n.msg))
    end
  end)

  t.it("runs the build once the plugin is loaded", function()
    t.assert.equals(1, #vim.tbl_filter(function(v)
      return v == "late-build-ran"
    end, _G.DASH_PAQ_TEST_LOG))
    local ran_at, loaded_at
    for i, v in ipairs(_G.DASH_PAQ_TEST_LOG) do
      if v == "late-build-ran" then
        ran_at = i
      elseif v == "late-build-plugin" then
        loaded_at = i
      end
    end
    t.assert.truthy(loaded_at and ran_at and loaded_at < ran_at, "plugin must be sourced before its build")
  end)
end)

t.finish()
