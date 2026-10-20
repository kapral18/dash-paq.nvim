-- lazy.nvim-style require-triggered loading: a `require(modname)` miss whose
-- top-level segment is provided by an enabled, not-yet-loaded deferred entry
-- loads that entry first, then lets Lua's own searchers resolve the require
-- normally now that the entry is on 'runtimepath'.
local M = {}

local triggers_mod = require("dash_paq.loader.triggers")

-- The loader state (`entries`/`sorted`/`entry_state`/`load_entry`) the
-- searcher below reads from; set once by `M.install`.
local current = nil

-- Top-level module names `entry`'s resolved root provides: the `lua/` dir's
-- own immediate children only (`lua/<top>.lua` files, `lua/<top>/`
-- directories) -- no recursion into submodules, since only the top-level
-- segment of a `require()`d name ever needs to resolve to an entry.
local function top_level_modules(entry)
  local root = triggers_mod.resolve_root(entry)
  local names = {}
  if type(root) ~= "string" or root == "" then
    return nil
  end
  local handle = vim.uv.fs_scandir(vim.fs.joinpath(root, "lua"))
  if not handle then
    return nil
  end
  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if ftype == "link" then
      local stat = vim.uv.fs_stat(vim.fs.joinpath(root, "lua", name))
      ftype = stat and stat.type
    end
    if ftype == "file" and name:match("%.lua$") then
      names[#names + 1] = name:sub(1, -5)
    elseif ftype == "directory" then
      names[#names + 1] = name
    end
  end
  return names
end

-- True while `entry` is still a require-trigger candidate: enabled, and not
-- already mid-load or loaded by some other route. A disabled entry, or one
-- already loaded/loading, is never (re)loaded from here.
local function is_eligible(entry, state)
  return entry ~= nil and entry.enabled and state ~= nil and state.status ~= "loaded" and state.status ~= "loading"
end

-- Loaded entries retain provider precedence; entries mid-load may be required
-- by their dependencies. Shared namespaces keep dependency order.
local function build_top_map(ctx)
  local map = {}
  local unavailable = {}
  for _, entry in ipairs(ctx.sorted) do
    local state = ctx.entry_state[entry.name]
    if entry.enabled and state then
      local names = top_level_modules(entry)
      if not names and state.status ~= "loaded" then
        unavailable[#unavailable + 1] = entry
      end
      for _, top in ipairs(names or {}) do
        map[top] = map[top] or {}
        map[top][#map[top] + 1] = entry.name
      end
    end
  end
  return map, unavailable
end

local function module_path(entry, modname)
  local root = triggers_mod.resolve_root(entry)
  if type(root) ~= "string" or root == "" then
    return nil
  end
  local lua_dir = vim.fs.joinpath(root, "lua")
  return package.searchpath(modname, lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua")
end

-- Loader for `modname` straight from a mid-load `entry`'s own `lua/` dir, or
-- nil once its root is on 'runtimepath' (Neovim's rtp searcher handles it
-- then). An entry's dependencies load before its root reaches 'runtimepath'
-- (rtp order follows load order), and a dependency's plugin/after files may
-- require the entry itself (e.g. nvim-cmp sources requiring "cmp").
local function loading_entry_loader(entry, modname)
  local root = triggers_mod.resolve_root(entry)
  if type(root) ~= "string" or root == "" or vim.tbl_contains(vim.opt.rtp:get(), root) then
    return nil
  end
  local path = module_path(entry, modname)
  if not path then
    return nil
  end
  local chunk, err = loadfile(path)
  if not chunk then
    error(err)
  end
  return chunk
end

-- Load the owning entry, then let Neovim resolve the module from runtimepath.
-- A dependency can require its parent mid-load; serve that module directly.
local function searcher(modname)
  if not current then
    return nil
  end
  if not current.top_map then
    current.top_map, current.unavailable = build_top_map(current)
  else
    for _, entry in ipairs(current.unavailable) do
      local state = current.entry_state[entry.name]
      if entry.enabled and state and state.status ~= "loaded" and top_level_modules(entry) then
        current.top_map, current.unavailable = build_top_map(current)
        break
      end
    end
  end
  local top = modname:match("^[^.]+")
  local entry_name
  for _, name in ipairs(top and current.top_map[top] or {}) do
    if module_path(current.entries[name], modname) then
      entry_name = name
      break
    end
  end
  if not entry_name then
    return nil
  end
  local entry = current.entries[entry_name]
  local state = current.entry_state[entry_name]
  if entry and entry.enabled and state and state.status == "loading" then
    return loading_entry_loader(entry, modname)
  end
  if not is_eligible(entry, state) then
    return nil
  end
  if not current.load_entry(entry_name, "require:" .. modname) then
    return nil
  end
  -- A dependency's plugin/after file may have required `modname` while the entry loaded (see
  -- `loading_entry_loader`), which already cached it. Returning the message below would make `require()`
  -- evaluate the module a second time from rtp and split its state (e.g. two nvim-cmp cores).
  local cached = package.loaded[modname]
  if cached ~= nil then
    return function()
      return cached
    end
  end
  return string.format("\n\tdash_paq: loaded entry %q for %s, deferring to rtp search", entry_name, modname)
end

-- `opts`: `{ entries, sorted, entry_state, load_entry }` -- the loader's own
-- tables/closure. Called once, from the one allowed `setup()`.
function M.install(opts)
  current = {
    entries = opts.entries,
    sorted = opts.sorted,
    entry_state = opts.entry_state,
    load_entry = opts.load_entry,
    top_map = nil,
  }
  -- Neovim installs its runtimepath searcher at index 2 in _init_packages.lua.
  -- Run just before it so a deferred plugin reaches runtimepath in time.
  table.insert(package.loaders, 2, searcher)
end

return M
