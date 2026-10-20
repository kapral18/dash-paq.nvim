local t = require("runner")
local fixture = require("support.gitfixture")
local remote = fixture.new_remote("flags")
local v1 = fixture.commit(remote, "fix: v1", { ["README.md"] = "v1" })
fixture.tag(remote, "v1.0.0")
fixture.tag(remote, "20261019")
local v2 = fixture.commit(remote, "fix: v2", { ["README.md"] = "v2" })
fixture.tag(remote, "v2.0.0")
fixture.run({ "git", "-C", remote.work, "-c", "tag.gpgsign=false", "tag", v2:sub(1, 8), v1 })
fixture.push(remote)
fixture.commit_on_branch(remote, "release/2.x", "fix: branch", {})
fixture.push(remote, "release/2.x")
require("dash_paq").setup({
  dashboard = { refresh_on_open = false },
  version_policy = false,
  spec = {
    { src = remote.src, name = "dated", version = "20261019" },
    { src = remote.src, name = "qualified", version = "refs/tags/v2.0.0" },
    { src = remote.src, name = "shadowed", version = v2:sub(1, 8) },
    { src = remote.src, name = "pinned", version = "v2.0.0" },
    { src = remote.src, name = "digits", branch = "release/2.x" },
    { src = remote.src, name = "starred", version = "*" },
    { src = remote.src, name = "override", version = "*", branch = "main" },
  },
})
local state = require("dash_paq.dashboard.state")
local version = require("dash_paq.dashboard.analysis.version")
local path = vim.pack.get({ "pinned" }, { info = false })[1].path
fixture.run({ "git", "-C", path, "checkout", "--detach", v1 })
local callbacks = 0
version.refresh_version_flags_async(function()
  callbacks = callbacks + 1
end)
version.refresh_version_flags_async(function()
  callbacks = callbacks + 1
end)
t.wait_until(function()
  return state.version_flags_scanned
end, 5000, "version scan incomplete")

t.describe("WHEN version flags are computed from an installed checkout", function()
  t.it("SHOULD recognize a real branch containing digits", function()
    t.assert.falsy(state.version_flags_cache.digits.drift)
  end)

  t.it("SHOULD inspect disk HEAD after an external checkout", function()
    t.assert.truthy(state.version_flags_cache.pinned.drift)
  end)

  t.it("SHOULD notify every caller waiting for the same scan", function()
    t.assert.equals(2, callbacks)
  end)

  t.it("SHOULD derive star warnings from the winning version", function()
    t.assert.falsy(state.declared_versions_cache.override.star)
  end)

  t.it("SHOULD recognize a date tag at the current checkout", function()
    t.assert.falsy(state.version_flags_cache.dated.drift)
  end)

  t.it("SHOULD recognize a fully qualified tag at the current checkout", function()
    t.assert.falsy(state.version_flags_cache.qualified.drift)
  end)

  t.it("SHOULD detect drift when a tag shadows the checked-out commit prefix", function()
    local shadow_path = vim.pack.get({ "shadowed" }, { info = false })[1].path
    fixture.run({ "git", "-C", shadow_path, "checkout", "--detach", v2 })
    state.invalidate_version_flags()
    local done = false
    version.refresh_version_flags_async(function()
      done = true
    end)
    t.wait_until(function()
      return done
    end, 5000, "shadow tag scan incomplete")
    local drift = state.version_flags_cache.shadowed.drift
    vim.pack.update({ "shadowed" }, { offline = true, force = true })
    t.assert.equals(v1, fixture.run({ "git", "-C", shadow_path, "rev-parse", "HEAD" }))
    t.assert.truthy(drift)
  end)
end)

t.describe("WHEN an online refresh fetches a new prerelease tag", function()
  t.it("SHOULD recompute risky pins without restarting", function()
    fixture.tag(remote, "v9.9.9-experimental+build")
    fixture.push(remote, "release/2.x")
    local view = require("dash_paq.dashboard.ui.view")
    local report = require("dash_paq.dashboard.report")
    local refresh = require("dash_paq.dashboard.ui.refresh")
    local ctx = view.new_context({
      bufnr = vim.api.nvim_create_buf(false, true),
      rows = report.collect_dashboard_rows(),
      selected = {},
      filter_mode = "all",
      sort_mode = "status",
    })
    refresh.refresh(ctx, true)
    t.wait_until(function()
      return not ctx.online_check_running
    end, 5000, "tag refresh incomplete")
    t.assert.truthy(report.collect_dashboard_row("starred").is_risky_pin)
    t.assert.falsy(report.collect_dashboard_row("override").is_risky_pin)
  end)
end)

