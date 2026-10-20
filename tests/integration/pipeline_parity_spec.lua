-- Pipeline status must equal vim.pack.update(offline) parsed status.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local tagged = gitfixture.new_remote("tagged")
gitfixture.commit(tagged, "feat: initial", { ["README.md"] = "v1" })
gitfixture.tag(tagged, "v1.0.0")
gitfixture.push(tagged)

local steady = gitfixture.new_remote("steady")
gitfixture.commit(steady, "feat: initial", { ["README.md"] = "v1" })
gitfixture.tag(steady, "v2.0.0")
gitfixture.push(steady)

local major = gitfixture.new_remote("major")
gitfixture.commit(major, "feat: initial", { ["README.md"] = "v1" })
gitfixture.tag(major, "v1.0.0")
gitfixture.push(major)

local series = gitfixture.new_remote("series")
gitfixture.commit(series, "feat: initial", { ["README.md"] = "v1" })
gitfixture.tag(series, "v2.3.0")
gitfixture.push(series, "v2")

local branch = gitfixture.new_remote("branch")
gitfixture.commit(branch, "feat: initial", { ["README.md"] = "v1" })
gitfixture.push(branch)

require("dash_paq").setup({
  spec = {
    { src = tagged.src, name = "tagged", version = "*" }, -- strict-parse tag range
    { src = steady.src, name = "steady", version = "*" }, -- stays current
    { src = major.src, name = "major", version = false }, -- branch tip gets a major tag
    { src = series.src, name = "series", version = "v2" }, -- a branch named like a version
    { src = branch.src, name = "branchplug", version = false }, -- forces branch tracking
  },
  dashboard = true,
  version_policy = false,
})

-- New commits/tags after install give both routes something to disagree about if either is wrong.
gitfixture.commit(tagged, "feat: add feature", { ["feature.txt"] = "x" })
gitfixture.tag(tagged, "v1.1.0")
gitfixture.push(tagged)

gitfixture.commit(major, "feat: new api", { ["api.txt"] = "z" })
gitfixture.tag(major, "v2.0.0")
gitfixture.push(major)

gitfixture.commit(series, "feat: more", { ["more.txt"] = "s" })
gitfixture.tag(series, "v2.4.0")
gitfixture.push(series, "v2")

gitfixture.commit(branch, "feat: another commit", { ["more.txt"] = "y" })
gitfixture.push(branch)

local pipeline = require("dash_paq.dashboard.report.pipeline")
local parser = require("dash_paq.dashboard.report.parser")
local state = require("dash_paq.dashboard.state")

-- 1. Run dash-paq's own pipeline (online) for both plugins.
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

-- 2. Ask vim.pack.update itself, offline, and parse its real report.
local ok_update = pcall(vim.pack.update, nil, { offline = true })
t.assert.truthy(ok_update, "vim.pack.update(offline=true) raised")
local bufnr = parser.find_pack_report_buffer()
t.assert.truthy(bufnr ~= nil, "expected a nvim-pack://confirm buffer after vim.pack.update")
parser.parse_pack_report_buffer(bufnr)
local vim_pack_status, vim_pack_label = {}, {}
for name, p in pairs(state.pack_report_cache.plugins) do
  vim_pack_status[name] = p.status
  vim_pack_label[name] = p.status == "update" and p.target_version or p.current_version
end

t.describe("the pipeline's version labels", function()
  t.it("SHOULD match the labels vim.pack.update's report shows", function()
    for _, name in ipairs({ "tagged", "steady", "branchplug" }) do
      t.assert.truthy(vim_pack_label[name] ~= nil, name)
      t.assert.equals(vim_pack_label[name], pipeline_results[name].version_label, name)
    end
  end)
end)

t.describe("WHEN a dashboard refresh finishes", function()
  t.it("SHOULD keep a current tag-range plugin's version label", function()
    local view = require("dash_paq.dashboard.ui.view")
    local report = require("dash_paq.dashboard.report")
    local fmt = require("dash_paq.dashboard.ui.format")
    local ctx = view.new_context({
      bufnr = vim.api.nvim_create_buf(false, true),
      rows = report.collect_dashboard_rows(),
      selected = {},
      filter_mode = "all",
      sort_mode = "status",
    })
    require("dash_paq.dashboard.ui.refresh").refresh(ctx, false)
    t.wait_until(function()
      return not ctx.online_check_running
    end, 10000, "refresh incomplete")
    t.assert.equals("v2.0.0", fmt.version_cell(report.collect_dashboard_row("steady")))
  end)

  t.it("SHOULD flag a major tag on a branch-tracking plugin's new tip", function()
    local row = require("dash_paq.dashboard.report").collect_dashboard_row("major")
    t.assert.equals("v1.0.0 -> v2.0.0", require("dash_paq.dashboard.ui.format").version_cell(row))
    t.assert.equals("major", row.semver_delta)
    t.assert.equals(true, row.breaking)
  end)

  t.it("SHOULD read the tag on the new tip of a branch named like a version", function()
    local row = require("dash_paq.dashboard.report").collect_dashboard_row("series")
    t.assert.equals("v2.3.0 -> v2.4.0", require("dash_paq.dashboard.ui.format").version_cell(row))
    t.assert.equals("minor", row.semver_delta)
  end)
end)

t.describe("a tag-range ('*') plugin gets a new tag on its remote", function()
  t.it("is 'update' per dash-paq's own pipeline", function()
    t.assert.truthy(pipeline_results.tagged ~= nil)
    t.assert.equals("update", pipeline_results.tagged.status)
  end)

  t.it("agrees with vim.pack.update's own offline report", function()
    t.assert.equals(vim_pack_status.tagged, pipeline_results.tagged.status)
  end)
end)

t.describe("a branch-tracking plugin gets a new commit on its remote", function()
  t.it("is 'update' per dash-paq's own pipeline", function()
    t.assert.truthy(pipeline_results.branchplug ~= nil)
    t.assert.equals("update", pipeline_results.branchplug.status)
  end)

  t.it("agrees with vim.pack.update's own offline report", function()
    t.assert.equals(vim_pack_status.branchplug, pipeline_results.branchplug.status)
  end)
end)

t.finish()
