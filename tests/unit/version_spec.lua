local t = require("runner")
local version = require("pack_companion.dashboard.analysis.version")

t.describe("classifying a commit-hash-shaped string", function()
  t.it("accepts a 7+ char hex string", function()
    t.assert.truthy(version.is_commit_string("abc1234"))
    t.assert.truthy(version.is_commit_string("deadbeefdeadbeef"))
  end)

  t.it("rejects a short hex string", function()
    t.assert.falsy(version.is_commit_string("abc12"))
  end)

  t.it("rejects a branch/tag name", function()
    t.assert.falsy(version.is_commit_string("main"))
    t.assert.falsy(version.is_commit_string("v1.2.3"))
  end)
end)

t.describe("classifying a release-shaped tag (strict shape)", function()
  t.it("accepts vMAJOR.MINOR.PATCH", function()
    t.assert.truthy(version.is_release_tag("v1.2.3"))
    t.assert.truthy(version.is_release_tag("1.2.3"))
  end)

  t.it("rejects a two-part tag like nvim-0.6", function()
    t.assert.falsy(version.is_release_tag("nvim-0.6"))
  end)

  t.it("rejects a non-string", function()
    t.assert.falsy(version.is_release_tag(nil))
  end)
end)

t.describe("computing spec-vs-disk version drift", function()
  t.it("never flags drift for branch-tracking (declared = nil)", function()
    t.assert.falsy(version.compute_version_drift(nil, { rev = "abc", tags = {} }))
  end)

  t.it("flags drift when no on-disk tag satisfies a declared version range", function()
    local range = vim.version.range("^2.0.0")
    t.assert.truthy(version.compute_version_drift(range, { rev = "abc", tags = { "v1.0.0" } }))
  end)

  t.it("does not flag drift when an on-disk tag satisfies the declared range", function()
    local range = vim.version.range("^1.0.0")
    t.assert.falsy(version.compute_version_drift(range, { rev = "abc", tags = { "v1.5.0" } }))
  end)

  t.it("compares a declared commit against the checkout rev (prefix match)", function()
    t.assert.falsy(version.compute_version_drift("abc1234", { rev = "abc1234def", tags = {} }))
    t.assert.truthy(version.compute_version_drift("abc1234", { rev = "zzzzzzz", tags = {} }))
  end)

  t.it("does not flag drift for a plain branch name absent from tags", function()
    t.assert.falsy(version.compute_version_drift("main", { rev = "abc", tags = {} }))
  end)

  t.it("flags drift for a tag-shaped string absent from on-disk tags", function()
    t.assert.truthy(version.compute_version_drift("v1.2.3", { rev = "abc", tags = { "v1.0.0" } }))
  end)

  t.it("does not flag drift when the declared tag is present on disk", function()
    t.assert.falsy(version.compute_version_drift("v1.2.3", { rev = "abc", tags = { "v1.2.3" } }))
  end)
end)

t.describe("detecting a risky version = '*' pin", function()
  t.it("does not flag risky for {nvim-0.6, v0.2.2} under strict parsing", function()
    -- A lenient parse would rank nvim-0.6 above v0.2.2 (false positive); strict parsing rejects nvim-0.6, so
    -- `*`'s own pick already agrees with the intended release pick.
    t.assert.falsy(version.detect_risky_star_pin(true, { "nvim-0.6", "v0.2.2" }))
  end)

  t.it("flags risky when a non-release tag strict-outranks the greatest release tag", function()
    -- Guards against a tag that strict-parses higher than the release the user meant.
    t.assert.truthy(version.detect_risky_star_pin(true, { "v9.9.9-experimental+build", "v0.2.2" }))
  end)

  t.it("does not flag risky when is_star is false", function()
    t.assert.falsy(version.detect_risky_star_pin(false, { "nvim-0.6", "v0.2.2" }))
  end)

  t.it("does not flag risky when there are no release-shaped tags at all", function()
    t.assert.falsy(version.detect_risky_star_pin(true, { "nightly", "unstable" }))
  end)

  t.it("does not flag risky for an empty or nil tag list", function()
    t.assert.falsy(version.detect_risky_star_pin(true, {}))
    t.assert.falsy(version.detect_risky_star_pin(true, nil))
  end)
end)

t.describe("shortening a revision", function()
  t.it("takes the first 8 characters", function()
    t.assert.equals("abcdef12", version.short_rev("abcdef1234567890"))
  end)

  t.it("returns nil for nil/empty input", function()
    t.assert.is_nil(version.short_rev(nil))
    t.assert.is_nil(version.short_rev(""))
  end)
end)

t.finish()
