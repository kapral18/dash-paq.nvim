-- Deferred-load trigger registration for the dash-paq loader: keymaps,
-- user-command stubs, events, and filetypes that call back into `load_entry`
-- the first time they fire.
local M = {}

local fs = require("dash_paq.fs")
local notify = require("dash_paq.notify")

-- Local dev directory when present, else the `vim.pack`-managed clone path,
-- else a `dir` spec. Exported for `loader/init.lua`'s rtp insertion too.
local function resolve_root(entry)
  if entry.is_dev and entry.dir then
    return vim.fn.expand(entry.dir)
  end
  if entry.src then
    local ok, info = pcall(vim.pack.get, { entry.name }, { info = false })
    if ok and type(info) == "table" and info[1] and type(info[1].path) == "string" then
      return info[1].path
    end
    return nil
  end
  if entry.dir then
    return vim.fn.expand(entry.dir)
  end
  return nil
end

M.resolve_root = resolve_root

-- Augroup ids attached to `event_name`, for the replay below to diff by group.
local function snapshot_event_groups(event_name)
  local ok, list = pcall(vim.api.nvim_get_autocmds, { event = event_name })
  if not ok then
    return {}
  end
  local groups = {}
  for _, au in ipairs(list) do
    if au.group then
      groups[au.group] = true
    end
  end
  return groups
end

-- Events whose `pattern` is a match tag, not a filename glob: replayed via
-- `pattern = ev.match` instead of `buffer = ev.buf`.
local PATTERN_MATCH_EVENTS = {
  User = true,
  CmdlineEnter = true,
  ColorScheme = true,
  OptionSet = true,
  ModeChanged = true,
}

-- Re-fire `event_name` for each augroup new since `before_groups`. A
-- groupless autocmd cannot be targeted this way and will not see the replay.
local function replay_new_groups(event_name, before_groups, ev)
  local ok, list = pcall(vim.api.nvim_get_autocmds, { event = event_name })
  if not ok then
    return
  end
  local exec_opts_base = PATTERN_MATCH_EVENTS[event_name] and { pattern = ev.match } or { buffer = ev.buf }
  local fired = {}
  for _, au in ipairs(list) do
    if au.group and not before_groups[au.group] and not fired[au.group] then
      fired[au.group] = true
      local exec_opts = vim.tbl_extend("force", { modeline = false, data = ev.data }, exec_opts_base)
      exec_opts.group = au.group
      pcall(vim.api.nvim_exec_autocmds, event_name, exec_opts)
    end
  end
end

