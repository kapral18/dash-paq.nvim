-- Lazy-spec loader over `vim.pack`: flattens specs, resolves versions,
-- installs via `vim.pack.add`, and defers loading behind cmd/event/ft/keys
-- triggers (or loads at startup for `lazy = false` / no-trigger entries).
local M = {}

local spec_mod = require("dash_paq.loader.spec")
local dev_mod = require("dash_paq.loader.dev")
local triggers_mod = require("dash_paq.loader.triggers")
local trace = require("dash_paq.loader.trace")
local policy = require("dash_paq.policy")
local modules_mod = require("dash_paq.loader.modules")

local AUGROUP = nil

local function notify_err(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.ERROR)
  end)
end

local function notify_warn(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.WARN)
  end)
end

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
local shell_build_queue = {} ---@type {build: string, path: string?, on_done: fun()}[]
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
  vim.system({ "/bin/sh", "-c", item.build }, { cwd = item.path, text = true }, function(result)
    -- vim.system's on_exit fires off the main loop; hop back before touching
    -- notify/UI state or resuming the (possibly ex-command/API-calling) next build.
    vim.schedule(function()
      if result.code ~= 0 then
        notify_err("Build shell command failed (" .. item.build .. "): " .. ((result.stderr or "exit ") .. result.code))
      end
      shell_build_running = false
      item.on_done()
      process_shell_queue()
    end)
  end)
end

