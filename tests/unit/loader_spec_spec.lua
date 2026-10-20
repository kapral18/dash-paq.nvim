local t = require("runner")
local spec_mod = require("dash_paq.loader.spec")

t.describe("deriving a source URL from a repo shorthand (repo_to_src)", function()
  t.it("expands owner/repo against the default GitHub host", function()
    t.assert.equals("https://github.com/owner/repo.git", spec_mod.repo_to_src("owner/repo"))
  end)

  t.it("honors a custom default_host", function()
    t.assert.equals("https://codeberg.org/owner/repo.git", spec_mod.repo_to_src("owner/repo", "https://codeberg.org/"))
  end)

  t.it("adds a trailing slash to a default_host missing one", function()
    t.assert.equals("https://codeberg.org/owner/repo.git", spec_mod.repo_to_src("owner/repo", "https://codeberg.org"))
  end)

  t.it("passes a scheme:// URL through verbatim", function()
    t.assert.equals("https://example.com/x/y", spec_mod.repo_to_src("https://example.com/x/y"))
    t.assert.equals("file:///tmp/x", spec_mod.repo_to_src("file:///tmp/x"))
  end)

  t.it("passes a git@ SSH shorthand through verbatim", function()
    t.assert.equals("git@github.com:owner/repo.git", spec_mod.repo_to_src("git@github.com:owner/repo.git"))
  end)

  t.it("passes a gh: shorthand through verbatim", function()
    t.assert.equals("gh:owner/repo", spec_mod.repo_to_src("gh:owner/repo"))
  end)
end)

t.describe("deriving a plugin name from a repo (repo_to_name)", function()
  t.it("takes the basename minus a .git suffix", function()
    t.assert.equals("repo", spec_mod.repo_to_name("https://github.com/owner/repo.git"))
    t.assert.equals("repo", spec_mod.repo_to_name("owner/repo"))
  end)
end)

t.describe("normalizing a spec table/string", function()
  t.it("wraps a bare string as { [1] = string }", function()
    t.assert.same({ "owner/repo" }, spec_mod.normalize_spec("owner/repo"))
  end)

  t.it("passes a table through unchanged", function()
    local spec = { "owner/repo", opts = {} }
    t.assert.equals(spec, spec_mod.normalize_spec(spec))
  end)

  t.it("rejects a non-string non-table", function()
    t.assert.is_nil(spec_mod.normalize_spec(42))
  end)
end)

t.describe("deriving module-name candidates for auto-setup", function()
  t.it("strips a .nvim suffix", function()
    local candidates = spec_mod.derive_module_candidates({ name = "conform.nvim" })
    t.assert.truthy(vim.tbl_contains(candidates, "conform"))
  end)

  t.it("strips a leading nvim- prefix", function()
    local candidates = spec_mod.derive_module_candidates({ name = "nvim-treesitter" })
    t.assert.truthy(vim.tbl_contains(candidates, "treesitter"))
  end)

  t.it("strips a .lua or -lua suffix", function()
    t.assert.truthy(vim.tbl_contains(spec_mod.derive_module_candidates({ name = "dim.lua" }), "dim"))
    t.assert.truthy(vim.tbl_contains(spec_mod.derive_module_candidates({ name = "tabout-lua" }), "tabout"))
  end)

  t.it("converts dashes to underscores", function()
    local candidates = spec_mod.derive_module_candidates({ name = "my-plugin" })
    t.assert.truthy(vim.tbl_contains(candidates, "my_plugin"))
  end)

  t.it("includes the bare name itself first", function()
    local candidates = spec_mod.derive_module_candidates({ name = "leap" })
    t.assert.equals("leap", candidates[1])
  end)
end)

