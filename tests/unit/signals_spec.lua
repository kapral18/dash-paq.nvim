local t = require("runner")
local signals = require("dash_paq.dashboard.analysis.signals")

t.describe("classifying conventional-commit breaking markers", function()
  t.it("detects an uppercase BREAKING CHANGE footer", function()
    t.assert.truthy(signals.classify_commit_signals("feat: x\n\nBREAKING CHANGE: rewrote the api").has_breaking)
  end)

  t.it("detects an uppercase BREAKING-CHANGE footer", function()
    t.assert.truthy(signals.classify_commit_signals("fix: x\n\nBREAKING-CHANGE: nope").has_breaking)
  end)

  t.it("does not treat lowercase 'breaking change' prose as a marker", function()
    t.assert.falsy(signals.classify_commit_signals("fix: the plugin made a breaking change to output").has_breaking)
  end)

  t.it("detects a bang after the type/scope (feat!:)", function()
    t.assert.truthy(signals.classify_commit_signals("feat!: drop old api").has_breaking)
  end)

  t.it("detects a scoped bang (feat(api)!:)", function()
    t.assert.truthy(signals.classify_commit_signals("feat(api)!: drop old api").has_breaking)
  end)

  t.it("detects a 'breaking:' subject marker case-insensitively", function()
    t.assert.truthy(signals.classify_commit_signals("Breaking: dropped support").has_breaking)
  end)

  t.it("detects a 'break:' word-boundary marker", function()
    t.assert.truthy(signals.classify_commit_signals("break: old behavior removed").has_breaking)
  end)

  t.it("does not false-positive on a word merely containing 'break'", function()
    t.assert.falsy(signals.classify_commit_signals("fix: unbreakable retry loop").has_breaking)
  end)
end)

t.describe("classifying conventional-commit types", function()
  t.it("counts feat/fix/refactor/perf/docs/chore by type prefix", function()
    local summary =
      signals.classify_commit_signals("feat: a\nfix: b\nrefactor: c\nperf: d\ndocs: e\nchore: f\nfeat(scope): g")
    t.assert.equals(2, summary.feat)
    t.assert.equals(1, summary.fix)
    t.assert.equals(1, summary.refactor)
    t.assert.equals(1, summary.perf)
    t.assert.equals(1, summary.docs)
    t.assert.equals(1, summary.chore)
  end)

  t.it("detects a deprecation mention", function()
    t.assert.truthy(signals.classify_commit_signals("chore: mark old_fn as deprecated").has_deprecation)
  end)

  t.it("returns an all-zero/false summary for empty/nil input", function()
    local summary = signals.classify_commit_signals("")
    t.assert.falsy(summary.has_breaking)
    t.assert.equals(0, summary.feat)
    t.assert.same(summary, signals.classify_commit_signals(nil))
  end)
end)

t.describe("formatting a commit-signal summary", function()
  t.it("renders 'none' when nothing was detected", function()
    t.assert.equals("none", signals.format_commit_signals(signals.classify_commit_signals("")))
  end)

  t.it("renders breaking/deprecation before the counted types", function()
    local summary = signals.classify_commit_signals("feat!: x\n\ndeprecated: y\nfeat: z")
    local text = signals.format_commit_signals(summary)
    t.assert.match("^breaking", text)
    t.assert.match("feat:2", text)
  end)

  t.it("renders 'none' for a non-table input", function()
    t.assert.equals("none", signals.format_commit_signals(nil))
  end)
end)

t.finish()
