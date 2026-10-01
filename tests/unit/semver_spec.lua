local t = require("runner")
local semver = require("dash_paq.semver")

t.describe("parsing a release tag", function()
  t.it("accepts a strict MAJOR.MINOR.PATCH tag with a leading v", function()
    local v = semver.parse_release_tag("v1.2.3")
    t.assert.truthy(v ~= nil)
    t.assert.equals(1, v.major)
    t.assert.equals(2, v.minor)
    t.assert.equals(3, v.patch)
  end)

  t.it("rejects a two-part tag like nvim-0.6 (strict parsing)", function()
    t.assert.is_nil(semver.parse_release_tag("nvim-0.6"))
  end)

  t.it("accepts a full triplet with a prerelease suffix", function()
    t.assert.truthy(semver.parse_release_tag("v0.2.2-rc.1") ~= nil)
  end)

  t.it("rejects a non-version string", function()
    t.assert.is_nil(semver.parse_release_tag("nerd-v2-compat"))
  end)

  t.it("rejects nil/non-string/empty input", function()
    t.assert.is_nil(semver.parse_release_tag(nil))
    t.assert.is_nil(semver.parse_release_tag(42))
    t.assert.is_nil(semver.parse_release_tag(""))
  end)
end)

t.describe("extracting semver components", function()
  t.it("reads the major version tolerant of a leading v", function()
    t.assert.equals(1, semver.semver_major("v1.2.3"))
    t.assert.equals(2, semver.semver_major("2.0"))
  end)

  t.it("coerces a two-part version to a triplet with patch 0", function()
    t.assert.same({ major = 0, minor = 7, patch = 0 }, semver.semver_triplet("0.7"))
  end)

  t.it("coerces a bare major to a triplet of zeros", function()
    t.assert.same({ major = 2, minor = 0, patch = 0 }, semver.semver_triplet("v2"))
  end)

  t.it("returns nil for an unparsable version", function()
    t.assert.is_nil(semver.semver_triplet("not-a-version"))
  end)
end)

t.describe("classifying an upgrade delta", function()
  t.it("classifies a major bump", function()
    t.assert.equals("major", semver.semver_delta("v1.2.3", "v2.0.0"))
  end)

  t.it("classifies a minor bump", function()
    t.assert.equals("minor", semver.semver_delta("v1.2.3", "v1.3.0"))
  end)

  t.it("classifies a patch bump", function()
    t.assert.equals("patch", semver.semver_delta("v1.2.3", "v1.2.4"))
  end)

  t.it("classifies an unchanged version as same", function()
    t.assert.equals("same", semver.semver_delta("v1.2.3", "v1.2.3"))
  end)

  t.it("returns nil when either side fails to parse", function()
    t.assert.is_nil(semver.semver_delta("garbage", "v1.2.3"))
    t.assert.is_nil(semver.semver_delta("v1.2.3", nil))
  end)
end)

t.finish()
