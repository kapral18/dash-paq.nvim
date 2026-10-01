-- `:DashPaq[!] [subcommand] [args]`: the plugin's single user command.
-- The loader and the dashboard each register their own subcommands here, so
-- `opts.dashboard = false` leaves only the loader's. No subcommand opens the
-- dashboard (the `default` subcommand); `!` is only accepted where a
-- subcommand declares `bang = true`.
local M = {}

local COMMAND = "DashPaq"

---@class dash_paq.Subcommand
---@field impl fun(args: string[], opts: { bang: boolean, raw: string })
---@field complete? fun(arglead: string, args: string[]): string[]
---@field bang? boolean
---@field usage string shown in the usage error, e.g. "trace [plugin]"

---@type table<string, dash_paq.Subcommand>
local subcommands = {}
---@type dash_paq.Subcommand?
local default = nil
local created = false

-- Keeps candidates that contain `arglead`, sorted.
function M.filter(candidates, arglead)
  local out = {}
  for _, c in ipairs(candidates) do
    if arglead == "" or c:find(arglead, 1, true) then
      out[#out + 1] = c
    end
  end
  table.sort(out)
  return out
end

local function usage()
  local lines = {}
  if default then
    lines[#lines + 1] = ":" .. COMMAND .. default.usage
  end
  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  for _, name in ipairs(names) do
    lines[#lines + 1] = ":" .. COMMAND .. " " .. subcommands[name].usage
  end
  return "Usage:\n  " .. table.concat(lines, "\n  ")
end

local function run(cmd)
  local fargs = cmd.fargs
  local def
  local name = fargs[1]
  if name == nil then
    def = default
  else
    def = subcommands[name]
  end
  if not def then
    local what = name and ("unknown subcommand '" .. name .. "'") or "no subcommand given"
    vim.notify(COMMAND .. ": " .. what .. "\n" .. usage(), vim.log.levels.ERROR)
    return
  end
  if cmd.bang and not def.bang then
    vim.notify(COMMAND .. ": '!' is not valid for '" .. tostring(name) .. "'", vim.log.levels.ERROR)
    return
  end
  -- `raw` is everything after the subcommand name, untouched, so a path
  -- argument may contain spaces.
  local raw = name and vim.trim((cmd.args:gsub("^%s*%S+", "", 1))) or ""
  def.impl(vim.list_slice(fargs, 2), { bang = cmd.bang, raw = raw })
end

-- Completes `:DashPaq <sub> <args>`; `cmdline` is up to the cursor.
function M.complete(arglead, cmdline)
  local rest = cmdline:match("^%s*" .. COMMAND .. "!?%s+(.*)$")
  if not rest then
    return {}
  end
  local name, after = rest:match("^(%S+)%s+(.*)$")
  if not name then
    return M.filter(vim.tbl_keys(subcommands), arglead)
  end
  local def = subcommands[name]
  if not def or not def.complete then
    return {}
  end
  -- Arguments before the one being completed.
  local done = vim.split(after, "%s+", { trimempty = true })
  if arglead ~= "" then
    table.remove(done)
  end
  return def.complete(arglead, done)
end

local function ensure_command()
  if created then
    return
  end
  created = true
  vim.api.nvim_create_user_command(COMMAND, run, {
    nargs = "*",
    bang = true,
    complete = M.complete,
    desc = "dash-paq: dashboard, sync/status reports, load trace, lockfile, version policy",
  })
end

---@param name string
---@param def dash_paq.Subcommand
function M.register(name, def)
  subcommands[name] = def
  ensure_command()
end

-- The subcommand `:DashPaq` runs with no arguments; its `usage` is the
-- suffix after the command name, e.g. "[!]".
---@param def dash_paq.Subcommand
function M.register_default(def)
  default = def
  ensure_command()
end

return M
