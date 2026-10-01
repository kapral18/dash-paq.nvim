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
    t.assert.equals(0.68, resolved.dashboard.width_ratio)
    t.assert.equals(84, resolved.dashboard.min_width)
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
    dashboard = { min_width = 100 },
    version_policy = { min_tags = 5 },
    hosts = { ["gitlab.com"] = { compare = "-/compare/%s...%s", commit = "-/commit/%s" } },
  })

  t.it("deep-merges overrides onto the dashboard defaults", function()
    t.assert.equals(100, resolved.dashboard.min_width)
    t.assert.equals(0.68, resolved.dashboard.width_ratio) -- untouched default
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

t.finish()
