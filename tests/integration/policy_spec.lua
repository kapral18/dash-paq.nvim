local t = require("runner")
local fixture = require("support.gitfixture")
local policy = require("dash_paq.policy")
local spec = require("dash_paq.loader.spec")
local remote = fixture.new_remote("policy")
fixture.commit(remote, "fix: initial", { ["README.md"] = "policy" })
fixture.push(remote)
local other_path = remote.bare:gsub("%.git$", "")
fixture.run({ "git", "init", "--quiet", "--bare", other_path })
local other_src = "file://" .. other_path
vim.pack.add({ { src = remote.src, name = "policy" } }, { confirm = false, load = false })
local path = vim.pack.get({ "policy" }, { info = false })[1].path

t.describe("WHEN a cached decision belongs to another source", function()
  t.it("SHOULD ignore the old source's pin for a reused plugin name", function()
    policy.write_version_policy({ policy = { src = other_src, strategy = "tags", latest_tag = "v9.9.9" } })
    local resolved =
      spec.resolve_entry_version({ name = "policy", src = remote.src, specs = { {} } }, policy.load_version_policy())
    t.assert.is_nil(resolved)
  end)

  t.it("SHOULD refresh a decision whose source changed even within its TTL", function()
    policy.write_version_policy({ policy = { src = other_src, strategy = "tags", latest_tag = "v9.9.9" } })
    policy.refresh_version_policy_if_needed()
    local decision = policy.load_version_policy().plugins.policy
    t.assert.equals(remote.src, decision.src)
    t.assert.equals("branch", decision.strategy)
  end)

  t.it("SHOULD ignore a pin from the old cache schema", function()
    local resolved = spec.resolve_entry_version({ name = "policy", src = remote.src, specs = { {} } }, {
      schema = 3,
      plugins = { policy = { src = remote.src, strategy = "tags", latest_tag = "v9.9.9" } },
    })
    t.assert.is_nil(resolved)
  end)

  t.it("SHOULD not infer that different network URLs identify the same source", function()
    local resolved = spec.resolve_entry_version(
      { name = "policy", src = "https://example.test/repo.git", specs = { {} } },
      {
        schema = policy.SCHEMA,
        plugins = { policy = { src = "https://example.test/repo", strategy = "tags", latest_tag = "v9.9.9" } },
      }
    )
    t.assert.is_nil(resolved)
  end)
end)

t.describe("WHEN a synchronous rebuild supersedes an asynchronous refresh", function()
  t.it("SHOULD retain the newer decision after old callbacks complete", function()
    policy.invalidate_version_policy()
    local timers = {}
    local defer = vim.defer_fn
    vim.defer_fn = function(callback)
      timers[#timers + 1] = callback
    end
    policy.refresh_version_policy_async()
    table.remove(timers, 1)()
    fixture.tag(remote, "v1.0.0")
    fixture.push(remote)
    fixture.run({ "git", "-C", path, "fetch", "--tags", "origin" })
    policy.rebuild_version_policy("policy")
    while #timers > 0 do
      table.remove(timers, 1)()
    end
    vim.defer_fn = defer
    t.assert.equals("tags", policy.load_version_policy().plugins.policy.strategy)
  end)
end)

t.finish()
