-- An exported `GIT_DIR`/`GIT_WORK_TREE` (a bare-dotfiles shell, or nvim spawned from a git hook) overrides
-- `git -C <path>`. Every git call must still read the plugin's own clone, not the repository those vars name.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local plug = gitfixture.new_remote("envplug")
gitfixture.commit(plug, "feat: initial", { ["README.md"] = "v1" })
gitfixture.tag(plug, "v1.2.3")
gitfixture.push(plug)

local other = gitfixture.new_remote("envother")
gitfixture.commit(other, "feat: unrelated", { ["README.md"] = "other" })
gitfixture.tag(other, "v9.9.9")

require("dash_paq").setup({
  spec = { { src = plug.src, name = "envplug" } },
  dashboard = true,
  version_policy = {},
})

local path = vim.pack.get({ "envplug" }, { info = false })[1].path

vim.env.GIT_DIR = other.work .. "/.git"
vim.env.GIT_WORK_TREE = other.work

t.describe("git calls under an exported GIT_DIR", function()
  t.it("version policy reads the plugin's own tags", function()
    t.assert.truthy(require("dash_paq.policy").refresh_version_policy_if_needed())
    local cached = require("dash_paq.policy").load_version_policy()
    t.assert.equals("v1.2.3", cached.plugins.envplug.latest_tag)
  end)

  t.it("dashboard tag queries read the plugin's own tags", function()
    local gitcmd = require("dash_paq.dashboard.analysis.gitcmd")
    local tags
    gitcmd.all_tags(path, function(result)
      tags = result
    end)
    t.wait_until(function()
      return tags ~= nil
    end, 5000, "tag listing never answered")
    t.assert.same({ "v1.2.3" }, tags)
    local head =
      vim.trim(vim.fn.system({ "git", "-C", plug.work, "--git-dir", plug.work .. "/.git", "rev-parse", "HEAD" }))
    t.assert.equals("v1.2.3", gitcmd.tag_on_revision(path, head))
  end)

  t.it("the row refresh pipeline resolves the plugin's own status", function()
    local result
    require("dash_paq.dashboard.report").run_refresh_pipeline({ "envplug" }, false, function(r)
      result = r
    end, function() end)
    t.wait_until(function()
      return result ~= nil
    end, 5000, "pipeline result")
    t.assert.equals("same", result.status)
  end)

  t.it("dev worktree listing reads the checkout's own worktrees", function()
    local worktrees = require("dash_paq.loader.dev").list_worktrees(plug.work)
    t.assert.equals(1, #worktrees)
    t.assert.equals(require("dash_paq.fs").real_path(plug.work), worktrees[1].path)
  end)
end)

t.finish()
