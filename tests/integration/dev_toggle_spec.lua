-- Dev-toggle resolution (container detection, saved-choice overrides,
-- stale/drifted choices) and the dashboard `L` toggle (dev.json writes,
-- restart stubbed, never actually run).
local t = require("runner")
local dirfixture = require("support.dirfixture")
local gitfixture = require("support.gitfixture")
local dev = require("dash_paq.loader.dev")

_G.DASH_PAQ_TEST_LOG = {}

local function marker_lua(marker)
  return dirfixture.marker_plugin_files(marker)["plugin/init.lua"]
end

local function write_marker(dir, marker)
  vim.fn.mkdir(vim.fs.joinpath(dir, "plugin"), "p")
  vim.fn.writefile(vim.split(marker_lua(marker), "\n"), vim.fs.joinpath(dir, "plugin", "init.lua"))
end

local function realpath(path)
  return vim.uv.fs_realpath(path) or path
end

local dev_root = dirfixture.tmp_dir("dev-toggle-root")

-- Scenario A: a string `dev` base that is a *container* (no .git of its
-- own, one git child) with no saved choice -> resolves to the main worktree.
local container_base = vim.fs.joinpath(dev_root, "containerplug-base")
local container_child = vim.fs.joinpath(container_base, "main-worktree")
write_marker(container_child, "containerplug-loaded")
do
  local result = vim
    .system({ "git", "init", "--quiet", "--initial-branch=main", container_child }, { text = true })
    :wait()
  assert(result.code == 0, "git init failed: " .. tostring(result.stderr))
end

-- Scenario B: a string `dev` base that is a git worktree root with a second,
-- linked worktree on another branch; a saved path choice picks that other
-- worktree over the (default) main one. `choiceplug` also carries a decoy
-- `src` so it has 3 dev-toggle options later (upstream + 2 worktrees).
local choice_repo = gitfixture.new_remote("choiceplug")
write_marker(choice_repo.work, "choiceplug-main-loaded")
gitfixture.commit(choice_repo, "feat: main content", {})
gitfixture.commit_on_branch(choice_repo, "other", "feat: other content", {})
write_marker(choice_repo.work, "choiceplug-other-loaded")
gitfixture.commit(choice_repo, "feat: other content v2", {})
gitfixture.checkout(choice_repo, "main")
local choice_other_dir = vim.fs.joinpath(dev_root, "choiceplug-other-wt")
gitfixture.add_worktree(choice_repo, choice_other_dir, "other")

-- Scenario C: a real upstream `src` plus a dev-capable base; a saved
-- "upstream" choice must load the vim.pack clone, never the dev dir.
local upstream_remote = gitfixture.new_remote("upstreamplug")
gitfixture.commit(upstream_remote, "feat: initial", { ["plugin/init.lua"] = marker_lua("upstreamplug-src-loaded") })
gitfixture.push(upstream_remote)
local upstream_dev_dir = dirfixture.new("upstreamplug-dev", {})
write_marker(upstream_dev_dir, "upstreamplug-dev-loaded")

-- Scenario D: a saved choice pointing at a path that no longer exists ->
-- ignored (with a warning), falling back to the default (its own base).
-- Carries a decoy `src` too, so it also has 2 dev-toggle options later
-- (upstream + its own base dir) for the flip-toggle coverage below.
local badpath_dev_dir = dirfixture.new("badpathplug-dev", {})
write_marker(badpath_dev_dir, "badpathplug-loaded")

-- Scenario E: a saved "upstream" choice for an entry with no `src`
-- at all has nothing to fall back to, so it must resolve to the default
-- dev dir instead (with a stale-choice warning), never disable the entry.
local noupstream_dev_dir = dirfixture.new("noupstreamplug-dev", {})
write_marker(noupstream_dev_dir, "noupstreamplug-loaded")

-- Scenario F: a saved path choice that still exists but is no
-- longer among its base's *current* candidates (e.g. the spec's `dev` base
-- moved elsewhere) must be ignored, not silently honored.
local drift_base = dirfixture.new("driftplug-base", {})
write_marker(drift_base, "driftplug-base-loaded")
local drift_unrelated = dirfixture.new("driftplug-unrelated", {})
write_marker(drift_unrelated, "driftplug-unrelated-loaded")

dev.save_choices({
  choiceplug = choice_other_dir,
  upstreamplug = "upstream",
  badpathplug = vim.fs.joinpath(dev_root, "no-such-saved-path-xyz"),
  noupstreamplug = "upstream",
  driftplug = drift_unrelated,
})

