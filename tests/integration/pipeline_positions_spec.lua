-- `on_each(result, done_count, total)`: `done_count` is the result's own completion position. The callbacks run
-- later via `vim.schedule`, so when several plugins finish while the main loop is busy it must still be 1..N in
-- delivery order, not the final count repeated.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local names = { "pa", "pb", "pc", "pd" }
local spec = {}
for _, name in ipairs(names) do
  local remote = gitfixture.new_remote(name)
  gitfixture.commit(remote, "feat: initial", { ["README.md"] = "v1" })
  gitfixture.push(remote)
  spec[#spec + 1] = { src = remote.src, name = name, version = false }
end

require("dash_paq").setup({ spec = spec, dashboard = true, version_policy = false })

local report = require("dash_paq.dashboard.report")

local positions, totals = {}, {}
local done = false
report.run_refresh_pipeline(nil, false, function(_, position, total)
  positions[#positions + 1] = position
  totals[#totals + 1] = total
  if #positions == 1 then
    -- Block the main loop while the remaining plugins finish, so their results queue up behind this callback.
    vim.uv.sleep(600)
  end
end, function()
  done = true
end)
t.wait_until(function()
  return done
end, 10000, "pipeline never finished")

t.describe("pipeline on_each positions", function()
  t.it("reports 1..N in delivery order even when results queue up behind a busy main loop", function()
    t.assert.same({ 1, 2, 3, 4 }, positions)
  end)

  t.it("reports the total on every call", function()
    t.assert.same({ 4, 4, 4, 4 }, totals)
  end)
end)

t.describe("WHEN a queued refresh target has been deleted", function()
  t.it("SHOULD report its failure and finish the pipeline", function()
    require("dash_paq.dashboard.state").dashboard_config.fetch_concurrency = 1
    local missing = vim.pack.get({ "pb" }, { info = false })[1].path
    vim.fn.delete(missing, "rf")
    local results, finished = {}, false
    report.run_refresh_pipeline({ "pa", "pb" }, true, function(result)
      results[result.name] = result.status
    end, function()
      finished = true
    end)
    t.wait_until(function()
      return finished
    end, 3000, "refresh was stranded")
    t.assert.equals("same", results.pa)
    t.assert.equals("error", results.pb)
  end)
end)

t.finish()
