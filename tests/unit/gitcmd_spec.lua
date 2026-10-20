-- gitcmd's tag tie-break: semver comparison, not lexical order (which ranks "v1.9.0" above "v1.10.0").
local t = require("runner")
local gitfixture = require("support.gitfixture")
local gitcmd = require("dash_paq.dashboard.analysis.gitcmd")

local function count_git_calls(fn)
  local git = require("dash_paq.git")
  local original = git.run
  local count = 0
  git.run = function(...)
    count = count + 1
    return original(...)
  end
  local ok, err = pcall(fn)
  git.run = original
  assert(ok, err)
  return count
end

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

  local done_count = 0
  local prefetch_calls = count_git_calls(function()
    gitcmd.prefetch_range(remote.work, before, after, function()
      done_count = done_count + 1
    end)
    t.wait_until(function()
      return done_count > 0
    end, 5000, "prefetch_range's done was never called")
  end)

  t.it("SHOULD read both revision tags and the commit range in three Git queries", function()
    t.assert.equals(3, prefetch_calls)
  end)

  t.it("calls done exactly once", function()
    -- Give any spurious extra completion a chance to land before asserting.
    vim.wait(50, function()
      return false
    end)
    t.assert.equals(1, done_count)
  end)

  local sync_before_tag, sync_after_tag, sync_messages, sync_pending, sync_records
  local system_calls = count_git_calls(function()
    sync_before_tag = gitcmd.tag_on_revision(remote.work, before)
    sync_after_tag = gitcmd.tag_on_revision(remote.work, after)
    sync_messages = gitcmd.commit_messages_between(remote.work, before, after)
    sync_pending = gitcmd.pending_updates_between(remote.work, before, after)
    sync_records = gitcmd.commit_records_between(remote.work, before, after)
  end)

  t.it("spawns no git process for the sync calls once prefetched (pure cache hits)", function()
    t.assert.equals(0, system_calls)
  end)

  t.it("SHOULD preserve the commit subject and breaking footer", function()
    t.assert.equals("feat: add thing\nBREAKING CHANGE: yes", sync_messages)
    t.assert.match("^%x%x%x%x%x%x%x+ │ feat: add thing$", sync_pending)
    t.assert.equals(1, #sync_records)
    t.assert.equals("feat: add thing\nBREAKING CHANGE: yes", sync_records[1].message)
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

t.describe("WHEN a commit range is read synchronously through a symlink", function()
  t.it("SHOULD share one Git query across messages, pending rows, and commit records", function()
    local remote = gitfixture.new_remote("log-café")
    local before = gitfixture.commit(remote, "chore: initial", {})
    gitfixture.commit(remote, "docs: explain café", {})
    local after = gitfixture.commit(remote, "fix: café\n\nBREAKING CHANGE: new name", {})
    local link = remote.work .. "-link"
    assert(vim.uv.fs_symlink(remote.work, link))
    local messages, pending, records

    local calls = count_git_calls(function()
      pending = gitcmd.pending_updates_between(link, before, after)
      records = gitcmd.commit_records_between(link, before, after)
      messages = gitcmd.commit_messages_between(link, before, after)
    end)

    t.assert.equals(1, calls)
    t.assert.equals("fix: café\nBREAKING CHANGE: new name\n\ndocs: explain café", messages)
    t.assert.match("^%x%x%x%x%x%x%x+ │ fix: café\n%x%x%x%x%x%x%x+ │ docs: explain café$", pending)
    t.assert.equals(2, #records)
    t.assert.equals("fix: café\nBREAKING CHANGE: new name", records[1].message)
    t.assert.equals("docs: explain café", records[2].message)
  end)

  t.it("SHOULD share an empty range without inventing pending commits", function()
    local remote = gitfixture.new_remote("empty-log")
    local head = gitfixture.commit(remote, "chore: initial", {})
    local messages, pending, records

    local calls = count_git_calls(function()
      records = gitcmd.commit_records_between(remote.work, head, head)
      messages = gitcmd.commit_messages_between(remote.work, head, head)
      pending = gitcmd.pending_updates_between(remote.work, head, head)
    end)

    t.assert.equals(1, calls)
    t.assert.is_nil(records)
    t.assert.is_nil(messages)
    t.assert.is_nil(pending)
  end)
end)

t.describe("WHEN commit messages contain record separators", function()
  t.it("SHOULD preserve the complete message in every projection", function()
    local remote = gitfixture.new_remote("log-separators")
    local before = gitfixture.commit(remote, "chore: initial", {})
    local after = gitfixture.commit(remote, "fix: one\30two\31three\n\nBody\30with\31separators", {})

    local records = gitcmd.commit_records_between(remote.work, before, after)

    t.assert.equals(1, #records)
    t.assert.equals("fix: one\30two\31three\nBody\30with\31separators", records[1].message)
    t.assert.equals(
      "fix: one\30two\31three\nBody\30with\31separators",
      gitcmd.commit_messages_between(remote.work, before, after)
    )
    t.assert.match(
      "^%x%x%x%x%x%x%x+ │ fix: one\30two\31three$",
      gitcmd.pending_updates_between(remote.work, before, after)
    )
  end)
end)

t.describe("WHEN both prefetch endpoints are the same revision", function()
  t.it("SHOULD query its tags only once and settle an empty range", function()
    local remote = gitfixture.new_remote("prefetch-same")
    local head = gitfixture.commit(remote, "chore: initial", {})
    gitfixture.tag(remote, "v1.0.0")
    local done_count = 0

    local calls = count_git_calls(function()
      gitcmd.prefetch_range(remote.work, head, head, function()
        done_count = done_count + 1
      end)
      t.wait_until(function()
        return done_count > 0
      end)
    end)

    t.assert.equals(2, calls)
    t.assert.equals(1, done_count)
    t.assert.equals("v1.0.0", gitcmd.tag_on_revision(remote.work, head))
    t.assert.is_nil(gitcmd.pending_updates_between(remote.work, head, head))
  end)
end)

t.finish()