local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  notified[#notified + 1] = { msg = msg, level = level }
  return orig_notify(msg, level, opts)
end

require("dash_paq").setup({
  spec = {
    { name = "containerplug", dev = container_base },
    { src = "https://example.invalid/owner/choiceplug.git", name = "choiceplug", dev = choice_repo.work },
    { src = upstream_remote.src, name = "upstreamplug", dev = upstream_dev_dir },
    { src = "https://example.invalid/owner/badpathplug.git", name = "badpathplug", dev = badpath_dev_dir },
    { name = "noupstreamplug", dev = noupstream_dev_dir },
    { name = "driftplug", dev = drift_base },
  },
  dashboard = true,
  version_policy = false,
  dev = { path = dev_root, patterns = {}, fallback = true },
})

-- The stale-choice WARN notify is scheduled (`vim.schedule`), not
-- synchronous; pump the loop until it (and any other startup notify) lands.
t.wait_until(function()
  for _, entry in ipairs(notified) do
    if entry.level == vim.log.levels.WARN then
      return true
    end
  end
  return false
end, 5000, "expected a stale dev-choice WARN notify")
vim.notify = orig_notify

local state = require("dash_paq.dashboard.state")

t.describe("a string `dev` base that is a container, no saved choice", function()
  t.it("loads the container's main worktree, not the container dir itself", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "containerplug-loaded"))
  end)

  t.it("publishes the resolved main-worktree path to the dashboard", function()
    t.assert.equals(realpath(container_child), state.dev_plugin_paths_cache.containerplug)
  end)
end)

t.describe("a saved path choice selecting a specific worktree", function()
  t.it("loads the chosen worktree's content, not the main worktree's", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "choiceplug-other-loaded"))
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "choiceplug-main-loaded"))
  end)

  t.it("publishes the chosen worktree path to the dashboard", function()
    -- a saved choice is only honored once it's matched against the
    -- base's current (git-reported, already-realpath) candidates, so the
    -- published path is that normalized candidate path, not the raw
    -- fixture-constructed one.
    t.assert.equals(realpath(choice_other_dir), state.dev_plugin_paths_cache.choiceplug)
  end)
end)

t.describe('a saved "upstream" choice for a dev-capable entry with src', function()
  t.it("loads from the vim.pack clone, not the dev directory", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "upstreamplug-src-loaded"))
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "upstreamplug-dev-loaded"))
  end)

  t.it("was registered with vim.pack (proves it is not a dev entry)", function()
    local ok = pcall(vim.pack.get, { "upstreamplug" }, { info = false })
    t.assert.truthy(ok)
  end)

  t.it("is not in the active dev-paths cache", function()
    t.assert.is_nil(state.dev_plugin_paths_cache.upstreamplug)
  end)

  t.it("still shows up as dev-capable (so `L` can flip it back later)", function()
    t.assert.truthy(state.dev_capable_cache.upstreamplug ~= nil)
    t.assert.truthy(state.dev_capable_cache.upstreamplug.has_src)
  end)
end)

t.describe("a saved choice whose path no longer exists", function()
  t.it("falls back to the entry's own default dir instead", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "badpathplug-loaded"))
  end)

  t.it("warns once about the stale/invalid saved choice", function()
    local saw = false
    for _, entry in ipairs(notified) do
      if entry.level == vim.log.levels.WARN and tostring(entry.msg):find("badpathplug", 1, true) then
        saw = true
      end
    end
    t.assert.truthy(saw)
  end)
end)

-- The "upstream" choice requires `entry.src`; without it there is
-- nothing to fall back to, so the saved choice is treated as stale.
t.describe('a saved "upstream" choice for a dev-capable entry with no src', function()
  t.it("falls back to the entry's own default dev dir instead", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "noupstreamplug-loaded"))
  end)

  t.it("is not disabled and still shows up as dev-capable", function()
    t.assert.truthy(state.dev_capable_cache.noupstreamplug ~= nil)
    t.assert.falsy(state.dev_capable_cache.noupstreamplug.has_src)
  end)

  t.it("warns once about the stale/invalid saved choice", function()
    local saw = false
    for _, entry in ipairs(notified) do
      if entry.level == vim.log.levels.WARN and tostring(entry.msg):find("noupstreamplug", 1, true) then
        saw = true
      end
    end
    t.assert.truthy(saw)
  end)
end)

t.describe("a saved path choice that exists but has drifted off its base's candidates", function()
  t.it("loads the base's own default instead of the drifted saved path", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "driftplug-base-loaded"))
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "driftplug-unrelated-loaded"))
  end)

  t.it("warns once about the drifted saved choice", function()
    local saw = false
    for _, entry in ipairs(notified) do
      if entry.level == vim.log.levels.WARN and tostring(entry.msg):find("driftplug", 1, true) then
        saw = true
      end
    end
    t.assert.truthy(saw)
  end)
end)

