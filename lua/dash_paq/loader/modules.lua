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
    return names
  end
  local handle = vim.uv.fs_scandir(vim.fs.joinpath(root, "lua"))
  if not handle then
    return names
  end
  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then
      break
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

-- Built lazily on the first `require()` miss (never scanned at startup):
-- one non-recursive `fs_scandir` per enabled, not-yet-loaded entry --
-- including one mid-load, whose dependencies may require it (see
-- `searcher`). `ctx.sorted` (not `pairs(ctx.entries)`) keeps the
-- "first entry wins" tie-break (two entries providing the same top-level
-- name) deterministic.
local function build_top_map(ctx)
  local map = {}
  for _, entry in ipairs(ctx.sorted) do
    local state = ctx.entry_state[entry.name]
    if entry.enabled and state and state.status ~= "loaded" then
      for _, top in ipairs(top_level_modules(entry)) do
        if not map[top] then
          map[top] = entry.name
        end
      end
    end
  end
  return map
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
  local lua_dir = vim.fs.joinpath(root, "lua")
  local path = package.searchpath(modname, lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua")
  if not path then
    return nil
  end
  local chunk, err = loadfile(path)
  if not chunk then
    error(err)
  end
  return chunk
end

-- `package.loaders` searcher. On a miss owned by a still-eligible entry,
-- loads it and returns a plain message -- not a loader function -- so
-- `require()` keeps walking the remaining searchers, which now find the
-- module on rtp themselves (see `M.install` for exactly where this runs
-- relative to Neovim's own rtp searcher). On a miss owned by an entry
-- that is mid-load, returns a loader from its root (see
-- `loading_entry_loader`) instead of loading it again.
local function searcher(modname)
  if not current then
    return nil
  end
  if not current.top_map then
    current.top_map = build_top_map(current)
  end
  local top = modname:match("^[^.]+")
  local entry_name = top and current.top_map[top]
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
  current.load_entry(entry_name, "require:" .. modname)
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
  -- $VIMRUNTIME/lua/vim/_init_packages.lua inserts Neovim's own rtp
  -- searcher, `vim._load_package`, at `package.loaders[2]` (`table.insert
  -- (package.loaders, 2, vim._load_package)`, right after the stock
  -- preload searcher at [1]). Inserting this searcher at the same index 2
  -- pushes that rtp searcher to [3], so a miss reaches this searcher
  -- first -- the entry's root then lands on rtp *before* the rtp searcher
  -- itself runs (on the very next searcher, since this one returns a
  -- string rather than a loader function).
  table.insert(package.loaders, 2, searcher)
end

return M
