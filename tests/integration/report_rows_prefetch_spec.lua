-- Once the refresh pipeline resolves a row as "update", the breaking-change
-- inference inputs (tags, commit messages, pending log) are prefetched async
-- before the row callback runs, so collecting the row is a pure cache hit
-- (no per-row `:wait()` git call). Also covers the risk_reason-based skip
-- that avoids re-inferring an already-inferred rev pair on every collect.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local tagged = gitfixture.new_remote("tagged")
gitfixture.commit(tagged, "feat: initial", { ["README.md"] = "v1" })
gitfixture.tag(tagged, "v1.0.0")
gitfixture.push(tagged)

require("dash_paq").setup({
  spec = {
    { src = tagged.src, name = "tagged", version = "*" },
  },
  dashboard = true,
  version_policy = false,
})

-- A minor bump (new feature commit + a new release tag) after install: the
-- pipeline should resolve this as "update" and infer a non-breaking verdict.
gitfixture.commit(tagged, "feat: add feature", { ["feature.txt"] = "x" })
gitfixture.tag(tagged, "v1.1.0")
gitfixture.push(tagged)

local pipeline = require("dash_paq.dashboard.report.pipeline")
local report = require("dash_paq.dashboard.report")
local state = require("dash_paq.dashboard.state")
local gitcmd = require("dash_paq.dashboard.analysis.gitcmd")
local signals = require("dash_paq.dashboard.analysis.signals")

-- Independent reference values from a fresh clone of the bare remote: its
-- cache keys (keyed by path) are guaranteed cold, so these prove what the
-- sync-only inference would have produced on its own, for parity comparison.
local mirror = gitfixture.tmp_dir("tagged-mirror")
vim.fn.delete(mirror, "rf")
gitfixture.run({ "git", "clone", "--quiet", tagged.bare, mirror })

local pipeline_results = {}
local pipeline_done = false
pipeline.run(nil, true, function(result)
  pipeline_results[result.name] = result
end, function()
  pipeline_done = true
end)
t.wait_until(function()
  return pipeline_done
end, 10000, "pipeline.run did not finish")

t.describe("the refresh pipeline prefetches breaking-change inputs for an 'update' row", function()
  t.it("resolved 'tagged' as an update", function()
    t.assert.truthy(pipeline_results.tagged ~= nil)
    t.assert.equals("update", pipeline_results.tagged.status)
  end)

  local expected_current = gitcmd.tag_on_revision(mirror, pipeline_results.tagged.rev_before)
  local expected_target = gitcmd.tag_on_revision(mirror, pipeline_results.tagged.rev_after)
  local expected_messages =
    gitcmd.commit_messages_between(mirror, pipeline_results.tagged.rev_before, pipeline_results.tagged.rev_after)
  local expected_pending =
    gitcmd.pending_updates_between(mirror, pipeline_results.tagged.rev_before, pipeline_results.tagged.rev_after)
  local expected_message_text = (type(expected_messages) == "string" and expected_messages ~= "") and expected_messages
    or (expected_pending or "")
  local expected_commit_signal = signals.format_commit_signals(signals.classify_commit_signals(expected_message_text))

  -- Seed the cache the way ui/refresh.lua's apply_pipeline_result does for a
  -- non-error result: status/source/path/rev_before/rev_after set, every
  -- breaking-status-derived field cleared.
  state.pack_report_cache.plugins["tagged"] = {
    status = pipeline_results.tagged.status,
    source = pipeline_results.tagged.source,
    path = pipeline_results.tagged.path,
    rev_before = pipeline_results.tagged.rev_before,
    rev_after = pipeline_results.tagged.rev_after,
  }

  local wait_calls = 0
  local orig_system = vim.system
  vim.system = function(cmd, opts, on_exit)
    local handle = orig_system(cmd, opts, on_exit)
    local orig_wait = handle.wait
    handle.wait = function(...)
      wait_calls = wait_calls + 1
      return orig_wait(...)
    end
    return handle
  end

  local row = report.collect_dashboard_row("tagged")

  vim.system = orig_system

  t.it("collects the row with zero `:wait()` git calls (prefetch already filled the caches)", function()
    t.assert.equals(0, wait_calls)
  end)

  t.it("the collected row's breaking-status fields equal the cold sync-inference values", function()
    t.assert.equals(expected_current, row.current_version)
    t.assert.equals(expected_target, row.target_version)
    -- Not a strict string equality against `expected_pending`: git's `%h`
    -- abbreviation length depends on the repo's object count, which can
    -- differ slightly between the mirror clone and vim.pack's own installed
    -- checkout even for the identical commit. The shape and subject text are
    -- what matters here.
    t.assert.match("^%x%x%x%x%x%x%x+ │ feat: add feature$", row.pending_updates or "")
    t.assert.equals(expected_commit_signal, row.commit_signal)
    t.assert.equals("minor", row.semver_delta)
    t.assert.equals(false, row.breaking)
    t.assert.equals("semver minor bump", row.risk_reason)
  end)
end)

t.describe("a persisted nil-verdict row with risk_reason already set is not re-inferred on collect", function()
  state.pack_report_cache.plugins["tagged"] = {
    status = "update",
    source = pipeline_results.tagged.source,
    path = pipeline_results.tagged.path,
    rev_before = pipeline_results.tagged.rev_before,
    rev_after = pipeline_results.tagged.rev_after,
    -- `breaking` intentionally absent (nil): the shape a fresh-session reload
    -- leaves behind, since a nil `breaking` verdict is never persisted.
    risk_reason = "insufficient semver/commit signal",
    current_version = "sentinel-current",
    target_version = "sentinel-target",
    pending_updates = "sentinel-pending",
    semver_delta = "sentinel-delta",
    commit_signal = "sentinel-signal",
  }

  local system_calls = 0
  local orig_system = vim.system
  vim.system = function(...)
    system_calls = system_calls + 1
    return orig_system(...)
  end

  local row = report.collect_dashboard_row("tagged")

  vim.system = orig_system

  t.it("spawns no git process at all (inference is skipped, not just cache-hit)", function()
    t.assert.equals(0, system_calls)
  end)

  t.it("keeps the persisted verdict fields instead of recomputing them", function()
    t.assert.is_nil(row.breaking)
    t.assert.equals("insufficient semver/commit signal", row.risk_reason)
    t.assert.equals("sentinel-current", row.current_version)
    t.assert.equals("sentinel-target", row.target_version)
    t.assert.equals("sentinel-pending", row.pending_updates)
    t.assert.equals("sentinel-delta", row.semver_delta)
    t.assert.equals("sentinel-signal", row.commit_signal)
  end)
end)

t.finish()