t.describe("the dashboard `L` toggle (dash_paq.dashboard.ui.operations.toggle_dev)", function()
  local operations = require("dash_paq.dashboard.ui.operations")

  t.it("2 options: flips directly to the other one, writes dev.json, and restarts on confirm", function()
    local restarted = false
    local prompt = nil
    operations.toggle_dev(nil, { name = "badpathplug" }, {
      confirm = function(msg)
        prompt = msg
        return 1 -- "Yes"
      end,
      restart = function()
        restarted = true
      end,
    })
    t.assert.equals("upstream", dev.load_choices().badpathplug)
    t.assert.truthy(restarted)
    t.assert.truthy(prompt:find("badpathplug: switching from ", 1, true))
    t.assert.truthy(prompt:find(" to upstream.", 1, true))
  end)

  t.it("more than 2 options: opens vim.ui.select and applies the chosen option", function()
    local seen_options = nil
    local restarted = false
    operations.toggle_dev(nil, { name = "choiceplug" }, {
      select = function(options, _select_opts, on_choice)
        seen_options = options
        for _, option in ipairs(options) do
          if option.kind == "upstream" then
            on_choice(option)
            return
          end
        end
      end,
      confirm = function()
        return 2 -- "No": exercise the not-restarted path too.
      end,
      restart = function()
        restarted = true
      end,
    })
    t.assert.truthy(seen_options ~= nil and #seen_options == 3)
    t.assert.equals("upstream", dev.load_choices().choiceplug)
    t.assert.falsy(restarted)
  end)

  t.it("a non-dev-capable row warns instead of prompting", function()
    local warned = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN and tostring(msg):find("no dev checkout configured", 1, true) then
        warned = true
      end
    end
    operations.toggle_dev(nil, { name = "not-a-real-plugin" }, {})
    vim.notify = orig
    t.assert.truthy(warned)
  end)

  -- `upstreamplug` is currently active on its `src` (not in
  -- dev_plugin_paths_cache), so `active` is "upstream" and the 2-option
  -- flip must pick the dev dir, not (a no-op) itself.
  t.it("upstream -> dev flip: 2 options, flips to the dev checkout and saves its path", function()
    local restarted = false
    operations.toggle_dev(nil, { name = "upstreamplug" }, {
      confirm = function()
        return 1 -- "Yes"
      end,
      restart = function()
        restarted = true
      end,
    })
    t.assert.equals(realpath(upstream_dev_dir), dev.load_choices().upstreamplug)
    t.assert.truthy(restarted)
  end)

  t.it("dev -> upstream flip is refused when the clone lacks the active dev checkout's Lua modules", function()
    local state = require("dash_paq.dashboard.state")
    local stale_clone = dirfixture.new("upstreamplug-stale-clone", { ["lua/oldname/init.lua"] = "return {}" })
    dirfixture.write(upstream_dev_dir, "lua/newname/init.lua", "return {}")
    local before = dev.load_choices().upstreamplug
    local orig_get, orig_notify = vim.pack.get, vim.notify
    local prompted, warned = false, nil
    vim.pack.get = function()
      return { { path = stale_clone } }
    end
    vim.notify = function(msg)
      warned = msg
    end
    state.dev_plugin_paths_cache.upstreamplug = realpath(upstream_dev_dir)
    local ok, err = pcall(operations.toggle_dev, nil, { name = "upstreamplug" }, {
      confirm = function()
        prompted = true
        return 2
      end,
    })
    state.dev_plugin_paths_cache.upstreamplug = nil
    vim.pack.get, vim.notify = orig_get, orig_notify
    assert(ok, err)
    t.assert.equals(before, dev.load_choices().upstreamplug)
    t.assert.falsy(prompted)
    t.assert.truthy(warned:find("upstreamplug: not switching to upstream", 1, true))
  end)

  t.it("a failed dev.json write is reported with an ERROR and skips the restart prompt", function()
    local orig_save = dev.save_choices
    dev.save_choices = function()
      return false
    end
    local errored = false
    local restarted = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        errored = true
      end
    end
    operations.toggle_dev(nil, { name = "badpathplug" }, {
      confirm = function()
        return 1 -- "Yes"
      end,
      restart = function()
        restarted = true
      end,
    })
    vim.notify = orig
    dev.save_choices = orig_save
    t.assert.truthy(errored)
    t.assert.falsy(restarted)
  end)
end)

t.describe("the dashboard buffer's dev-toggle key", function()
  local view = require("dash_paq.dashboard.ui.view")
  local bufnr = vim.api.nvim_create_buf(false, true)
  local ctx = view.new_context({
    bufnr = bufnr,
    rows = {},
    selected = {},
    filter_mode = "all",
    sort_mode = "status",
    search_text = nil,
  })
  require("dash_paq.dashboard.ui.bindings").attach(ctx)

  local function buffer_map(lhs)
    return vim.api.nvim_buf_call(bufnr, function()
      local map = vim.fn.maparg(lhs, "n", false, true)
      return map.buffer == 1 and map or nil
    end)
  end

  t.it("is `L`", function()
    t.assert.truthy(buffer_map("L"))
  end)

  t.it("has no mapping for `D` (D reads as delete)", function()
    t.assert.is_nil(buffer_map("D"))
  end)
end)

t.finish()
