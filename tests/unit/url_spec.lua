local t = require("runner")
local url = require("pack_companion.dashboard.analysis.url")

t.describe("parsing source coordinates from a src string", function()
  t.it("parses a https .git URL", function()
    local host, owner, repo = url.parse_source_coordinates("https://github.com/kapral18/pack-companion.nvim.git")
    t.assert.equals("github.com", host)
    t.assert.equals("kapral18", owner)
    t.assert.equals("pack-companion.nvim", repo)
  end)

  t.it("parses a https URL without a .git suffix", function()
    local host, owner, repo = url.parse_source_coordinates("https://github.com/kapral18/pack-companion.nvim")
    t.assert.equals("github.com", host)
    t.assert.equals("pack-companion.nvim", repo)
  end)

  t.it("parses a git@ SSH URL", function()
    local host, owner, repo = url.parse_source_coordinates("git@codeberg.org:owner/repo.git")
    t.assert.equals("codeberg.org", host)
    t.assert.equals("owner", owner)
    t.assert.equals("repo", repo)
  end)

  t.it("parses a ssh:// URL", function()
    local host, owner, repo = url.parse_source_coordinates("ssh://git@example.com/owner/repo.git")
    t.assert.equals("example.com", host)
    t.assert.equals("repo", repo)
  end)

  t.it("returns nil for an unparsable source", function()
    t.assert.is_nil(url.parse_source_coordinates("gh:owner/repo"))
    t.assert.is_nil(url.parse_source_coordinates(nil))
    t.assert.is_nil(url.parse_source_coordinates(""))
  end)
end)

t.describe("deriving URLs against the built-in hosts", function()
  t.it("builds a github.com compare URL", function()
    t.assert.equals(
      "https://github.com/kapral18/repo/compare/aaa...bbb",
      url.source_to_compare_url("https://github.com/kapral18/repo.git", "aaa", "bbb")
    )
  end)

  t.it("builds a codeberg.org compare URL", function()
    t.assert.equals(
      "https://codeberg.org/kapral18/repo/compare/aaa...bbb",
      url.source_to_compare_url("https://codeberg.org/kapral18/repo.git", "aaa", "bbb")
    )
  end)

  t.it("builds a repo URL", function()
    t.assert.equals("https://github.com/kapral18/repo", url.source_to_repo_url("https://github.com/kapral18/repo.git"))
  end)

  t.it("builds a commit URL for a valid hex hash", function()
    t.assert.equals(
      "https://github.com/kapral18/repo/commit/abc1234",
      url.repo_to_commit_url("https://github.com/kapral18/repo", "abc1234")
    )
  end)

  t.it("rejects a non-hex 'hash' for a commit URL", function()
    t.assert.is_nil(url.repo_to_commit_url("https://github.com/kapral18/repo", "not-a-hash"))
  end)

  t.it("builds a bare repo URL even for a host with no compare/commit template", function()
    -- `source_to_repo_url` only needs host/owner/repo, not a configured
    -- template — only compare/commit URLs require one.
    t.assert.equals("https://gitlab.com/kapral18/repo", url.source_to_repo_url("https://gitlab.com/kapral18/repo.git"))
  end)

  t.it("returns nil for a compare URL on a host with no known template", function()
    t.assert.is_nil(url.source_to_compare_url("https://gitlab.com/kapral18/repo.git", "aaa", "bbb"))
  end)
end)

t.describe("opts.hosts configures a custom/additional git-forge host", function()
  t.it("derives URLs for the newly configured host", function()
    url.configure({ ["gitlab.com"] = { compare = "-/compare/%s...%s", commit = "-/commit/%s" } })
    t.assert.equals(
      "https://gitlab.com/kapral18/repo/-/compare/aaa...bbb",
      url.source_to_compare_url("https://gitlab.com/kapral18/repo.git", "aaa", "bbb")
    )
    t.assert.equals(
      "https://gitlab.com/kapral18/repo/-/commit/abc1234",
      url.repo_to_commit_url("https://gitlab.com/kapral18/repo", "abc1234")
    )
  end)

  t.it("keeps the built-in hosts available after configure()", function()
    t.assert.truthy(url.source_to_repo_url("https://github.com/kapral18/repo.git") ~= nil)
  end)

  t.it("lets configure() override a built-in host's template", function()
    url.configure({ ["github.com"] = { compare = "custom/%s/%s", commit = "custom/%s" } })
    t.assert.equals(
      "https://github.com/kapral18/repo/custom/aaa/bbb",
      url.source_to_compare_url("https://github.com/kapral18/repo.git", "aaa", "bbb")
    )
  end)
end)

t.finish()
