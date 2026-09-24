-- Loaded via `nvim --headless -u tests/minimal_init.lua -l <spec file>`.
-- Isolates every XDG-derived directory under a fresh temp dir and puts this repo's lua/ on 'runtimepath'.
local uv = vim.uv or vim.loop

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h:h")
end

local ROOT = repo_root()

local function tmp_base()
  local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  return string.format("%s/pack-companion-tests/%d-%d", base, uv.os_getpid(), math.floor(uv.hrtime()))
end

local TMP = tmp_base()

local function isolate_xdg(name, env_var)
  local dir = TMP .. "/" .. name
  vim.fn.mkdir(dir, "p")
  vim.env[env_var] = dir
  return dir
end

isolate_xdg("config", "XDG_CONFIG_HOME")
isolate_xdg("data", "XDG_DATA_HOME")
isolate_xdg("state", "XDG_STATE_HOME")
isolate_xdg("cache", "XDG_CACHE_HOME")
isolate_xdg("run", "XDG_RUNTIME_DIR")

vim.fn.mkdir(vim.fn.stdpath("config"), "p")
vim.fn.mkdir(vim.fn.stdpath("data"), "p")
vim.fn.mkdir(vim.fn.stdpath("state"), "p")

vim.opt.rtp = { vim.env.VIMRUNTIME, ROOT } -- not `--clean`: that leaves 'packpath' stale
-- VIMRUNTIME must stay on packpath, or :packadd default plugins (netrw) fail with E919.
vim.opt.packpath = { vim.env.VIMRUNTIME, vim.fs.joinpath(vim.fn.stdpath("data"), "site") }

package.path = ROOT .. "/tests/?.lua;" .. ROOT .. "/tests/?/init.lua;" .. package.path

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.loadplugins = true -- pack-companion must not require this to be false.

_G.PACK_COMPANION_TEST_ROOT = ROOT
_G.PACK_COMPANION_TEST_TMP = TMP