t.describe("WHEN a native update or sync changes version evidence", function()
  t.it("SHOULD discard drift flags after a native checkout", function()
    vim.pack.update({ "pinned" }, { offline = true, force = true })
    local done = false
    version.refresh_version_flags_async(function()
      done = true
    end)
    t.wait_until(function()
      return done
    end, 5000, "native checkout scan incomplete")
    t.assert.falsy(state.version_flags_cache.pinned.drift)
  end)

  t.it("SHOULD discard tag caches after sync fetches a newer stable release", function()
    fixture.tag(remote, "v10.0.0")
    fixture.push(remote, "release/2.x")
    vim.cmd("DashPaq sync")
    local done = false
    version.refresh_version_flags_async(function()
      done = true
    end)
    t.wait_until(function()
      return done
    end, 5000, "sync tag scan incomplete")
    t.assert.falsy(state.version_flags_cache.starred.risky)
  end)
end)

t.describe("WHEN a local branch shares the declared tag name", function()
  t.it("SHOULD detect tag drift just as native version resolution does", function()
    fixture.run({ "git", "-C", path, "checkout", "--detach", v1 })
    fixture.run({ "git", "-C", path, "branch", "v2.0.0", v1 })
    state.invalidate_version_flags()
    local done = false
    version.refresh_version_flags_async(function()
      done = true
    end)
    t.wait_until(function()
      return done
    end, 5000, "branch collision scan incomplete")
    t.assert.truthy(state.version_flags_cache.pinned.drift)
    vim.pack.update({ "pinned" }, { offline = true, force = true })
    t.assert.equals(
      fixture.run({ "git", "-C", path, "rev-list", "-1", "refs/tags/v2.0.0" }),
      fixture.run({ "git", "-C", path, "rev-parse", "HEAD" })
    )
  end)
end)

t.describe("WHEN a tag query is invalidated during its Git wait", function()
  t.it("SHOULD leave the replacement cache free of the old result", function()
    local git = require("dash_paq.git")
    local tags = require("dash_paq.dashboard.analysis.gitcmd")
    tags.invalidate_tags()
    local original = git.run
    local interrupted = false
    git.run = function(args, opts, callback)
      local job = original(args, opts, callback)
      if not interrupted and args[3] == "tag" and args[4] == "--points-at" then
        interrupted = true
        return {
          wait = function(_, timeout)
            local result = job:wait(timeout)
            fixture.run({ "git", "-C", path, "tag", "v20.0.0", v1 })
            tags.invalidate_tags()
            return result
          end,
        }
      end
      return job
    end
    local ok, before = pcall(tags.tag_on_revision, path, v1)
    git.run = original
    t.assert.truthy(ok, before)
    t.assert.equals("v1.0.0", before)
    t.assert.equals("v20.0.0", tags.tag_on_revision(path, v1))
  end)
end)

t.describe("WHEN a native checkout invalidates the final plugin during a flag scan", function()
  t.it("SHOULD restart the scan before notifying its subscribers", function()
    local script = vim.fn.tempname() .. ".lua"
    vim.fn.writefile(
      vim.split(
        [[
local t = require("runner")
local fixture = require("support.gitfixture")
local remote = fixture.new_remote("generation")
local old = fixture.commit(remote, "fix: old", { ["README.md"] = "old" })
fixture.tag(remote, "v1.0.0")
fixture.commit(remote, "fix: new", { ["README.md"] = "new" })
fixture.tag(remote, "v2.0.0")
fixture.push(remote)
require("dash_paq").setup({ spec = {{src=remote.src,name="generation",version="v2.0.0"}}, dashboard={refresh_on_open=false}, version_policy=false })
local path = vim.pack.get({"generation"}, {info=false})[1].path
fixture.run({"git", "-C", path, "checkout", "--detach", old})
local state = require("dash_paq.dashboard.state")
local version = require("dash_paq.dashboard.analysis.version")
local git = require("dash_paq.git")
local original = git.run
local interrupted = false
-- :wait() pumps events; a native checkout can finish before it returns.
git.run = function(args, opts, callback)
  local job = original(args, opts, callback)
  if not interrupted and args[3] == "rev-parse" and args[4] == "HEAD" then
    interrupted = true
    return {wait=function(_, timeout)
      local result = job:wait(timeout)
      vim.pack.update({"generation"}, {offline=true,force=true})
      return result
    end}
  end
  return job
end
local callbacks = 0
version.refresh_version_flags_async(function() callbacks = callbacks + 1 end)
version.refresh_version_flags_async(function() callbacks = callbacks + 1 end)
t.wait_until(function() return callbacks > 0 end, 5000, "scan did not finish")
git.run = original
assert(callbacks == 2, "scan lost a subscriber")
assert(not state.version_flags_cache.generation.drift, "stale scan overwrote newer invalidation")
]],
        "\n"
      ),
      script
    )
    local result = vim
      .system(
        { vim.v.progpath, "--headless", "-u", DASH_PAQ_TEST_ROOT .. "/tests/minimal_init.lua", "-l", script },
        { text = true }
      )
      :wait(10000)
    t.assert.equals(0, result.code, result.stderr)
  end)
end)

t.finish()
