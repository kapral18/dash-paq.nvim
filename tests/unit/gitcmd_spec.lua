-- gitcmd's tag tie-break: semver comparison, not lexical order (which ranks "v1.9.0" above "v1.10.0").
local t = require("runner")
local gitfixture = require("support.gitfixture")
local gitcmd = require("pack_companion.dashboard.analysis.gitcmd")

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

t.finish()
