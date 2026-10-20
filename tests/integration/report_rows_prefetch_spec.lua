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
local git = require("dash_paq.git")
local popups = require("dash_paq.dashboard.ui.popups")

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

  local calls = 0
  local original_run = git.run
  git.run = function(...)
    calls = calls + 1
    return original_run(...)
  end
  local ok, row = pcall(function()
    local collected = report.collect_dashboard_row("tagged")
    local ctx = require("dash_paq.dashboard.ui.view").new_context({ rows = {}, selected = {} })
    popups.open_details(ctx, collected)
    popups.close_details(ctx)
    return collected
  end)
  git.run = original_run
  assert(ok, row)

  t.it("SHOULD collect the row and open its details without more Git queries", function()
    t.assert.equals(0, calls)
  end)

  t.it("SHOULD describe the fixture's minor release without a breaking signal", function()
    t.assert.equals("v1.0.0", row.current_version)
    t.assert.equals("v1.1.0", row.target_version)
    t.assert.match("^%x%x%x%x%x%x%x+ │ feat: add feature$", row.pending_updates or "")
    t.assert.equals("feat:1", row.commit_signal)
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
