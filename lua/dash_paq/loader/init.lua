-- Lazy-spec loader over `vim.pack`: flattens specs, resolves versions,
-- installs via `vim.pack.add`, and manages startup and deferred loading.
local M = {}

local spec_mod = require("dash_paq.loader.spec")
local dev_mod = require("dash_paq.loader.dev")
local triggers_mod = require("dash_paq.loader.triggers")
local trace = require("dash_paq.loader.trace")
local policy = require("dash_paq.policy")
local modules_mod = require("dash_paq.loader.modules")
local notify = require("dash_paq.notify")
local git = require("dash_paq.git")

local notify_err = notify.err
local notify_warn = notify.warn

-- First insertion lands right after `stdpath("data")/site`, matching where
-- `:packadd!` would put it (`:h packadd`).
local function site_path()
  return vim.fs.normalize(vim.fs.joinpath(vim.fn.stdpath("data") --[[@as string]], "site"))
end

-- Insert after the last inserted root, else after site; index recomputed
-- (config() may edit rtp).
local function insert_root_tracked(root, rtp_track)
  local rtp_list = vim.opt.rtp:get()
  local idx = nil
  if rtp_track.last_root then
    for i, p in ipairs(rtp_list) do
      if p == rtp_track.last_root then
        idx = i
        break
      end
    end
  end
  if not idx then
    local site = site_path()
    for i, p in ipairs(rtp_list) do
      if vim.fs.normalize(p) == site then
        idx = i
        break
      end
    end
  end
  if idx then
    table.insert(rtp_list, idx + 1, root)
    vim.opt.rtp = rtp_list
  else
    vim.opt.rtp:prepend(root)
  end
  rtp_track.last_root = root
end

-- Insert `after_dir` right before the first pre-existing rtp entry ending in
-- `/after` (matching `:packadd!`'s own placement, ahead of the user's/site
-- `after`), or right after the previously-inserted after dir on later calls,
-- so after-dir order also stays equal to load order.
local function insert_after_tracked(after_dir, rtp_track)
  local rtp_list = vim.opt.rtp:get()
  local idx = nil
  if rtp_track.last_after then
    for i, p in ipairs(rtp_list) do
      if p == rtp_track.last_after then
        idx = i
        break
      end
    end
  end
  if not idx then
    for i, p in ipairs(rtp_list) do
      if p:match("/after$") then
        idx = i - 1
        break
      end
    end
  end
  if idx then
    table.insert(rtp_list, idx + 1, after_dir)
    vim.opt.rtp = rtp_list
  else
    vim.opt.rtp:append(after_dir)
  end
  rtp_track.last_after = after_dir
end

-- Add `entry`'s root (and `after/` dir, if present) onto 'runtimepath'.
-- Never sources anything; the caller decides that separately.
local function insert_entry_rtp(entry, rtp_track)
  local root = triggers_mod.resolve_root(entry)
  if type(root) ~= "string" or root == "" or vim.fn.isdirectory(root) ~= 1 then
    return
  end
  if vim.tbl_contains(vim.opt.rtp:get(), root) then
    return
  end
  insert_root_tracked(root, rtp_track)
  local after_dir = root .. "/after"
  if vim.fn.isdirectory(after_dir) == 1 and not vim.tbl_contains(vim.opt.rtp:get(), after_dir) then
    insert_after_tracked(after_dir, rtp_track)
  end
end

-- Shell-string builds are the only async kind (function/":ex" builds still
-- run inline on the main thread). They are serialized across every plugin
-- through this one module-local queue so many concurrent installs never
-- oversubscribe the machine with parallel `make`/`cargo` processes.
local shell_build_queue = {} ---@type {name: string, build: string, path: string?, on_done: fun()}[]
local shell_build_running = false

