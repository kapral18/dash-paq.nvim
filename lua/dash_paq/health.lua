-- `:checkhealth dash_paq`.
local M = {}

-- Minimum Neovim version this loader's tag resolution was verified against.
local MIN_VERSION = { major = 0, minor = 12, patch = 4 }
local MIN_VERSION_STR = string.format("%d.%d.%d", MIN_VERSION.major, MIN_VERSION.minor, MIN_VERSION.patch)

local function meets_min(v)
  if v.major ~= MIN_VERSION.major then
    return v.major > MIN_VERSION.major
  end
  if v.minor ~= MIN_VERSION.minor then
    return v.minor > MIN_VERSION.minor
  end
  return v.patch >= MIN_VERSION.patch
end

function M.check()
  local health = vim.health
  health.start("dash-paq.nvim")

  local ok, dash_paq = pcall(require, "dash_paq")
  if ok and dash_paq.is_configured() then
    health.ok("setup() has been called")
  else
    health.error("setup() has not been called; call require('dash_paq').setup(opts)")
  end

  local v = vim.version()
  local version_str = string.format("%d.%d.%d", v.major, v.minor, v.patch)
  if meets_min(v) then
    health.ok("Neovim " .. version_str .. " >= " .. MIN_VERSION_STR)
  else
    health.warn("Neovim " .. version_str .. " is below the tested minimum (" .. MIN_VERSION_STR .. ")")
  end

  if type(vim.pack) == "table" and type(vim.pack.add) == "function" then
    health.ok("vim.pack is available")
  else
    health.error("vim.pack is not available; dash-paq.nvim requires Neovim >= 0.12")
  end

  if vim.fn.executable("git") == 1 then
    health.ok("git found on PATH")
  else
    health.error("git not found on PATH; required for install/update/version-policy/dashboard analysis")
  end

  local state_dir = require("dash_paq.fs").state_dir()
  pcall(vim.fn.mkdir, state_dir, "p")
  -- `isdirectory` only proves the directory exists, not that it is writable
  -- (e.g. a read-only mount); `filewritable() == 2` is the directory result.
  if vim.fn.filewritable(state_dir) == 2 then
    health.ok("state directory writable: " .. state_dir)
  else
    health.error("state directory not writable: " .. state_dir)
  end
end

return M
