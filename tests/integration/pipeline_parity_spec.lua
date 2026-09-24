-- Pipeline status must equal vim.pack.update(offline) parsed status.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local tagged = gitfixture.new_remote("tagged")
gitfixture.commit(tagged, "feat: initial", { ["README.md"] = "v1" })
gitfixture.tag(tagged, "v1.0.0")
gitfixture.push(tagged)

local branch = gitfixture.new_remote("branch")
gitfixture.commit(branch, "feat: initial", { ["README.md"] = "v1" })
gitfixture.push(branch)

require("pack_companion").setup({
  spec = {
    { src = tagged.src, name = "tagged", version = "*" }, -- strict-parse tag range
    { src = branch.src, name = "branchplug", version = false }, -- forces branch tracking
  },
  dashboard = true,
  version_policy = false,
})

-- New commits/tags after install give both routes something to disagree about if either is wrong.
gitfixture.commit(tagged, "feat: add feature", { ["feature.txt"] = "x" })
gitfixture.tag(tagged, "v1.1.0")
gitfixture.push(tagged)

gitfixture.commit(branch, "feat: another commit", { ["more.txt"] = "y" })
gitfixture.push(branch)

local pipeline = require("pack_companion.dashboard.report.pipeline")
local parser = require("pack_companion.dashboard.report.parser")
local state = require("pack_companion.dashboard.state")

-- 1. Run pack-companion's own pipeline (online) for both plugins.
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
local vim_pack_status = {}
for name, p in pairs(state.pack_report_cache.plugins) do
  vim_pack_status[name] = p.status
end

t.describe("a tag-range ('*') plugin gets a new tag on its remote", function()
  t.it("is 'update' per pack-companion's own pipeline", function()
    t.assert.truthy(pipeline_results.tagged ~= nil)
    t.assert.equals("update", pipeline_results.tagged.status)
  end)

  t.it("agrees with vim.pack.update's own offline report", function()
    t.assert.equals(vim_pack_status.tagged, pipeline_results.tagged.status)
  end)
end)

t.describe("a branch-tracking plugin gets a new commit on its remote", function()
  t.it("is 'update' per pack-companion's own pipeline", function()
    t.assert.truthy(pipeline_results.branchplug ~= nil)
    t.assert.equals("update", pipeline_results.branchplug.status)
  end)

  t.it("agrees with vim.pack.update's own offline report", function()
    t.assert.equals(vim_pack_status.branchplug, pipeline_results.branchplug.status)
  end)
end)

t.finish()