local function process_shell_queue()
  if shell_build_running then
    return
  end
  local item = table.remove(shell_build_queue, 1)
  if not item then
    return
  end
  shell_build_running = true
  local function finish(result)
    -- vim.system's on_exit fires off the main loop; hop back before touching
    -- notify/UI state or resuming the (possibly ex-command/API-calling) next build.
    vim.schedule(function()
      if result.code ~= 0 then
        notify_err(
          item.name .. ": build failed (" .. item.build .. "): " .. ((result.stderr or "exit ") .. result.code)
        )
      end
      shell_build_running = false
      item.on_done()
      process_shell_queue()
    end)
  end
  local ok, err = pcall(vim.system, { "/bin/sh", "-c", item.build }, { cwd = item.path, text = true }, finish)
  if not ok then
    finish({ code = -1, stderr = tostring(err) })
  end
end

local plugin_view = spec_mod.plugin_view

-- Runs one build and calls `on_done` exactly once, whether it succeeded,
-- failed, or was a no-op. Shell-string builds are queued (see above);
-- function and ":ex" builds still run synchronously, inline.
local function run_build(name, build, path, on_done, spec)
  if type(build) == "function" then
    local ok, err = pcall(build, plugin_view(name, spec, path))
    if not ok then
      notify_err(name .. ": build failed: " .. tostring(err))
    end
    on_done()
    return
  end

  if type(build) ~= "string" or build == "" then
    on_done()
    return
  end

  if build:sub(1, 1) == ":" then
    local ok, err = pcall(vim.cmd --[[@as fun(cmd: string)]], build:sub(2))
    if not ok then
      notify_err(name .. ": build failed (" .. build .. "): " .. tostring(err))
    end
    on_done()
    return
  end

  shell_build_queue[#shell_build_queue + 1] = { name = name, build = build, path = path, on_done = on_done }
  process_shell_queue()
end

-- Events lazy.nvim/LazyVim fire themselves; nothing fires them here, so a
-- trigger on one would never load its plugin.
local LAZY_EVENTS = {
  verylazy = "VeryLazy is fired by lazy.nvim, not Neovim; use UIEnter or VimEnter",
  lazyfile = 'LazyFile is LazyVim\'s; use { "BufReadPost", "BufNewFile", "BufWritePre" }',
}

local function run_auto_setup(entry, opts)
  if type(opts) ~= "table" then
    return
  end
  local candidates = spec_mod.derive_module_candidates(entry)
  for _, mod_name in ipairs(candidates) do
    local ok_mod, mod = pcall(require, mod_name)
    if ok_mod and type(mod) == "table" and type(mod.setup) == "function" then
      local ok_setup, err = pcall(mod.setup, opts)
      if not ok_setup then
        notify_err(entry.name .. ": setup() failed: " .. tostring(err))
      end
      return
    end
    -- A candidate that exists but fails to load is the plugin's own error,
    -- not a wrong guess: report it instead of dropping the opts silently.
    if not ok_mod and not tostring(mod):find("module '" .. mod_name .. "' not found", 1, true) then
      notify_err(entry.name .. ": loading " .. mod_name .. " for setup() failed: " .. tostring(mod))
      return
    end
  end
  notify_warn(
    entry.name
      .. ": no module with setup() found for opts/config = true (tried: "
      .. table.concat(candidates, ", ")
      .. "); use config = function(_, opts) ... end"
  )
end

-- Resolve saved dev choices once, independently of dashboard settings.
-- Only current candidates or an available upstream are valid; stale choices
-- use the default checkout, then follow dev.fallback if it is unavailable.
-- Return active dev paths and all dev-capable entries for the switch controls.
local function resolve_dev_entries(entries, dev_cfg)
  local dev_plugin_paths = {}
  local dev_capable = {}
  if not dev_cfg then
    return dev_plugin_paths, dev_capable
  end

  local choices = dev_mod.load_choices()

  for _, entry in pairs(entries) do
    -- Disabled by `cond`/`enabled`: it never loads, so no dev path to resolve.
    if entry.is_dev and not entry.enabled then
      entry.is_dev = false
    end
    if entry.is_dev then
      local base = dev_mod.base_dir_for(entry, dev_cfg)
      dev_capable[entry.name] = { base = base, has_src = entry.src ~= nil }

      local choice = choices[entry.name]
      local resolved_dir = nil
      local stale_choice = false

      if choice == "upstream" and entry.src then
        entry.is_dev = false
      elseif type(choice) == "string" and choice ~= "upstream" then
        resolved_dir = dev_mod.matching_candidate_path(base, choice)
        if not resolved_dir then
          stale_choice = true
          resolved_dir = dev_mod.default_dir(base)
        end
      else
        if choice ~= nil then
          stale_choice = true
        end
        resolved_dir = dev_mod.default_dir(base)
      end

      -- An existing directory that holds no plugin content is as unusable as a
      -- missing one.
      local not_plugin = nil
      if entry.is_dev and resolved_dir and not dev_mod.is_plugin_dir(resolved_dir) then
        not_plugin = resolved_dir
        resolved_dir = nil
      end

      if entry.is_dev then
        if resolved_dir then
          entry.dir = resolved_dir
          entry.src = nil
          dev_plugin_paths[entry.name] = resolved_dir
        else
          entry.is_dev = false
          local why = not_plugin and ("dev path " .. not_plugin .. " is not a plugin directory")
            or ("dev path not found (" .. tostring(base) .. ")")
          if dev_cfg.fallback == false then
            notify_err(entry.name .. ": " .. why .. " and dev.fallback is false, disabling")
            entry.enabled = false
          elseif entry.src then
            notify_warn(entry.name .. ": " .. why .. ", using upstream")
          else
            notify_err(entry.name .. ": " .. why .. " and the spec has no src to fall back to, disabling")
            entry.enabled = false
          end
        end
      end

      if stale_choice then
        notify_warn(entry.name .. ": saved dev choice not found, using default")
      end
    end
  end

  return dev_plugin_paths, dev_capable
end

local function install_specs(pack_specs)
  -- Initialize without publishing new specs or prompting for missing lockfile
  -- clones. Snapshot before adding specs, which masks an existing source.
  local ok_snapshot, plugins = pcall(function()
    vim.pack.add({}, { confirm = false, load = function() end })
    return vim.pack.get(nil, { info = false })
  end)
  if not ok_snapshot then
    notify_err("Cannot read installed plugins: " .. tostring(plugins))
    return
  end
  local installed = {}
  for _, plugin in ipairs(plugins) do
    installed[plugin.spec.name] = plugin
  end
  local unchanged, replaced = {}, {}
  for _, spec in ipairs(pack_specs) do
    local old = installed[spec.name]
    if not old or git.same_remote(old.spec.src, spec.src) then
      unchanged[#unchanged + 1] = spec
    else
      -- Keep the working tree outside opt, including local and untracked edits.
      local backup =
        vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(old.path)), spec.name .. ".backup-" .. tostring(vim.uv.hrtime()))
      local moved, move_err = vim.uv.fs_rename(old.path, backup)
      if not moved then
        notify_err("Cannot preserve " .. spec.name .. " before replacing its source: " .. tostring(move_err))
      else
        local ok, err = pcall(function()
          vim.pack.del({ spec.name }, { force = true })
          vim.pack.add({ spec }, { confirm = false, load = function() end })
        end)
        local ok_get, info = pcall(vim.pack.get, { spec.name }, { info = false })
        if ok and ok_get and info[1] and vim.fn.isdirectory(old.path) == 1 then
          replaced[#replaced + 1] = spec.name
          notify_warn("Previous checkout of " .. spec.name .. " preserved at " .. backup)
        else
          -- A failed native install removes its partial clone. Never overwrite
          -- a remaining path: keep the backup available for recovery instead.
          local restored, restore_err
          if vim.uv.fs_lstat(old.path) then
            restore_err = "replacement path still exists"
          else
            restored, restore_err = vim.uv.fs_rename(backup, old.path)
          end
          notify_err(
            "Source replacement failed for "
              .. spec.name
              .. ": "
              .. tostring(err or "install failed")
              .. (
                restored and "; previous checkout restored, restart to register it"
                or ("; previous checkout preserved at " .. backup .. ": " .. tostring(restore_err))
              )
          )
        end
      end
    end
  end
  if #unchanged > 0 then
    -- `vim.pack.add` validates the whole list before installing anything, so
    -- one invalid spec would block every install: check each the same way
    -- (vim/pack.lua `normalize_spec`) and report it by name.
    local valid = {}
    for _, pack_spec in ipairs(unchanged) do
      local version = pack_spec.version
      local problem = (type(pack_spec.src) ~= "string" or pack_spec.src == "") and "src must be a non-empty string"
        or (pack_spec.name ~= nil and (type(pack_spec.name) ~= "string" or pack_spec.name == "")) and "name must be a non-empty string"
        or (
            version ~= nil
            and type(version) ~= "string"
            and not (type(version) == "table" and pcall(version.has, version, "1"))
          )
          and "version must be a string or vim.VersionRange, got " .. vim.inspect(version)
      if problem then
        notify_err(tostring(pack_spec.name) .. ": invalid spec: " .. problem)
      else
        valid[#valid + 1] = pack_spec
      end
    end
    if #valid > 0 then
      local ok, err = pcall(vim.pack.add, valid, { confirm = false, load = function() end })
      if not ok then
        notify_err("vim.pack.add failed during install: " .. tostring(err))
      end
    end
  end
  if #replaced > 0 then
    vim.schedule(function()
      vim.notify("Reinstalled (src changed): " .. table.concat(replaced, ", "), vim.log.levels.INFO)
    end)
  end
end

-- `config`: `dash_paq.config`'s resolved table. `dashboard`: nil when `config.dashboard == false`.
function M.setup(config, dashboard)
  local AUGROUP = vim.api.nvim_create_augroup("dash_paq", { clear = true })

  -- Nesting depth of `:source` calls right now; decides below whether a load's `after/plugin/**` must be queued.
  local source_depth = 0
  vim.api.nvim_create_autocmd("SourcePre", {
    group = AUGROUP,
    callback = function()
      source_depth = source_depth + 1
    end,
  })
  vim.api.nvim_create_autocmd("SourcePost", {
    group = AUGROUP,
    callback = function()
      source_depth = math.max(0, source_depth - 1)
    end,
  })

  local entries = spec_mod.flatten_specs(config.modules, config.spec, {
    notify_err = notify_err,
    default_host = config.default_host,
    dev = config.dev,
  })

  for _, entry in pairs(entries) do
    local has_required = false
    for _, spec in ipairs(entry.specs) do
      if not spec.optional then
        has_required = true
        break
      end
    end
    if not has_required then
      entry.enabled = false
    end
  end

  -- After every gate, so a disabled entry never resolves a dev path.
  local dev_plugin_paths, dev_capable = resolve_dev_entries(entries, config.dev)

  local sorted = spec_mod.ordered_entries(entries)

  local build_hooks = {}
  local pack_specs = {}
  -- false: ignore cached pins too.
  local version_policy = config.version_policy and policy.load_version_policy() or { plugins = {} }
  -- Per-plugin version intent published to the dashboard (drift/`"*"` warnings).
  local declared_versions = {}

  for _, entry in ipairs(sorted) do
    if entry.enabled then
      for _, spec in ipairs(entry.specs) do
        if type(spec.init) == "function" then
          local ok, err = pcall(spec.init, plugin_view(entry.name, spec, triggers_mod.resolve_root(entry)))
          if not ok then
            notify_err(entry.name .. ": init() failed: " .. tostring(err))
          end
        end

        if spec.build ~= nil and not entry.is_dev then
          build_hooks[entry.name] = build_hooks[entry.name] or {}
          build_hooks[entry.name][#build_hooks[entry.name] + 1] = { build = spec.build, spec = spec }
        end
      end

      if entry.src and not entry.is_dev then
        local pack_spec = { src = entry.src, name = entry.name }
        local version, star = spec_mod.resolve_entry_version(entry, version_policy)
        if version ~= nil then
          pack_spec.version = version
        end
        pack_specs[#pack_specs + 1] = pack_spec

        declared_versions[entry.name] = { resolved = version, star = star }
      end
    end
  end

  local entry_meta = {}
  local entry_state = {}
  local load_entry

  -- `declared` -> `registered` (deferred only) -> `loading` -> `loaded`; a disabled entry never leaves `declared`.
  for _, entry in ipairs(sorted) do
    entry_state[entry.name] = { status = "declared", loaded_at = nil, loaded_by = nil }
    if entry.enabled then
      local meta = {
        cmds = {},
        events = {},
        fts = {},
        keys = {},
        has_keys = false,
        defer = false,
        priority = 50,
      }
      local seen_cmd, seen_event, seen_ft = {}, {}, {}
      local force_start = false
      local explicit_lazy = false

      for _, spec in ipairs(entry.specs) do
        if spec.lazy == false then
          force_start = true
        elseif spec.lazy == true then
          explicit_lazy = true
        end

        if type(spec.priority) == "number" then
          meta.priority = math.max(meta.priority, spec.priority)
        end

        for _, cmd in ipairs(spec_mod.as_list(spec.cmd)) do
          if type(cmd) == "string" and cmd ~= "" and not seen_cmd[cmd] then
            seen_cmd[cmd] = true
            meta.cmds[#meta.cmds + 1] = cmd
          end
        end

        -- lazy.nvim's forms: "Event", "Event pattern", { "A", "B" },
        -- { event = "A" | { "A", "B" }, pattern = ... }.
        local event_items = {}
        if type(spec.event) == "table" and next(spec.event) == nil then
          notify_err(entry.name .. ": empty event list (skipped)")
        end
        for _, ev in ipairs(spec_mod.as_list(spec.event)) do
          if type(ev) == "table" then
            local names = ev.event ~= nil and spec_mod.as_list(ev.event) or ev
            if #names == 0 then
              notify_err(entry.name .. ": event table has no event name (skipped)")
            end
            for _, name in ipairs(names) do
              event_items[#event_items + 1] = { name = name, pattern = ev.pattern }
            end
          else
            event_items[#event_items + 1] = { name = ev }
          end
        end
        for _, item in ipairs(event_items) do
          local ev_name, ev_pattern = item.name, item.pattern
          if type(ev_name) ~= "string" or ev_name == "" then
            notify_err(entry.name .. ": event " .. vim.inspect(ev_name) .. " is not a name (skipped)")
            ev_name = nil
          end
          -- lazy.nvim's "Event pattern" shorthand, in either form.
          if type(ev_name) == "string" and ev_pattern == nil then
            local name, pattern = ev_name:match("^(%S+)%s+(.-)%s*$")
            ev_name, ev_pattern = name or ev_name, pattern
          end
          if type(ev_name) == "string" and ev_name ~= "" then
            local foreign = LAZY_EVENTS[ev_name:lower()]
            local all_lazy = false
            if ev_name:lower() == "user" and ev_pattern ~= nil then
              -- Drop only the lazy.nvim patterns; the user's own still trigger.
              local kept, dropped = {}, 0
              for _, pattern in ipairs(spec_mod.as_list(ev_pattern)) do
                local lazy = type(pattern) == "string" and LAZY_EVENTS[pattern:lower()]
                if lazy then
                  dropped = dropped + 1
                  notify_err(entry.name .. ": event " .. lazy .. " (skipped; the plugin loads as if it were not set)")
                else
                  kept[#kept + 1] = pattern
                end
              end
              if dropped > 0 then
                all_lazy = #kept == 0
                ev_pattern = #kept == 1 and kept[1] or kept
              end
            end
            -- The same check `nvim_create_autocmd` applies (`exists("##")`
            -- reads only the first word, so it passes "BufRead,BufNewFile").
            local known = pcall(vim.api.nvim_get_autocmds, { event = ev_name })
            local bad_pattern = false
            for _, pattern in ipairs(spec_mod.as_list(ev_pattern)) do
              bad_pattern = bad_pattern or type(pattern) ~= "string"
            end
            local problem = foreign and ("event " .. foreign)
              or (not known and ("unknown event " .. ev_name))
              or (bad_pattern and ("event " .. ev_name .. " pattern must be a string or list of strings"))
            if all_lazy then
              ev_name = nil
            elseif problem then
              notify_err(entry.name .. ": " .. problem .. " (skipped; the plugin loads as if it were not set)")
              ev_name = nil
            end
          end
          if type(ev_name) == "string" and ev_name ~= "" then
            local key = ev_name .. "\0" .. table.concat(vim.tbl_map(tostring, spec_mod.as_list(ev_pattern)), ",")
            if not seen_event[key] then
              seen_event[key] = true
              meta.events[#meta.events + 1] = { event = ev_name, pattern = ev_pattern }
            end
          end
        end

        for _, ft in ipairs(spec_mod.as_list(spec.ft)) do
          if type(ft) == "string" and ft ~= "" and not seen_ft[ft] then
            seen_ft[ft] = true
            meta.fts[#meta.fts + 1] = ft
          end
        end

        local key_specs = spec_mod.normalize_key_specs(spec.keys, plugin_view(entry.name, spec), notify_err)
        if #key_specs > 0 then
          meta.has_keys = true
          vim.list_extend(meta.keys, key_specs)
        end
      end

      -- Triggerless `lazy = true` entries load through `require()`,
      -- `:DashPaq load`, or a dependency.
      meta.defer = not force_start
        and (#meta.cmds > 0 or #meta.events > 0 or #meta.fts > 0 or meta.has_keys or explicit_lazy or entry.dep_only)
      entry_meta[entry.name] = meta
    end
  end

  if dashboard then
    dashboard.setup(config)
  end

  -- Build hooks queued during init so they don't race the native load-plugins step; flushed once on `VimEnter`.
  local queued_builds = {} ---@type {name: string, path: string?}[]

  -- Loads `name`, then runs its builds one at a time, in declared order:
  -- the next build only starts once the previous one's `on_done` fires (sync
  -- builds call it inline; shell builds call it from the queue above).
  local function run_plugin_builds(name, path)
    local builds = build_hooks[name]
    if not builds then
      return
    end
    load_entry(name, "build")
    local i = 0
    local function step()
      i = i + 1
      local hook = builds[i]
      if hook == nil then
        return
      end
      run_build(name, hook.build, path, step, hook.spec)
    end
    step()
  end

  vim.api.nvim_create_autocmd("PackChanged", {
    group = AUGROUP,
    callback = function(ev)
      local data = ev.data or {}
      if data.kind ~= "install" and data.kind ~= "update" then
        return
      end
      local name = data.spec and data.spec.name
      if not name or not build_hooks[name] then
        return
      end

      -- `load_entry` is defined further down: an install during this setup()'s own
      -- `vim.pack.add` (setup called after startup) queues too, and is flushed below.
      if vim.v.vim_did_init == 0 or load_entry == nil then
        queued_builds[#queued_builds + 1] = { name = name, path = data.path }
        return
      end

      run_plugin_builds(name, data.path)
    end,
  })

  vim.api.nvim_create_autocmd("VimEnter", {
    group = AUGROUP,
    once = true,
    callback = function()
      local pending = queued_builds
      queued_builds = {}
      for _, item in ipairs(pending) do
        run_plugin_builds(item.name, item.path)
      end
    end,
  })

  local policy_was_empty = type(version_policy.plugins) ~= "table" or next(version_policy.plugins) == nil
  -- Pins from another schema (an upgrade from an older release) are ignored
  -- like a missing policy, so this session also runs without them.
  local policy_outdated = not policy_was_empty and version_policy.schema ~= policy.SCHEMA

  if #pack_specs > 0 then
    install_specs(pack_specs)
  end

  if #pack_specs > 0 and config.version_policy then
    -- Deferred: git shell-outs per plugin would block the UI at startup.
    vim.api.nvim_create_autocmd("VimEnter", {
      group = AUGROUP,
      once = true,
      callback = function()
        vim.defer_fn(function()
          policy.refresh_version_policy_async(function(ok, reason)
            if ok and policy_was_empty then
              vim.notify("Generated initial version policy — restart to apply tag pins", vim.log.levels.INFO)
            elseif ok and policy_outdated then
              vim.notify(
                "Rebuilt the version policy from an older release — restart to apply tag pins",
                vim.log.levels.INFO
              )
            elseif ok and reason == "full" then
              vim.notify("Refreshed version policy", vim.log.levels.INFO)
            end
          end)
        end, config.version_policy.startup_delay_ms)
      end,
    })
  end

  -- A conditionally-disabled spec still counts as declared, not an orphan.
  local retain_pack_names = {}
  for _, entry in ipairs(sorted) do
    if entry.src and not entry.is_dev then
      retain_pack_names[entry.name] = true
    end
  end

  if dashboard then
    -- Lets the dashboard flag an on-disk entry with no matching spec as orphaned.
    dashboard.set_declared_plugin_names(retain_pack_names)
    dashboard.set_declared_plugin_versions(declared_versions)
    dashboard.set_dev_plugin_paths(dev_plugin_paths)
    dashboard.set_dev_capable_plugins(dev_capable)
  end

  local triggers = triggers_mod.new({ group = AUGROUP, notify_err = notify_err })
  -- Shared across every route so rtp order stays equal to load order.
  local rtp_track = { last_root = nil, last_after = nil }

  -- after/plugin queue for loads nested in :source before VimEnter.
  local queued_after_entries = {} ---@type table[]
  vim.api.nvim_create_autocmd("VimEnter", {
    group = AUGROUP,
    once = true,
    callback = function()
      local pending = queued_after_entries
      queued_after_entries = {}
      for _, queued_entry in ipairs(pending) do
        triggers.source_entry_after(queued_entry)
      end
    end,
  })

  -- Check the dependency graph before consuming any trigger. A dependency may
  -- define the parent's command, so those stubs still come off before loading.
  local function directories_available(entry, seen)
    local status = entry_state[entry.name].status
    if seen[entry.name] or status == "loaded" or status == "loading" then
      return true
    end
    seen[entry.name] = true
    local root = triggers_mod.resolve_root(entry)
    if (entry.src or entry.dir) and (not root or vim.fn.isdirectory(root) ~= 1) then
      notify_err("Plugin directory unavailable for " .. entry.name .. ": " .. tostring(root or entry.dir))
      return false
    end
    for dep_name in pairs(entry.deps) do
      local dep = entries[dep_name]
      if dep and dep.enabled and not directories_available(dep, seen) then
        return false
      end
    end
    return true
  end

  -- The only place anything loads: guards re-entrancy, then walks the
  -- algorithm every route (startup, dependency, `:DashPaq load`, a build hook,
  -- `require()`, or a cmd/event/ft/keys trigger) shares.
  local function apply_entry(entry, reason)
    local state = entry_state[entry.name]
    if state.status == "loading" or state.status == "loaded" then
      return false
    end
    if not directories_available(entry, {}) then
      return false
    end
    state.status = "loading"

    -- Remove this entry's own trigger stubs before anything else, so its
    -- `config()` below can (re)define the same command/mapping/autocmd
    -- without colliding with a stale stub. The firing trigger (if any)
    -- forwards/replays on its own once this call returns.
    triggers.disable(entry.name)

    for dep_name in pairs(entry.deps) do
      local dep = entries[dep_name]
      if dep and dep.enabled then
        load_entry(dep_name, "dependency:" .. entry.name)
      end
    end

    -- Still sourcing `init.lua`: Neovim's own native step will pick this
    -- root up itself, so this loader must not also source it (double-source).
    local native_load_pending = vim.v.vim_did_init == 0

    insert_entry_rtp(entry, rtp_track)

    if native_load_pending then
      -- Neovim's own pending `:runtime! filetype.lua` will source this
      -- root's `ftdetect/*` itself; mark it done so no other route does too.
      triggers.mark_ftdetect_pending_native(entry)
    else
      triggers.source_plugin_files(entry)
      triggers.source_entry_ftdetect(entry)
    end

    local opts, has_opts = spec_mod.resolve_opts(entry, notify_err)
    local ran_config = false
    local has_config_true = false
    for _, spec in ipairs(entry.specs) do
      if type(spec.config) == "function" then
        local ok, err = pcall(spec.config, plugin_view(entry.name, spec, triggers_mod.resolve_root(entry)), opts)
        if not ok then
          notify_err(entry.name .. ": config() failed: " .. tostring(err))
        end
        ran_config = true
      elseif spec.config == true then
        has_config_true = true
      end
    end
    -- Auto-`setup(opts)` only when a spec supplied `opts` or `config = true`.
    if not ran_config and (has_opts or has_config_true) then
      run_auto_setup(entry, opts)
    end

    -- Every key with a known `rhs` becomes a real mapping now. An `lhs`-only
    -- key is left alone; it relies on the plugin's own `config()` to have
    -- (re)defined it.
    for _, key in ipairs(entry_meta[entry.name].keys) do
      if key.rhs ~= nil then
        if key.ft then
          triggers.apply_loaded_ft_key(key)
        else
          triggers.apply_loaded_key(key)
        end
      end
    end

    -- During init the native step sources after/plugin. Nested in :source
    -- before VimEnter: queue to VimEnter. Else source now; dedupe skips
    -- native files.
    if not native_load_pending then
      if vim.v.vim_did_enter == 0 and source_depth > 0 then
        queued_after_entries[#queued_after_entries + 1] = entry
      else
        triggers.source_entry_after(entry)
      end
    end

    state.status = "loaded"
    state.loaded_at = os.date("%H:%M:%S")
    state.loaded_by = reason
    return true
  end

  load_entry = function(name, reason)
    local entry = entries[name]
    if not entry or not entry.enabled then
      return false
    end
    return apply_entry(entry, reason)
  end

  -- lazy.nvim-style require-triggered loading: a `require()` miss for a
  -- module a not-yet-loaded deferred entry provides loads that entry first.
  modules_mod.install({
    entries = entries,
    sorted = sorted,
    entry_state = entry_state,
    load_entry = load_entry,
  })

  require("dash_paq.loader.dev_command").setup(dev_capable)

  trace.setup({
    entries = entries,
    sorted = sorted,
    entry_state = entry_state,
    entry_meta = entry_meta,
    load_entry = load_entry,
  })

  local startup_entries = {}

  for _, entry in ipairs(sorted) do
    if entry.enabled and not entry_meta[entry.name].defer then
      startup_entries[#startup_entries + 1] = entry
    end
  end

  table.sort(startup_entries, function(a, b)
    local pa = entry_meta[a.name].priority
    local pb = entry_meta[b.name].priority
    if pa ~= pb then
      return pa > pb
    end
    return a.index < b.index
  end)

  for _, entry in ipairs(startup_entries) do
    load_entry(entry.name, "startup")
  end

  -- Only after startup loading: an already-`loaded` entry never gets a
  -- trigger registered too.
  for _, entry in ipairs(sorted) do
    if entry.enabled and entry_state[entry.name].status ~= "loaded" then
      local meta = entry_meta[entry.name]
      entry_state[entry.name].status = "registered"

      -- One invalid trigger (a bad key mode) is reported
      -- against its entry and must not stop later entries from registering.
      local function register(what, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then
          notify_err(entry.name .. ": " .. what .. " failed: " .. tostring(err))
        end
      end

      for _, key in ipairs(meta.keys) do
        register("key " .. tostring(key.lhs), triggers.map_key_trigger, entry.name, key, load_entry)
      end

      if meta.defer then
        for _, cmd_name in ipairs(meta.cmds) do
          register("cmd " .. cmd_name, triggers.register_cmd_trigger, entry.name, cmd_name, load_entry)
        end
        for _, event_item in ipairs(meta.events) do
          register("event " .. event_item.event, triggers.register_event_trigger, entry.name, event_item, load_entry)
        end
        if #meta.fts > 0 then
          register("ft trigger", triggers.register_ft_trigger, entry, meta.fts, load_entry)
        end
      end
    end
  end

  -- Installs queued while `load_entry` was not yet defined (setup after startup):
  -- nothing else will flush them, `VimEnter` has already fired.
  if vim.v.vim_did_init ~= 0 then
    local pending = queued_builds
    queued_builds = {}
    for _, item in ipairs(pending) do
      run_plugin_builds(item.name, item.path)
    end
  end
end

return M
