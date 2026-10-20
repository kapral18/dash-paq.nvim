local t = require("runner")
local config = require("dash_paq.config")

t.describe("opts is missing both spec and modules", function()
  t.it("raises a clear error", function()
    t.assert.raises(function()
      config.setup({})
    end, "opts.spec or opts.modules is required")
  end)

  t.it("also raises for nil opts", function()
    t.assert.raises(function()
      config.setup(nil)
    end, "opts.spec or opts.modules is required")
  end)
end)

t.describe("opts is not a table", function()
  t.it("raises a clear error", function()
    t.assert.raises(function()
      config.setup("not-a-table")
    end, "opts must be a table")
  end)
end)

t.describe("opts.spec or opts.modules is supplied", function()
  t.it("accepts opts.spec alone", function()
    local resolved = config.setup({ spec = { "owner/repo" } })
    t.assert.same({ "owner/repo" }, resolved.spec)
  end)

  t.it("accepts opts.modules alone", function()
    local resolved = config.setup({ modules = { "plugins.editor" } })
    t.assert.same({ "plugins.editor" }, resolved.modules)
  end)

  t.it("accepts a single non-positional spec table (no [1]/#spec == 0)", function()
    local resolved = config.setup({ spec = { src = "owner/repo" } })
    t.assert.equals("owner/repo", resolved.spec.src)
  end)
end)

t.describe("dashboard/version_policy/dev are omitted", function()
  local resolved = config.setup({ spec = { "owner/repo" } })

  t.it("fills in the documented dashboard defaults", function()
    t.assert.equals(0.68, resolved.dashboard.height_ratio)
    t.assert.equals(18, resolved.dashboard.min_height)
    t.assert.equals(8, resolved.dashboard.fetch_concurrency)
    t.assert.equals(4, resolved.dashboard.apply_batch_size)
  end)

  t.it("fills in the documented version_policy defaults", function()
    t.assert.equals(3, resolved.version_policy.min_tags)
    t.assert.equals(180, resolved.version_policy.max_tag_age_days)
    t.assert.equals(3, resolved.version_policy.ttl_days)
  end)

  t.it("defaults default_host to GitHub", function()
    t.assert.equals("https://github.com/", resolved.default_host)
  end)

  t.it("defaults dev.path to ~/projects with fallback enabled", function()
    t.assert.equals("~/projects", resolved.dev.path)
    t.assert.equals(true, resolved.dev.fallback)
  end)

  t.it("ships the built-in github.com/codeberg.org host templates", function()
    t.assert.truthy(resolved.hosts["github.com"] ~= nil)
    t.assert.truthy(resolved.hosts["codeberg.org"] ~= nil)
  end)
end)

t.describe("dashboard = false", function()
  t.it("resolves dashboard to false, not a table", function()
    local resolved = config.setup({ spec = { "owner/repo" }, dashboard = false })
    t.assert.equals(false, resolved.dashboard)
  end)
end)

t.describe("version_policy = false", function()
  t.it("resolves version_policy to false, not a table", function()
    local resolved = config.setup({ spec = { "owner/repo" }, version_policy = false })
    t.assert.equals(false, resolved.version_policy)
  end)
end)

t.describe("dev = false", function()
  t.it("resolves dev to nil (disabled)", function()
    local resolved = config.setup({ spec = { "owner/repo" }, dev = false })
    t.assert.is_nil(resolved.dev)
  end)
end)

t.describe("a partial dashboard/version_policy/hosts table is supplied", function()
  local resolved = config.setup({
    spec = { "owner/repo" },
    dashboard = { min_height = 30 },
    version_policy = { min_tags = 5 },
    hosts = { ["gitlab.com"] = { compare = "-/compare/%s...%s", commit = "-/commit/%s" } },
  })

  t.it("deep-merges overrides onto the dashboard defaults", function()
    t.assert.equals(30, resolved.dashboard.min_height)
    t.assert.equals(0.68, resolved.dashboard.height_ratio) -- untouched default
  end)

  t.it("deep-merges overrides onto the version_policy defaults", function()
    t.assert.equals(5, resolved.version_policy.min_tags)
    t.assert.equals(180, resolved.version_policy.max_tag_age_days) -- untouched default
  end)

  t.it("extends the built-in hosts table rather than replacing it", function()
    t.assert.truthy(resolved.hosts["gitlab.com"] ~= nil)
    t.assert.truthy(resolved.hosts["github.com"] ~= nil)
  end)
end)

t.describe("WHEN opts have typos or wrong types", function()
  local function warnings(opts)
    local notes = {}
    local original = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local resolved = config.setup(opts)
    vim.wait(100, function()
      return #notes > 0
    end)
    vim.notify = original
    return resolved, table.concat(notes, "\n")
  end

  t.it("SHOULD accept a single spec or module string", function()
    t.assert.same({ "owner/repo" }, config.setup({ spec = "owner/repo" }).spec)
    t.assert.same({ "plugins" }, config.setup({ modules = "plugins" }).modules)
  end)

  t.it("SHOULD warn about unknown keys at the top level and in sections", function()
    local _, warned = warnings({ spec = { "o/r" }, dashbaord = false, dashboard = { heigth_ratio = 0.5 } })
    t.assert.match("opts%.dashbaord", warned)
    t.assert.match("opts%.dashboard%.heigth_ratio", warned)
  end)

  t.it("SHOULD warn about a wrongly typed value and keep its default", function()
    local resolved, warned = warnings({ spec = { "o/r" }, version_policy = { startup_delay_ms = "200" } })
    t.assert.match("opts%.version_policy%.startup_delay_ms", warned)
    t.assert.equals(200, resolved.version_policy.startup_delay_ms)
  end)

  t.it("SHOULD warn when a section is neither false nor a table", function()
    local resolved, warned = warnings({ spec = { "o/r" }, dashboard = "x" })
    t.assert.match("opts%.dashboard", warned)
    t.assert.equals(0.68, resolved.dashboard.height_ratio)
  end)

  t.it("SHOULD warn about a host missing compare or commit", function()
    local resolved, warned = warnings({ spec = { "o/r" }, hosts = { ["gitlab.com"] = { compare = "x/%s...%s" } } })
    t.assert.match("gitlab%.com", warned)
    t.assert.is_nil(resolved.hosts["gitlab.com"])
  end)

  t.it("SHOULD stay quiet for a valid config", function()
    local _, warned = warnings({ spec = { "o/r" }, dashboard = { margin = 4 }, dev = { patterns = { "^x" } } })
    t.assert.equals("", warned)
  end)

  t.it("SHOULD read true for a section as on with the defaults, quietly", function()
    local resolved, warned = warnings({ spec = { "o/r" }, dashboard = true, dev = true, version_policy = true })
    t.assert.equals("", warned)
    t.assert.equals(0.68, resolved.dashboard.height_ratio)
  end)
end)

t.finish()
