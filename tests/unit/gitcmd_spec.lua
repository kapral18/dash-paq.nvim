-- gitcmd's tag tie-break: semver comparison, not lexical order (which ranks "v1.9.0" above "v1.10.0").
local t = require("runner")
local gitfixture = require("support.gitfixture")
local gitcmd = require("dash_paq.dashboard.analysis.gitcmd")

t.describe("two release tags point at the same revision (tag tie-break)", function()
  local remote = gitfixture.new_remote("tietest")
  gitfixture.commit(remote, "feat: initial", { ["a.txt"] = "1" })
  gitfixture.tag(remote, "v1.9.0")
  gitfixture.tag(remote, "v1.10.0")
  local head = vim.system({ "git", "-C", remote.work, "rev-parse", "HEAD" }, { text = true }):wait().stdout

  t.it("picks the semver-greatest tag (v1.10.0), not the lexically-greatest (v1.9.0)", function()
    local winner = gitcmd.tag_on_revision(remote.work, vim.trim(head))
    t.assert.equals("v1.10.0", winner)
  end)
end)

t.describe("three tags mix release and non-release shapes on the same revision", function()
  -- A non-release tag ("1.2") must never win over a real MAJOR.MINOR.PATCH tag, and the comparator must stay
  -- a valid strict weak order across all three (a naive fallback-to-string-order rule isn't transitive here).
  local remote = gitfixture.new_remote("mixedtags")
  gitfixture.commit(remote, "feat: initial", { ["a.txt"] = "1" })
  gitfixture.tag(remote, "1.10.0")
  gitfixture.tag(remote, "1.9.0")
  gitfixture.tag(remote, "1.2")
  local head = vim.trim(vim.system({ "git", "-C", remote.work, "rev-parse", "HEAD" }, { text = true }):wait().stdout)

  t.it("picks the release-shaped semver-greatest tag (1.10.0), never the non-release '1.2'", function()
    t.assert.equals("1.10.0", gitcmd.tag_on_revision(remote.work, head))
  end)
end)

t.describe("listing tags on a revision", function()
  local remote = gitfixture.new_remote("tagsontag")
  gitfixture.commit(remote, "feat: initial", { ["a.txt"] = "1" })
  gitfixture.tag(remote, "v1.0.0")
  local head = vim.trim(vim.system({ "git", "-C", remote.work, "rev-parse", "HEAD" }, { text = true }):wait().stdout)

  t.it("returns the tags pointing at that revision", function()
    t.assert.same({ "v1.0.0" }, gitcmd.tags_on_revision(remote.work, head))
  end)

  t.it("returns an empty list for an unknown path", function()
    t.assert.same({}, gitcmd.tags_on_revision("", head))
  end)
end)

t.describe("listing all tags in a repo", function()
  local remote = gitfixture.new_remote("alltags")
  gitfixture.commit(remote, "feat: initial", { ["a.txt"] = "1" })
  gitfixture.tag(remote, "v1.0.0")
  gitfixture.commit(remote, "feat: two", { ["b.txt"] = "2" })
  gitfixture.tag(remote, "v2.0.0")

  t.it("lists every tag in the repo, sorted newest-version-first", function()
    t.assert.same({ "v2.0.0", "v1.0.0" }, gitcmd.all_tags(remote.work))
  end)
end)

t.describe("reading commit messages between two revisions", function()
  local remote = gitfixture.new_remote("logrange")
  local before = gitfixture.commit(remote, "feat: initial", { ["a.txt"] = "1" })
  local after = gitfixture.commit(remote, "feat: add thing\n\nBREAKING CHANGE: yes", { ["b.txt"] = "2" })

  t.it("returns the concatenated subject+body text for the range", function()
    local text = gitcmd.commit_messages_between(remote.work, before, after)
    t.assert.match("feat: add thing", text)
    t.assert.match("BREAKING CHANGE", text)
  end)

  t.it("returns per-commit hash/message records for the range", function()
    local records = gitcmd.commit_records_between(remote.work, before, after)
    t.assert.equals(1, #records)
    t.assert.match("feat: add thing", records[1].message)
    t.assert.truthy(#records[1].hash >= 7)
  end)

  t.it("returns nil for missing path/rev arguments", function()
    t.assert.is_nil(gitcmd.commit_messages_between("", before, after))
    t.assert.is_nil(gitcmd.commit_records_between(remote.work, "", after))
  end)

  t.it("rebuilds vim.pack-update-report-shaped 'hash │ subject' pending-updates text", function()
    local text = gitcmd.pending_updates_between(remote.work, before, after)
    -- Matches popups.lua's pending_line_hash shape: short hex hash, " │ ", subject.
    t.assert.match("^%x%x%x%x%x%x%x+ │ feat: add thing$", text)
  end)

  t.it("returns nil for missing path/rev arguments (pending updates)", function()
    t.assert.is_nil(gitcmd.pending_updates_between("", before, after))
  end)
end)

t.describe("gitcmd.prefetch_range fills caches so the sync calls spawn nothing", function()
  local remote = gitfixture.new_remote("prefetchrange")
  local before = gitfixture.commit(remote, "feat: initial", { ["a.txt"] = "1" })
  gitfixture.tag(remote, "v1.0.0")
  local after = gitfixture.commit(remote, "feat: add thing\n\nBREAKING CHANGE: yes", { ["b.txt"] = "2" })
  gitfixture.tag(remote, "v2.0.0")

  -- Independent reference values from a fresh clone: its cache keys (keyed by
  -- path) are guaranteed cold, so these calls prove what the SYNC functions
  -- would produce on their own, for comparison against the prefetched path.
  local mirror = gitfixture.tmp_dir("prefetchrange-mirror")
  vim.fn.delete(mirror, "rf")
  gitfixture.run({ "git", "clone", "--quiet", remote.work, mirror })
  local expected_before_tag = gitcmd.tag_on_revision(mirror, before)
  local expected_after_tag = gitcmd.tag_on_revision(mirror, after)
  local expected_messages = gitcmd.commit_messages_between(mirror, before, after)
  local expected_pending = gitcmd.pending_updates_between(mirror, before, after)

  local done_count = 0
  gitcmd.prefetch_range(remote.work, before, after, function()
    done_count = done_count + 1
  end)
  t.wait_until(function()
    return done_count > 0
  end, 5000, "prefetch_range's done was never called")

  t.it("calls done exactly once", function()
    -- Give any spurious extra completion a chance to land before asserting.
    vim.wait(50, function()
      return false
    end)
    t.assert.equals(1, done_count)
  end)

  local system_calls = 0
  local orig_system = vim.system
  vim.system = function(...)
    system_calls = system_calls + 1
    return orig_system(...)
  end

  local sync_before_tag = gitcmd.tag_on_revision(remote.work, before)
  local sync_after_tag = gitcmd.tag_on_revision(remote.work, after)
  local sync_messages = gitcmd.commit_messages_between(remote.work, before, after)
  local sync_pending = gitcmd.pending_updates_between(remote.work, before, after)

  vim.system = orig_system

  t.it("spawns no git process for the sync calls once prefetched (pure cache hits)", function()
    t.assert.equals(0, system_calls)
  end)

  t.it("sync results equal the values a cold sync-only run produces", function()
    t.assert.equals(expected_before_tag, sync_before_tag)
    t.assert.equals(expected_after_tag, sync_after_tag)
    t.assert.equals(expected_messages, sync_messages)
    -- Not a strict string comparison against `expected_pending`: git's `%h`
    -- abbreviation length is derived from the repo's total object count,
    -- which an incremental fetch/clone can grow differently than a single
    -- fresh clone even for the identical commit. Shape + subject is what
    -- matters here; hash uniqueness itself is covered by the "hash/message
    -- records" describe block above.
    t.assert.match("^%x%x%x%x%x%x%x+ │ feat: add thing$", sync_pending or "")
    t.assert.truthy(expected_pending ~= nil)
  end)

  t.it("picked the semver-greatest tag at each revision (parity with tag_on_revision's own logic)", function()
    t.assert.equals("v1.0.0", sync_before_tag)
    t.assert.equals("v2.0.0", sync_after_tag)
  end)
end)

t.describe("gitcmd.prefetch_range on a repo with no tags", function()
  local remote = gitfixture.new_remote("prefetchnotags")
  local before = gitfixture.commit(remote, "feat: initial", { ["a.txt"] = "1" })
  local after = gitfixture.commit(remote, "fix: bump", { ["b.txt"] = "2" })

  local done_count = 0
  gitcmd.prefetch_range(remote.work, before, after, function()
    done_count = done_count + 1
  end)
  t.wait_until(function()
    return done_count > 0
  end, 5000, "prefetch_range's done was never called")

  t.it("caches nil for the missing tags, matching the sync path's `false`-on-empty shape", function()
    t.assert.is_nil(gitcmd.tag_on_revision(remote.work, before))
    t.assert.is_nil(gitcmd.tag_on_revision(remote.work, after))
  end)

  t.it("still prefetches commit messages/pending updates", function()
    t.assert.match("fix: bump", gitcmd.commit_messages_between(remote.work, before, after))
    t.assert.match("fix: bump", gitcmd.pending_updates_between(remote.work, before, after))
  end)
end)

t.describe("gitcmd.prefetch_range on a failing path", function()
  local bogus_path = "/nonexistent/dash-paq-prefetch-path"

  local done_count = 0
  gitcmd.prefetch_range(
    bogus_path,
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "cafefeedcafefeedcafefeedcafefeedcafefeed",
    function()
      done_count = done_count + 1
    end
  )

  t.it("still calls done exactly once, caching `false`/nil like the sync path on a git failure", function()
    t.wait_until(function()
      return done_count > 0
    end, 5000, "prefetch_range's done was never called for a failing path")
    vim.wait(50, function()
      return false
    end)
    t.assert.equals(1, done_count)
    t.assert.is_nil(gitcmd.tag_on_revision(bogus_path, "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"))
    t.assert.is_nil(
      gitcmd.commit_messages_between(
        bogus_path,
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        "cafefeedcafefeedcafefeedcafefeedcafefeed"
      )
    )
  end)
end)

t.describe("gitcmd.prefetch_range with no revisions to prefetch", function()
  local remote = gitfixture.new_remote("prefetchnorevs")
  gitfixture.commit(remote, "feat: initial", { ["a.txt"] = "1" })

  local done_count = 0
  gitcmd.prefetch_range(remote.work, nil, nil, function()
    done_count = done_count + 1
  end)

  t.it("still calls done exactly once with no queries queued", function()
    t.wait_until(function()
      return done_count > 0
    end, 5000, "prefetch_range's done was never called")
    t.assert.equals(1, done_count)
  end)
end)

t.finish()