function M.new(opts)
  opts = opts or {}
  local group = opts.group
  local notify_err = opts.notify_err or notify.err

  local self = {}
  local command_wrappers = {}

  -- Every `after/plugin/**` file sourced so far, keyed by normalized real
  -- path; the only reliable way to dedupe native vs. self sourcing.
  local recorded_after_paths = {} ---@type table<string, boolean>

  -- Live before Neovim's own native load-plugins step ever runs.
  vim.api.nvim_create_autocmd("SourcePost", {
    group = group,
    pattern = "*/after/plugin/*",
    callback = function(ev)
      -- Real path, so a dev symlink and its target key the same way.
      local p = fs.real_path(ev.match or ev.file)
      if p then
        recorded_after_paths[p] = true
      end
    end,
  })

  -- Per-root guard so an entry's `ftdetect/*` is sourced exactly once.
  local did_ftdetect = {} ---@type table<string, boolean>
  local pending_ftdetect_root = {} ---@type table<string, boolean>

  -- Live trigger bookkeeping so `self.disable` can tear it down on load; a
  -- stale cmd stub otherwise collides with the plugin's real command (`E174`).
  local entry_triggers = {} ---@type table<string, {cmds: string[], keys: {mode:string|string[], lhs:string, buf:integer?}[], autocmd_ids: integer[]}>

  local function triggers_for(entry_name)
    local t = entry_triggers[entry_name]
    if not t then
      t = { cmds = {}, keys = {}, autocmd_ids = {} }
      entry_triggers[entry_name] = t
    end
    return t
  end

  function self.disable(entry_name)
    local t = entry_triggers[entry_name]
    if not t then
      return
    end
    entry_triggers[entry_name] = nil

    for _, cmd_name in ipairs(t.cmds) do
      command_wrappers[cmd_name] = nil
      pcall(vim.api.nvim_del_user_command, cmd_name)
    end
    for _, key in ipairs(t.keys) do
      pcall(vim.keymap.del, key.mode, key.lhs, key.buf and { buffer = key.buf } or nil)
    end
    for _, id in ipairs(t.autocmd_ids) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end

  -- `ftdetect/*` scripts rely on `augroup filetypedetect` already being the
  -- active augroup for their own bare `autocmd filetypedetect ...` calls.
  local function source_ftdetect_now(root)
    if did_ftdetect[root] then
      return
    end
    did_ftdetect[root] = true

    local paths = vim.fn.glob(root .. "/ftdetect/*.{vim,lua}", false, true)
    if #paths == 0 then
      return
    end
    vim.api.nvim_create_augroup("filetypedetect", { clear = false })
    vim.cmd("augroup filetypedetect")
    for _, p in ipairs(paths) do
      local ok, err = pcall(vim.cmd.source, { p, magic = { file = false } })
      if not ok then
        notify_err("Failed sourcing ftdetect file " .. p .. ": " .. tostring(err))
      end
    end
    vim.cmd("augroup END")
  end

  -- While `did_load_filetypes` is unset, defer to a one-shot `SourcePost` on
  -- `*/filetype.lua`, which sets that flag as its first statement.
  local function source_ftdetect(root)
    if type(root) ~= "string" or root == "" or vim.fn.isdirectory(root) ~= 1 then
      return
    end
    if did_ftdetect[root] then
      return
    end
    if vim.g.did_load_filetypes then
      source_ftdetect_now(root)
      return
    end
    if pending_ftdetect_root[root] then
      return
    end
    pending_ftdetect_root[root] = true
    vim.api.nvim_create_autocmd("SourcePost", {
      group = group,
      pattern = "*/filetype.lua",
      once = true,
      callback = function()
        source_ftdetect_now(root)
      end,
    })
  end

  -- `:packadd` never runs for a `dir`/dev entry outside the native window.
  function self.source_plugin_root(root)
    if type(root) ~= "string" or root == "" or vim.fn.isdirectory(root) ~= 1 then
      return
    end
    local plugin_paths = vim.fn.glob(root .. "/plugin/**/*.{vim,lua}", false, true)
    for _, p in ipairs(plugin_paths) do
      local ok, err = pcall(vim.cmd.source, { p, magic = { file = false } })
      if not ok then
        notify_err("Failed sourcing plugin file " .. p .. ": " .. tostring(err))
      end
    end
  end

  function self.source_plugin_files(entry)
    self.source_plugin_root(resolve_root(entry))
  end

  function self.source_entry_ftdetect(entry)
    source_ftdetect(resolve_root(entry))
  end

  -- Called after inserting a root onto rtp during init: Neovim's own pending
  -- `:runtime!` will source `ftdetect/*` for free, so mark it done here to
  -- stop a deferred `source_ftdetect` sourcing it again. No-op once init has run.
  function self.mark_ftdetect_pending_native(entry)
    if vim.g.did_load_filetypes then
      return
    end
    local root = resolve_root(entry)
    if type(root) == "string" and root ~= "" then
      did_ftdetect[root] = true
    end
  end

  -- A file already recorded in `recorded_after_paths` is skipped, whether
  -- Neovim's own native after-pass or an earlier call here sourced it first.
  function self.source_entry_after(entry)
    local root = resolve_root(entry)
    if type(root) ~= "string" or root == "" or vim.fn.isdirectory(root) ~= 1 then
      return
    end
    local after_paths = vim.fn.glob(root .. "/after/plugin/**/*.{vim,lua}", false, true)
    for _, p in ipairs(after_paths) do
      if type(p) == "string" and p ~= "" then
        local real = fs.real_path(p)
        if not (real and recorded_after_paths[real]) then
          local ok, err = pcall(vim.cmd.source, { p, magic = { file = false } })
          if not ok then
            notify_err("Failed sourcing after/plugin file " .. p .. ": " .. tostring(err))
          end
        end
      end
    end
  end

  -- A buffer-local `ft` stub deletes itself here: `self.disable` only tracks
  -- global stubs, so an lhs-only key would otherwise recurse via feedkeys.
  local function make_rhs(entry_name, key, load_entry, buf)
    return function()
      if buf then
        pcall(vim.keymap.del, key.mode, key.lhs, { buffer = buf })
      end
      load_entry(entry_name, "key:" .. tostring(key.lhs))
      local feed = vim.api.nvim_replace_termcodes("<Ignore>" .. key.lhs, true, true, true)
      vim.api.nvim_feedkeys(feed, "i", false)
    end
  end

  function self.apply_loaded_key(key)
    local real_opts = vim.deepcopy(key.opts) or {}
    pcall(vim.keymap.set, key.mode, key.lhs, key.rhs, real_opts)
  end

  -- Sets it in every open buffer of `key.ft`, plus an untracked `FileType` autocmd for every later buffer.
  function self.apply_loaded_ft_key(key)
    local patterns = type(key.ft) == "table" and key.ft or { key.ft }
    local fts = {}
    for _, ft in ipairs(patterns) do
      fts[ft] = true
    end

    local function set_for_buf(buf)
      local real_opts = vim.deepcopy(key.opts) or {}
      real_opts.buffer = buf
      pcall(vim.keymap.set, key.mode, key.lhs, key.rhs, real_opts)
    end

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and fts[vim.bo[buf].filetype] then
        set_for_buf(buf)
      end
    end

    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = patterns,
      callback = function(args)
        set_for_buf(args.buf)
      end,
    })
  end

  function self.map_key_trigger(entry_name, key, load_entry)
    local base_opts = key.opts or {}

    -- `expr = true`, returns nothing: without it an operator-pending
    -- lhs-only mapping cancels its operator instead of surviving for the replay below.
    local function stub_opts(buf)
      return {
        desc = base_opts.desc,
        nowait = base_opts.nowait,
        expr = true,
        buffer = buf,
      }
    end

    if key.ft then
      local patterns = type(key.ft) == "table" and key.ft or { key.ft }
      local id = vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = patterns,
        callback = function(args)
          vim.keymap.set(key.mode, key.lhs, make_rhs(entry_name, key, load_entry, args.buf), stub_opts(args.buf))
        end,
      })
      local t = triggers_for(entry_name)
      t.autocmd_ids[#t.autocmd_ids + 1] = id
    else
      vim.keymap.set(key.mode, key.lhs, make_rhs(entry_name, key, load_entry), stub_opts(nil))
      local t = triggers_for(entry_name)
      t.keys[#t.keys + 1] = { mode = key.mode, lhs = key.lhs }
    end
  end

  function self.register_cmd_trigger(entry_name, cmd_name, load_entry)
    if command_wrappers[cmd_name] then
      return
    end
    command_wrappers[cmd_name] = true
    local t = triggers_for(entry_name)
    t.cmds[#t.cmds + 1] = cmd_name

    vim.api.nvim_create_user_command(cmd_name, function(ctx)
      -- `load_entry` deletes this stub before `config()` (re)defines the real command.
      load_entry(entry_name, "cmd:" .. cmd_name)

      -- Forward range, bang, args, and `<mods>` to the now-real command.
      local ex = cmd_name
      if ctx.range and ctx.range > 0 then
        ex = string.format("%d,%d%s", ctx.line1, ctx.line2, ex)
      end
      if ctx.bang then
        ex = ex .. "!"
      end
      if ctx.args and ctx.args ~= "" then
        ex = ex .. " " .. ctx.args
      end
      if ctx.mods and ctx.mods ~= "" then
        ex = ctx.mods .. " " .. ex
      end
      vim.cmd(ex)
    end, {
      nargs = "*",
      bang = true,
      range = true,
      desc = "Load plugin and execute " .. cmd_name,
    })
  end

  function self.register_event_trigger(entry_name, event_item, load_entry)
    local id = vim.api.nvim_create_autocmd(event_item.event, {
      group = group,
      pattern = event_item.pattern,
      once = true,
      callback = function(ev)
        local before_groups = snapshot_event_groups(event_item.event)
        local loaded = load_entry(entry_name, "event:" .. event_item.event)
        if loaded and ev.buf and vim.api.nvim_buf_is_valid(ev.buf) then
          replay_new_groups(event_item.event, before_groups, ev)
        end
      end,
    })
    local t = triggers_for(entry_name)
    t.autocmd_ids[#t.autocmd_ids + 1] = id
  end

  -- `:filetype plugin on`/`:filetype indent on` re-run their rtp search
  -- only for a `FileType` fired after the entry landed on rtp.
  local NATIVE_FT_GROUP_NAMES = { "filetypeplugin", "filetypeindent" }

  local function resolve_augroup_id(name)
    local ok, id = pcall(vim.api.nvim_create_augroup, name, { clear = false })
    if ok then
      return id
    end
    return nil
  end

  -- A filetype the entry's own `ftdetect/` defines never fires a native
  -- `FileType`, so source it eagerly here instead of at load. Native
  -- `filetypeplugin`/`filetypeindent` (and any group `config()` registered)
  -- ran before the entry was on rtp, so replay once — only when this call
  -- actually loaded the entry, or an already-loaded entry double-fires.
  function self.register_ft_trigger(entry, fts, load_entry)
    self.source_entry_ftdetect(entry)

    local id = vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = fts,
      once = true,
      callback = function(args)
        local before_groups = snapshot_event_groups("FileType")
        local loaded = load_entry(entry.name, "ft")
        if not loaded or not (args.buf and vim.api.nvim_buf_is_valid(args.buf)) then
          return
        end

        local replay_group_ids = {}
        for _, gname in ipairs(NATIVE_FT_GROUP_NAMES) do
          local gid = resolve_augroup_id(gname)
          if gid then
            replay_group_ids[gid] = true
          end
        end

        local ok, list = pcall(vim.api.nvim_get_autocmds, { event = "FileType" })
        if not ok then
          return
        end
        local fired = {}
        for _, au in ipairs(list) do
          if au.group and (replay_group_ids[au.group] or not before_groups[au.group]) and not fired[au.group] then
            fired[au.group] = true
            pcall(vim.api.nvim_exec_autocmds, "FileType", {
              group = au.group,
              buffer = args.buf,
              modeline = false,
            })
          end
        end
      end,
    })
    local t = triggers_for(entry.name)
    t.autocmd_ids[#t.autocmd_ids + 1] = id
  end

  return self
end

return M