t.describe("normalizing keys specs (normalize_key_specs)", function()
  t.it("keeps an rhs-bearing key as-is", function()
    local normalized = spec_mod.normalize_key_specs({ { "<leader>a", "<cmd>A<cr>", desc = "do A" } }, {})
    t.assert.equals(1, #normalized)
    t.assert.equals("<leader>a", normalized[1].lhs)
    t.assert.equals("<cmd>A<cr>", normalized[1].rhs)
    t.assert.equals("do A", normalized[1].opts.desc)
  end)

  t.it("keeps a lhs-only key with rhs = nil, not drop it", function()
    local normalized = spec_mod.normalize_key_specs({ { "<leader>zz" } }, {})
    t.assert.equals(1, #normalized)
    t.assert.equals("<leader>zz", normalized[1].lhs)
    t.assert.is_nil(normalized[1].rhs)
  end)

  t.it("defaults mode to normal mode", function()
    local normalized = spec_mod.normalize_key_specs({ { "<leader>a", "<cmd>A<cr>" } }, {})
    t.assert.equals("n", normalized[1].mode)
  end)

  t.it("honors an explicit mode", function()
    local normalized = spec_mod.normalize_key_specs({ { "<leader>a", "<cmd>A<cr>", mode = "v" } }, {})
    t.assert.equals("v", normalized[1].mode)
  end)

  t.it("drops a key disabled via enabled = false", function()
    local normalized = spec_mod.normalize_key_specs({ { "<leader>a", "<cmd>A<cr>", enabled = false } }, {})
    t.assert.equals(0, #normalized)
  end)

  t.it("resolves a function keys spec", function()
    local normalized = spec_mod.normalize_key_specs(function()
      return { { "<leader>b", "<cmd>B<cr>" } }
    end, {})
    t.assert.equals(1, #normalized)
    t.assert.equals("<leader>b", normalized[1].lhs)
  end)

  t.it("defaults remap = true for a <Plug> rhs", function()
    local normalized = spec_mod.normalize_key_specs({ { "<leader>p", "<Plug>(thing)" } }, {})
    t.assert.equals(true, normalized[1].opts.remap)
  end)

  t.it("SHOULD apply the same remap default to a named rhs", function()
    local normalized = spec_mod.normalize_key_specs({ { lhs = "<leader>p", rhs = "<Plug>(thing)" } }, {})
    t.assert.equals(true, normalized[1].opts.remap)
  end)

  t.it("SHOULD preserve an explicit remap override for a named rhs", function()
    local normalized = spec_mod.normalize_key_specs({ { lhs = "<leader>p", rhs = "<Plug>(thing)", remap = false } }, {})
    t.assert.equals(false, normalized[1].opts.remap)
  end)
end)

t.describe("normalizing a declared version (normalize_pack_version)", function()
  t.it("turns version = false into nil (branch tip)", function()
    t.assert.is_nil(spec_mod.normalize_pack_version(false))
  end)

  t.it("turns '*' into an open-ended vim.version.range", function()
    local range = spec_mod.normalize_pack_version("*")
    t.assert.equals("table", type(range))
    t.assert.truthy(range:has(vim.version.parse("v999.0.0")))
  end)

  t.it("turns a caret/tilde/comparison string into a vim.version.range", function()
    local range = spec_mod.normalize_pack_version("^1.0.0")
    t.assert.equals("table", type(range))
    t.assert.truthy(range:has(vim.version.parse("v1.9.0")))
    t.assert.falsy(range:has(vim.version.parse("v2.0.0")))
  end)

  t.it("passes a plain branch/tag/commit string through verbatim", function()
    t.assert.equals("main", spec_mod.normalize_pack_version("main"))
    t.assert.equals("v1.2.3", spec_mod.normalize_pack_version("v1.2.3"))
  end)
end)

t.describe("resolving an entry's declared version (resolve_entry_version)", function()
  t.it("prefers an explicit spec.commit over spec.version", function()
    local entry = { specs = { { version = "v1.0.0", commit = "deadbeef" } } }
    t.assert.equals("deadbeef", spec_mod.resolve_entry_version(entry, nil))
  end)

  t.it("lets a later spec's explicit version win (last spec wins)", function()
    local entry = { specs = { { tag = "v1.0.0" }, { branch = "develop" } } }
    t.assert.equals("develop", spec_mod.resolve_entry_version(entry, nil))
  end)

  t.it("forces branch-tip (nil) when version = false, even with a version_policy entry", function()
    local entry = { name = "x", specs = { { version = false } } }
    local policy = { plugins = { x = { strategy = "tags", latest_tag = "v1.0.0" } } }
    t.assert.is_nil(spec_mod.resolve_entry_version(entry, policy))
  end)

  t.it("falls back to the version-policy's latest_tag range when nothing is declared", function()
    local entry = { name = "x", src = "file:///x.git", specs = { {} } }
    local policy = { schema = 4, plugins = { x = { src = entry.src, strategy = "tags", latest_tag = "v2.3.0" } } }
    local resolved = spec_mod.resolve_entry_version(entry, policy)
    t.assert.equals("table", type(resolved))
    t.assert.truthy(resolved:has(vim.version.parse("v2.9.0")))
    t.assert.falsy(resolved:has(vim.version.parse("v3.0.0")))
  end)

  t.it("returns nil when nothing is declared and there is no policy entry", function()
    local entry = { name = "x", specs = { {} } }
    t.assert.is_nil(spec_mod.resolve_entry_version(entry, { plugins = {} }))
  end)
end)

t.describe("converting a policy tag to a vim.version.range (policy_tag_to_range)", function()
  t.it("produces a caret range for a major >= 1 tag", function()
    local range = spec_mod.policy_tag_to_range("v2.3.4")
    t.assert.truthy(range:has(vim.version.parse("v2.9.9")))
    t.assert.falsy(range:has(vim.version.parse("v3.0.0")))
  end)

  t.it("produces a tilde-minor range for a 0.x tag", function()
    local range = spec_mod.policy_tag_to_range("v0.7.2")
    t.assert.truthy(range:has(vim.version.parse("v0.7.9")))
    t.assert.falsy(range:has(vim.version.parse("v0.8.0")))
  end)

  t.it("passes a non-release tag through verbatim", function()
    t.assert.equals("nvim-0.6", spec_mod.policy_tag_to_range("nvim-0.6"))
  end)
end)

t.describe("flattening module/spec lists (flatten_specs)", function()
  t.it("builds one entry per unique plugin name from direct specs", function()
    local entries = spec_mod.flatten_specs({}, { "owner/one", "owner/two" })
    t.assert.truthy(entries.one ~= nil)
    t.assert.truthy(entries.two ~= nil)
  end)

  t.it("merges two specs sharing the same name into one entry", function()
    local entries = spec_mod.flatten_specs({}, {
      { "owner/one", opts = { a = 1 } },
      { "owner/one", opts = { b = 2 } },
    })
    t.assert.equals(1, vim.tbl_count(entries))
    t.assert.equals(2, #entries.one.specs)
  end)

  t.it("resolves a list of Lua module names, each returning a spec or list of specs", function()
    package.preload["fixture_mod_single"] = function()
      return "owner/single"
    end
    package.preload["fixture_mod_list"] = function()
      return { "owner/first", "owner/second" }
    end
    local entries = spec_mod.flatten_specs({ "fixture_mod_single", "fixture_mod_list" }, {})
    t.assert.truthy(entries.single ~= nil)
    t.assert.truthy(entries.first ~= nil)
    t.assert.truthy(entries.second ~= nil)
  end)

  t.it("adds a dependency-only entry for a string dependency with a slash", function()
    local entries = spec_mod.flatten_specs({}, {
      { "owner/main", dependencies = { "owner/dep" } },
    })
    t.assert.truthy(entries.dep ~= nil)
    t.assert.truthy(entries.dep.dep_only)
    t.assert.truthy(entries.main.deps.dep)
  end)

  t.it("keeps an optional dependency edge until merged enablement is resolved", function()
    local entries = spec_mod.flatten_specs({}, {
      { "owner/main", dependencies = { { "owner/dep", optional = true } } },
    })
    t.assert.truthy(entries.dep ~= nil)
    t.assert.truthy(entries.main.deps.dep)
  end)

  t.it("disables an entry when enabled = false", function()
    local entries = spec_mod.flatten_specs({}, { { "owner/one", enabled = false } })
    t.assert.falsy(entries.one.enabled)
  end)

  t.it("disables an entry when cond evaluates to false", function()
    local entries = spec_mod.flatten_specs(
      {},
      { {
        "owner/one",
        cond = function()
          return false
        end,
      } }
    )
    t.assert.falsy(entries.one.enabled)
  end)

  t.it("notifies and skips a module that fails to require", function()
    local notified = {}
    local entries = spec_mod.flatten_specs({ "fixture_mod_missing_xyz" }, {}, {
      notify_err = function(msg)
        notified[#notified + 1] = msg
      end,
    })
    t.assert.equals(0, vim.tbl_count(entries))
    t.assert.equals(1, #notified)
  end)
end)

t.describe("resolving opts (resolve_opts)", function()
  t.it("deep-merges table opts across specs, later winning on conflicts", function()
    local entry =
      { name = "x", specs = { { opts = { a = 1, nested = { x = 1 } } }, { opts = { a = 2, nested = { y = 2 } } } } }
    local opts, has_opts = spec_mod.resolve_opts(entry)
    t.assert.truthy(has_opts)
    t.assert.same({ a = 2, nested = { x = 1, y = 2 } }, opts)
  end)

  t.it("calls an opts function with (spec, existing_opts) and uses its return value", function()
    local entry = {
      name = "x",
      specs = {
        {
          opts = function(_, existing)
            existing.called = true
            return existing
          end,
        },
      },
    }
    local opts, has_opts = spec_mod.resolve_opts(entry)
    t.assert.truthy(has_opts)
    t.assert.truthy(opts.called)
  end)

  t.it("reports has_opts = false when no spec supplies opts", function()
    local entry = { name = "x", specs = { {} } }
    local _, has_opts = spec_mod.resolve_opts(entry)
    t.assert.falsy(has_opts)
  end)
end)

t.describe("ordering entries by dependency (ordered_entries)", function()
  t.it("places a dependency before its dependent", function()
    local entries = spec_mod.flatten_specs({}, {
      { "owner/main", name = "main", dependencies = { "owner/dep" } },
    })
    local ordered = spec_mod.ordered_entries(entries)
    local index = {}
    for i, e in ipairs(ordered) do
      index[e.name] = i
    end
    t.assert.truthy(index.dep < index.main)
  end)

  t.it("cuts a dependency cycle instead of infinite-looping", function()
    local entries = {
      a = { name = "a", index = 1, deps = { b = true } },
      b = { name = "b", index = 2, deps = { a = true } },
    }
    local ordered = spec_mod.ordered_entries(entries)
    t.assert.equals(2, #ordered)
  end)

  t.it("falls back to declaration order among unrelated entries", function()
    local entries = spec_mod.flatten_specs({}, { "owner/first", "owner/second", "owner/third" })
    local ordered = spec_mod.ordered_entries(entries)
    t.assert.same({ "first", "second", "third" }, { ordered[1].name, ordered[2].name, ordered[3].name })
  end)
end)

t.describe("resolving dev-directory overrides", function()
  t.it("treats spec.dev = true as a dev entry", function()
    t.assert.truthy(spec_mod.is_dev_entry("x", true, { path = "~/projects" }))
  end)

  t.it("treats spec.dev = false as never a dev entry, even matching a pattern", function()
    t.assert.falsy(spec_mod.is_dev_entry("x", false, { path = "~/projects", patterns = { "^x$" } }))
  end)

  t.it("matches a name against dev.patterns when spec.dev is nil", function()
    t.assert.truthy(spec_mod.is_dev_entry("my%-plugin", nil, { path = "~/projects", patterns = { "^my" } }))
  end)

  t.it("returns false when there is no dev config at all", function()
    t.assert.falsy(spec_mod.is_dev_entry("x", true, nil))
  end)

  t.it("joins dev.path and the plugin name for dev_path_for", function()
    local path = spec_mod.dev_path_for("myplug", { path = "/tmp/code" })
    t.assert.equals("/tmp/code/myplug", path)
  end)

  t.it("treats a non-empty string spec.dev as a dev entry (a per-plugin base dir)", function()
    t.assert.truthy(spec_mod.is_dev_entry("x", "/tmp/some/checkout", { path = "~/projects" }))
  end)

  t.it("treats an empty string spec.dev as never a dev entry", function()
    t.assert.falsy(spec_mod.is_dev_entry("x", "", { path = "~/projects" }))
  end)
end)

t.describe("a spec's string `dev` field sets entry.dev_base (per-plugin dev base dir)", function()
  t.it("expands and records the per-plugin base on the flattened entry", function()
    local entries = spec_mod.flatten_specs({}, {
      { "owner/plug", name = "plug", dev = "/tmp/my-plug-checkout" },
    }, { dev = { path = "~/projects" } })
    t.assert.truthy(entries.plug.is_dev)
    t.assert.equals("/tmp/my-plug-checkout", entries.plug.dev_base)
  end)

  t.it("a later boolean dev spec reverts dev_base to nil (last explicit dev wins)", function()
    local entries = spec_mod.flatten_specs({}, {
      { "owner/plug", name = "plug", dev = "/tmp/my-plug-checkout" },
      { name = "plug", dev = true },
    }, { dev = { path = "~/projects" } })
    t.assert.truthy(entries.plug.is_dev)
    t.assert.is_nil(entries.plug.dev_base)
  end)

  t.it("leaves dev_base nil for a plain boolean/pattern dev entry", function()
    local entries = spec_mod.flatten_specs({}, {
      { "owner/plug", name = "plug", dev = true },
    }, { dev = { path = "~/projects" } })
    t.assert.is_nil(entries.plug.dev_base)
  end)
end)

t.describe("WHEN merged specs match dev.patterns", function()
  t.it("SHOULD keep an explicit dev=false when a later spec omits dev", function()
    local entries = spec_mod.flatten_specs({}, {
      { "owner/plug", dev = false },
      { "owner/plug", opts = {} },
    }, { dev = { path = "/tmp/projects", patterns = { "^plug$" } } })
    t.assert.equals(false, entries.plug.is_dev)
  end)

  t.it("SHOULD let a later explicit dev=true enable development again", function()
    local entries = spec_mod.flatten_specs({}, {
      { "owner/plug", dev = false },
      { "owner/plug", dev = true },
    }, { dev = { path = "/tmp/projects", patterns = { "^plug$" } } })
    t.assert.equals(true, entries.plug.is_dev)
  end)
end)

t.describe("WHEN a spec fails or cannot be read", function()
  local function flatten(direct, modules)
    local errors = {}
    local entries = spec_mod.flatten_specs(modules or {}, direct, {
      notify_err = function(msg)
        errors[#errors + 1] = msg
      end,
    })
    return entries, table.concat(errors, "\n")
  end

  t.it("SHOULD pass the spec to a cond function, as lazy.nvim does", function()
    local entries = flatten({
      {
        "owner/condplug",
        cond = function(plugin)
          return plugin.name == "condplug"
        end,
      },
    })
    t.assert.equals(true, entries.condplug.enabled)
  end)

  t.it("SHOULD report a cond function that throws", function()
    local entries, errors = flatten({
      {
        "owner/boomcond",
        cond = function()
          error("cond exploded")
        end,
      },
    })
    t.assert.equals(false, entries.boomcond.enabled)
    t.assert.match("boomcond", errors)
    t.assert.match("cond exploded", errors)
  end)

  t.it("SHOULD report the Lua error of a spec module that fails to load", function()
    package.preload["fixture_mod_syntax"] = function()
      error("unexpected symbol near 'x'")
    end
    local _, errors = flatten({}, { "fixture_mod_syntax" })
    package.preload["fixture_mod_syntax"] = nil
    t.assert.match("fixture_mod_syntax", errors)
    t.assert.match("unexpected symbol", errors)
  end)

  t.it("SHOULD report the Lua error of a keys function that throws", function()
    local errors = {}
    spec_mod.normalize_key_specs(function()
      error("keys exploded")
    end, { name = "keysplug" }, function(msg)
      errors[#errors + 1] = msg
    end)
    t.assert.match("keys exploded", table.concat(errors))
  end)

  t.it("SHOULD report the Lua error of an opts function that throws", function()
    local errors = {}
    spec_mod.resolve_opts({
      name = "optsplug",
      specs = {
        {
          opts = function()
            error("opts exploded")
          end,
        },
      },
    }, function(msg)
      errors[#errors + 1] = msg
    end)
    t.assert.match("opts exploded", table.concat(errors))
  end)

  t.it("SHOULD point a lazy.nvim import at opts.modules", function()
    local entries, errors = flatten({ { import = "plugins" } })
    t.assert.same({}, entries)
    t.assert.match("import", errors)
    t.assert.match("modules", errors)
  end)

  t.it("SHOULD report import on a spec that also has a source, and keep the spec", function()
    local entries, errors = flatten({ { "LazyVim/LazyVim", import = "lazyvim.plugins" } })
    t.assert.truthy(entries.LazyVim)
    t.assert.match("lazyvim.plugins", errors)
  end)

  t.it("SHOULD read lazy.nvim-style string keys", function()
    local list = spec_mod.normalize_key_specs({ "<leader>a", { "<leader>b", mode = "x" } }, { name = "p" })
    t.assert.same({ "<leader>a", "n" }, { list[1].lhs, list[1].mode })
    t.assert.same({ "<leader>b", "x" }, { list[2].lhs, list[2].mode })
    t.assert.equals("<leader>c", spec_mod.normalize_key_specs("<leader>c", { name = "p" })[1].lhs)
  end)

  t.it("SHOULD report a function import readably, naming the spec", function()
    local _, errors = flatten({ {
      "owner/importer",
      import = function()
        return {}
      end,
    } })
    t.assert.match("importer: `import` is not supported", errors)
    t.assert.falsy(errors:find("function:", 1, true), errors)
  end)

  t.it("SHOULD skip an empty spec or dependency silently", function()
    local entries, errors = flatten({ { "owner/kept", dependencies = { {} } }, {} })
    t.assert.truthy(entries.kept)
    t.assert.equals("", errors)
  end)

  t.it("SHOULD flatten a nested list of specs", function()
    local entries, errors = flatten({ { { "owner/nested_a" }, { "owner/nested_b" } } })
    t.assert.truthy(entries.nested_a and entries.nested_b)
    t.assert.equals("", errors)
  end)
end)

t.finish()