-- Runs one build and calls `on_done` exactly once, whether it succeeded,
-- failed, or was a no-op. Shell-string builds are queued (see above);
-- function and ":ex" builds still run synchronously, inline.
local function run_build(build, path, on_done)
  on_done = on_done or function() end

  if type(build) == "function" then
    local ok, err = pcall(build)
    if not ok then
      notify_err("Build function failed: " .. tostring(err))
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
      notify_err("Build ex-command failed (" .. build .. "): " .. tostring(err))
    end
    on_done()
    return
  end

  shell_build_queue[#shell_build_queue + 1] = { build = build, path = path, on_done = on_done }
  process_shell_queue()
end

local function run_auto_setup(entry, opts)
  if type(opts) ~= "table" then
    return
  end
  for _, mod_name in ipairs(spec_mod.derive_module_candidates(entry)) do
    local ok_mod, mod = pcall(require, mod_name)
    if ok_mod and type(mod) == "table" and type(mod.setup) == "function" then
      local ok_setup, err = pcall(mod.setup, opts)
      if not ok_setup then
        notify_err("Failed setup() for " .. entry.name .. ": " .. tostring(err))
      end
      return
    end
  end
end

-- Resolves every dev-capable entry (`entry.is_dev` from spec/pattern match)
-- against its saved choice (`loader/dev.lua`'s dev.json), read once before
-- any entry is touched (independent of `opts.dashboard`):
--   choice "upstream", entry has `src`  -> normal upstream entry.
--   choice matches (normalized) one of the base's *current* candidate
--   checkouts                          -> dev entry at that dir.
--   anything else (no choice, a stale/invalid one, an existing dir that
--   isn't among the base's current candidates, or "upstream" with no
--   `src`)                              -> the default dir for the base
--                                          (falls back to `src`/disables per
--                                          `dev.fallback` when that's nil).
-- Returns `dev_plugin_paths` (name -> active dev dir, for the dashboard) and
-- `dev_capable` (name -> {base, has_src}, every dev-capable entry regardless
-- of its resolved choice, for the dashboard's `L` toggle).
local function resolve_dev_entries(entries, dev_cfg)
  local dev_plugin_paths = {}
  local dev_capable = {}
  if not dev_cfg then
    return dev_plugin_paths, dev_capable
  end

  local choices = dev_mod.load_choices()

  for _, entry in pairs(entries) do
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

local function load_version_policy()
  local loaded = policy.load_version_policy()
  if loaded then
    return loaded
  end
  return { plugins = {} }
end

-- `config`: `dash_paq.config`'s resolved table. `dashboard`: nil when `config.dashboard == false`.
function M.setup(config, dashboard)
  AUGROUP = vim.api.nvim_create_augroup("dash_paq", { clear = true })

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

  local dev_plugin_paths, dev_capable = resolve_dev_entries(entries, config.dev)

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

  local sorted = spec_mod.ordered_entries(entries)

  local build_hooks = {}
  local pack_specs = {}
  -- false: ignore cached pins too.
  local version_policy = config.version_policy and load_version_policy() or { plugins = {} }
  -- Per-plugin version intent published to the dashboard (drift/`"*"` warnings).
  local declared_versions = {}

  for _, entry in ipairs(sorted) do
    if entry.enabled then
      for _, spec in ipairs(entry.specs) do
        if type(spec.init) == "function" then
          local ok, err = pcall(spec.init, spec)
          if not ok then
            notify_err("init() failed for " .. entry.name .. ": " .. tostring(err))
          end
        end

        if spec.build ~= nil and not entry.is_dev then
          build_hooks[entry.name] = build_hooks[entry.name] or {}
          build_hooks[entry.name][#build_hooks[entry.name] + 1] = spec.build
        end
      end

      if entry.src and not entry.is_dev then
        local pack_spec = { src = entry.src, name = entry.name }
        local version = spec_mod.resolve_entry_version(entry, version_policy)
        if version ~= nil then
          pack_spec.version = version
        end
        pack_specs[#pack_specs + 1] = pack_spec

        -- Literal `version = "*"` is lost after resolving to a VersionRange.
        local raw_star = false
        for _, spec in ipairs(entry.specs) do
          if spec.version == "*" then
            raw_star = true
          end
        end
        declared_versions[entry.name] = { resolved = version, star = raw_star }
      end
    end
  end

  local entry_meta = {}
  local entry_state = {}
  local load_entry

  local function entry_name_complete(arglead)
    local names = {}
    for name, entry in pairs(entries) do
      if entry.enabled and (arglead == "" or name:find("^" .. vim.pesc(arglead))) then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    return names
  end

  -- `declared` -> `registered` (deferred only) -> `loading` -> `loaded`; a disabled entry never leaves `declared`.
  for _, entry in ipairs(sorted) do
    entry_state[entry.name] = { status = "declared", loaded_at = nil, loaded_by = nil, load_count = 0 }
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

        for _, ev in ipairs(spec_mod.as_list(spec.event)) do
          local ev_name, ev_pattern
          if type(ev) == "string" then
            ev_name = ev
          elseif type(ev) == "table" then
            ev_name = ev.event or ev[1]
            ev_pattern = ev.pattern
          end
          if type(ev_name) == "string" and ev_name ~= "" then
            local key = ev_name .. "\0" .. tostring(ev_pattern or "")
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

        local key_specs = spec_mod.normalize_key_specs(spec.keys, spec, notify_err)
        if #key_specs > 0 then
          meta.has_keys = true
          vim.list_extend(meta.keys, key_specs)
        end
      end

      -- `lazy = true` with no other trigger stays deferred forever: loadable
      -- only via `:DashPaq load` or as a dependency, never at startup.
      meta.defer = not force_start
        and (#meta.cmds > 0 or #meta.events > 0 or #meta.fts > 0 or meta.has_keys or explicit_lazy)
      if entry.dep_only and not force_start and not meta.defer then
        meta.defer = true
      end
      entry_meta[entry.name] = meta
    end
  end

  if dashboard then
    dashboard.setup(config)
  end

  -- Build hooks queued during init so they don't race the native load-plugins step; flushed once on `VimEnter`.
  local queued_builds = {} ---@type {name: string, path: string?}[]

  -- Runs `name`'s builds (already loaded) one at a time, in declared order:
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
      local build = builds[i]
      if build == nil then
        return
      end
      run_build(build, path, step)
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

  if #pack_specs > 0 then
    -- A no-op `load` keeps `vim.pack.add` from touching 'runtimepath' itself
    -- (this loader does that); an install failure here must not abort setup.
    local ok_add, err_add = pcall(vim.pack.add, pack_specs, { confirm = false, load = function() end })
    if not ok_add then
      notify_err("vim.pack.add failed during install: " .. tostring(err_add))
    end
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
  local spec_src = {}
  for _, entry in ipairs(sorted) do
    if entry.src and not entry.is_dev then
      retain_pack_names[entry.name] = true
      if entry.enabled then
        spec_src[entry.name] = entry.src
      end
    end
  end

  if dashboard then
    -- Lets the dashboard flag an on-disk entry with no matching spec as orphaned.
    dashboard.set_declared_plugin_names(retain_pack_names)
    dashboard.set_declared_plugin_versions(declared_versions)
    dashboard.set_dev_plugin_paths(dev_plugin_paths)
    dashboard.set_dev_capable_plugins(dev_capable)
  end

  -- Re-clone when a declared plugin's remote moved (not orphan cleanup).
  local ok_get, all_plugins = pcall(vim.pack.get, nil, { info = false })
  if ok_get and type(all_plugins) == "table" then
    local to_reinstall = {}
    for _, p in ipairs(all_plugins) do
      local name = p.spec and p.spec.name
      if type(name) == "string" and name ~= "" then
        if retain_pack_names[name] and spec_src[name] and p.spec.src and spec_src[name] ~= p.spec.src then
          to_reinstall[#to_reinstall + 1] = name
        end
      end
    end

    if #to_reinstall > 0 then
      pcall(vim.pack.del, to_reinstall, { force = true })
      pcall(vim.pack.add, pack_specs, { confirm = false, load = function() end })
      vim.schedule(function()
        vim.notify("Reinstalled (src changed): " .. table.concat(to_reinstall, ", "), vim.log.levels.INFO)
      end)
    end
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

  -- The only place anything loads: guards re-entrancy, then walks the
  -- algorithm every route (startup, dependency, `:DashPaq load`, a build hook, or
  -- a cmd/event/ft/keys trigger) shares.
  local function apply_entry(entry, reason)
    local state = entry_state[entry.name]
    if not state or state.status == "loading" or state.status == "loaded" then
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
        local ok, err = pcall(spec.config, spec, opts)
        if not ok then
          notify_err("config() failed for " .. entry.name .. ": " .. tostring(err))
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
    local meta = entry_meta[entry.name]
    if meta then
      for _, key in ipairs(meta.keys) do
        if key.rhs ~= nil then
          if key.ft then
            triggers.apply_loaded_ft_key(entry.name, key)
          else
            triggers.apply_loaded_key(entry.name, key)
          end
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
    state.loaded_by = reason or "unknown"
    state.load_count = (state.load_count or 0) + 1
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
    entry_name_complete = entry_name_complete,
  })

  local startup_entries = {}

  for _, entry in ipairs(sorted) do
    if entry.enabled then
      local meta = entry_meta[entry.name]
        or { cmds = {}, events = {}, fts = {}, keys = {}, defer = false, priority = 50 }
      if not meta.defer then
        startup_entries[#startup_entries + 1] = entry
      end
    end
  end

  table.sort(startup_entries, function(a, b)
    local pa = (entry_meta[a.name] or {}).priority or 50
    local pb = (entry_meta[b.name] or {}).priority or 50
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
        or { cmds = {}, events = {}, fts = {}, keys = {}, defer = false, priority = 50 }
      entry_state[entry.name].status = "registered"

      for _, key in ipairs(meta.keys) do
        triggers.map_key_trigger(entry.name, key, load_entry)
      end

      if meta.defer then
        for _, cmd_name in ipairs(meta.cmds) do
          triggers.register_cmd_trigger(entry.name, cmd_name, load_entry)
        end
        for _, event_item in ipairs(meta.events) do
          triggers.register_event_trigger(entry.name, event_item, load_entry)
        end
        if #meta.fts > 0 then
          triggers.register_ft_trigger(entry, meta.fts, load_entry)
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
