-- Unit coverage for loader/dev.lua: pure `git worktree list --porcelain`
-- parsing, base-dir classification/default resolution, and the dev.json
-- choices file's tolerant load/save.
local t = require("runner")
local dirfixture = require("support.dirfixture")
local dev = require("dash_paq.loader.dev")

t.describe("parsing `git worktree list --porcelain` output (pure, no I/O)", function()
  t.it("parses a normal branch worktree entry", function()
    local out = "worktree /repo\nHEAD abc123\nbranch refs/heads/main\n"
    local entries = dev.parse_worktree_porcelain(out)
    t.assert.equals(1, #entries)
    t.assert.equals("/repo", entries[1].path)
    t.assert.equals("abc123", entries[1].head)
    t.assert.equals("main", entries[1].branch)
    t.assert.falsy(entries[1].bare)
    t.assert.falsy(entries[1].detached)
  end)

  t.it("parses a detached-HEAD worktree entry", function()
    local out = "worktree /repo/wt-detached\nHEAD abc123\ndetached\n"
    local entries = dev.parse_worktree_porcelain(out)
    t.assert.equals(1, #entries)
    t.assert.truthy(entries[1].detached)
    t.assert.is_nil(entries[1].branch)
  end)

  t.it("parses a bare repository entry with no HEAD/branch", function()
    local out = "worktree /repo/bare.git\nbare\n"
    local entries = dev.parse_worktree_porcelain(out)
    t.assert.equals(1, #entries)
    t.assert.truthy(entries[1].bare)
  end)

  t.it("parses multiple blank-line-separated entries in order", function()
    local out = "worktree /repo\nHEAD abc123\nbranch refs/heads/main\n\n"
      .. "worktree /repo/wt-feature\nHEAD def456\nbranch refs/heads/feature\n"
    local entries = dev.parse_worktree_porcelain(out)
    t.assert.equals(2, #entries)
    t.assert.equals("/repo", entries[1].path)
    t.assert.equals("feature", entries[2].branch)
  end)

  t.it("returns an empty list for empty output", function()
    t.assert.same({}, dev.parse_worktree_porcelain(""))
    t.assert.same({}, dev.parse_worktree_porcelain(nil))
  end)
end)

t.describe("classifying and resolving the default dir for a dev base", function()
  t.it("missing: a base that does not exist on disk", function()
    local base = vim.fs.joinpath(dirfixture.tmp_dir("dev-missing"), "does-not-exist")
    local kind = dev.classify_base(base)
    t.assert.equals("missing", kind)
    t.assert.is_nil(dev.default_dir(base))
  end)

  t.it("plain: an existing non-git directory resolves to itself", function()
    local base = dirfixture.new("dev-plain", { ["plugin/init.lua"] = "-- marker" })
    local expected = vim.uv.fs_realpath(base) or base
    local kind = dev.classify_base(base)
    t.assert.equals("plain", kind)
    -- Loaded as spelled; only candidates (compared/stored) are realpath'd.
    t.assert.equals(base, dev.default_dir(base))
    local candidates = dev.candidates_for(base)
    t.assert.equals(1, #candidates)
    t.assert.equals(expected, candidates[1].path)
  end)

  t.it("worktree: a base with its own .git dir resolves to itself (no git shell-out needed)", function()
    local base = dirfixture.new("dev-worktree", { ["plugin/init.lua"] = "-- marker" })
    vim.fn.mkdir(vim.fs.joinpath(base, ".git"), "p")
    local kind = dev.classify_base(base)
    t.assert.equals("worktree", kind)
    t.assert.equals(base, dev.default_dir(base))
  end)

  t.it("worktree: a base with a .git *file* (linked worktree pointer) also counts", function()
    local base = dirfixture.new("dev-worktree-file", { ["plugin/init.lua"] = "-- marker" })
    vim.fn.writefile({ "gitdir: /somewhere/else" }, vim.fs.joinpath(base, ".git"))
    t.assert.equals("worktree", dev.classify_base(base))
  end)

  t.it("container: a base without .git whose child is a real git dir resolves to the main worktree", function()
    local base = dirfixture.tmp_dir("dev-container")
    local child = vim.fs.joinpath(base, "main-worktree")
    vim.fn.mkdir(vim.fs.joinpath(child, "plugin"), "p")
    vim.fn.writefile({ "-- marker" }, vim.fs.joinpath(child, "plugin", "init.lua"))
    local result = vim.system({ "git", "init", "--quiet", "--initial-branch=main", child }, { text = true }):wait()
    t.assert.equals(0, result.code, "git init failed: " .. tostring(result.stderr))

    -- `git worktree list` reports its own realpath (e.g. macOS resolves
    -- /tmp -> /private/tmp), so compare against that, not the raw fixture path.
    local expected = vim.uv.fs_realpath(child) or child

    local kind = dev.classify_base(base)
    t.assert.equals("container", kind)
    t.assert.equals(expected, dev.default_dir(base))

    local candidates = dev.candidates_for(base)
    t.assert.equals(1, #candidates)
    t.assert.equals(expected, candidates[1].path)
    t.assert.match("main", candidates[1].label)
  end)

  -- a `.bare`-backed worktree container (`base/.bare` + `base/.git` ->
  -- "gitdir: ./.bare"): `base` has a `.git` *file* but is not itself a
  -- checkout (git reports it as bare), unlike the linked-worktree-pointer
  -- case above, so it must classify as "container", not "worktree".
  t.it("container: a .bare-backed worktree layout (.git file resolves to a bare repo)", function()
    local base = dirfixture.tmp_dir("dev-bare-container")
    local seed = dirfixture.new("dev-bare-seed", { ["plugin/init.lua"] = "-- marker" })
    local function run(args)
      local result = vim.system(args, { text = true }):wait()
      assert(result.code == 0, table.concat(args, " ") .. ": " .. tostring(result.stderr))
      return result
    end

    local function run_seed(...)
      local args = {
        "git",
        "-C",
        seed,
        "-c",
        "user.name=dash-paq-tests",
        "-c",
        "user.email=tests@dash-paq.invalid",
        "-c",
        "commit.gpgsign=false",
      }
      for _, arg in ipairs({ ... }) do
        args[#args + 1] = arg
      end
      run(args)
    end

    run({ "git", "init", "--quiet", "--initial-branch=main", seed })
    run_seed("add", "-A")
    run_seed("commit", "--quiet", "-m", "feat: seed")

    local bare_dir = vim.fs.joinpath(base, ".bare")
    run({ "git", "clone", "--quiet", "--bare", seed, bare_dir })
    vim.fn.writefile({ "gitdir: ./.bare" }, vim.fs.joinpath(base, ".git"))
    run({ "git", "-C", base, "worktree", "add", "--quiet", "wt", "main" })

    local expected = vim.uv.fs_realpath(vim.fs.joinpath(base, "wt")) or vim.fs.joinpath(base, "wt")

    local kind = dev.classify_base(base)
    t.assert.equals("container", kind)
    t.assert.equals(expected, dev.default_dir(base))

    local candidates = dev.candidates_for(base)
    t.assert.equals(1, #candidates)
    t.assert.equals(expected, candidates[1].path)
  end)

  -- a caller's own `GIT_DIR`/`GIT_WORK_TREE` (bare-dotfiles setups,
  -- nvim spawned from a git process) must never redirect these git calls.
  t.it("container resolution ignores an inherited GIT_DIR/GIT_WORK_TREE", function()
    local base = dirfixture.tmp_dir("dev-container-envguard")
    local child = vim.fs.joinpath(base, "main-worktree")
    vim.fn.mkdir(vim.fs.joinpath(child, "plugin"), "p")
    vim.fn.writefile({ "-- marker" }, vim.fs.joinpath(child, "plugin", "init.lua"))
    local result = vim.system({ "git", "init", "--quiet", "--initial-branch=main", child }, { text = true }):wait()
    t.assert.equals(0, result.code, "git init failed: " .. tostring(result.stderr))
    local expected = vim.uv.fs_realpath(child) or child

    local prev_git_dir, had_git_dir = vim.env.GIT_DIR, vim.env.GIT_DIR ~= nil
    local prev_work_tree, had_work_tree = vim.env.GIT_WORK_TREE, vim.env.GIT_WORK_TREE ~= nil
    vim.env.GIT_DIR = "/nonexistent-bogus-gitdir/.git"
    vim.env.GIT_WORK_TREE = "/nonexistent-bogus-worktree"

    local ok, kind = pcall(dev.classify_base, base)
    local default_ok, default = pcall(dev.default_dir, base)

    vim.env.GIT_DIR = had_git_dir and prev_git_dir or nil
    vim.env.GIT_WORK_TREE = had_work_tree and prev_work_tree or nil

    t.assert.truthy(ok)
    t.assert.equals("container", kind)
    t.assert.truthy(default_ok)
    t.assert.equals(expected, default)
  end)
end)

t.describe("the dev.json saved-choices file (dev.load_choices / dev.save_choices)", function()
  t.it("returns an empty table when no file exists yet", function()
    t.assert.same({}, dev.load_choices())
  end)

  t.it("round-trips a saved choices map", function()
    t.assert.truthy(dev.save_choices({ myplug = "upstream", other = "/tmp/other-checkout" }))
    local loaded = dev.load_choices()
    t.assert.equals("upstream", loaded.myplug)
    t.assert.equals("/tmp/other-checkout", loaded.other)
  end)

  t.it("tolerates a corrupt choices file (returns empty, does not raise)", function()
    vim.fn.mkdir(vim.fs.dirname(dev.choices_path()), "p")
    vim.fn.writefile({ "{ not valid json" }, dev.choices_path())
    t.assert.same({}, dev.load_choices())
  end)
end)

t.describe("dev.toggle_target: where a toggle switches to", function()
  local base = dirfixture.new("toggle-target-base", dirfixture.marker_plugin_files("tt-base"))
  local other = dirfixture.new("toggle-target-other", dirfixture.marker_plugin_files("tt-other"))
  local not_plugin = dirfixture.new("toggle-target-notplugin", { ["README.md"] = "just docs" })

  t.it("goes to the dev checkout from upstream (saved choice 'upstream')", function()
    t.assert.equals(dev.normalize_path(base), dev.toggle_target(base, true, "upstream"))
  end)

  t.it("goes to upstream when nothing is saved and the base exists (the default is already dev)", function()
    t.assert.equals("upstream", dev.toggle_target(base, true, nil))
  end)

  t.it("goes to upstream from a saved path that is still a current candidate", function()
    t.assert.equals("upstream", dev.toggle_target(base, true, base))
  end)

  t.it("treats a stale saved path (no longer a candidate) as the default, so goes to upstream", function()
    t.assert.equals("upstream", dev.toggle_target(base, true, other))
  end)

  t.it("refuses to leave dev when there is no upstream src", function()
    local target, reason = dev.toggle_target(base, false, nil)
    t.assert.is_nil(target)
    t.assert.truthy(reason:find("no upstream"))
  end)

  t.it("refuses to enter dev when the base does not exist", function()
    local missing = base .. "-missing"
    local target, reason = dev.toggle_target(missing, true, "upstream")
    t.assert.is_nil(target)
    t.assert.truthy(reason:find("no dev checkout found"))
  end)

  t.it("refuses to enter dev when the base is not a plugin directory", function()
    local target, reason = dev.toggle_target(not_plugin, true, "upstream")
    t.assert.is_nil(target)
    t.assert.truthy(reason:find("not a plugin directory", 1, true))
  end)

  t.it("from a missing base with no saved choice there is nothing to toggle to either", function()
    local target = dev.toggle_target(base .. "-missing", true, nil)
    t.assert.is_nil(target)
  end)
end)

t.describe("dev.is_plugin_dir", function()
  t.it("accepts a directory with runtime content (lua/, plugin/, ...)", function()
    t.assert.truthy(dev.is_plugin_dir(dirfixture.new("ipd-plugin", dirfixture.marker_plugin_files("ipd"))))
    t.assert.truthy(dev.is_plugin_dir(dirfixture.new("ipd-lua", { ["lua/x/init.lua"] = "return {}" })))
    t.assert.truthy(dev.is_plugin_dir(dirfixture.new("ipd-colors", { ["colors/x.vim"] = "" })))
  end)

  t.it("rejects empty or unrelated directories, files, and non-paths", function()
    t.assert.falsy(dev.is_plugin_dir(dirfixture.new("ipd-empty", {})))
    t.assert.falsy(dev.is_plugin_dir(dirfixture.new("ipd-readme", { ["README.md"] = "x" })))
    t.assert.falsy(dev.is_plugin_dir("/nonexistent/dash-paq-test-path"))
    t.assert.falsy(dev.is_plugin_dir(nil))
    t.assert.falsy(dev.is_plugin_dir(""))
  end)
end)

t.finish()
