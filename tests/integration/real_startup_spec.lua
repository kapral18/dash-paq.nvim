-- setup() called from a real init.lua, at real Neovim startup (v:vim_did_init == 0, not nvim -l's script mode).
-- Every plugin/**/after/plugin/** file (src, dir, a plain user plugin/, and a $VIMRUNTIME plugin) must be
-- ...sourced exactly once by VimEnter.
-- Runs a real child `nvim --headless -u <init.lua>` process with its own fresh, isolated XDG_*/stdpath dirs.
local t = require("runner")
local gitfixture = require("support.gitfixture")
local dirfixture = require("support.dirfixture")

local ROOT = _G.PACK_COMPANION_TEST_ROOT

local function fresh_dir(label)
  return dirfixture.fresh_dir("pack-companion-real-startup", label)
end

-- `src` fixture: real git remote with plugin/ + after/plugin/.
local srcplug = gitfixture.new_remote("realstartup-src")
gitfixture.commit(srcplug, "feat: initial plugin", {
  ["plugin/init.lua"] = [[
_G.PC_COUNTS.src_plugin = (_G.PC_COUNTS.src_plugin or 0) + 1
]],
  ["after/plugin/init.lua"] = [[
_G.PC_COUNTS.src_after = (_G.PC_COUNTS.src_after or 0) + 1
]],
})
gitfixture.push(srcplug)

-- `dir` fixture: plain directory, no git/vim.pack involvement at all.
local dirplug_root = fresh_dir("dirplug")
vim.fn.mkdir(vim.fs.joinpath(dirplug_root, "plugin"), "p")
vim.fn.mkdir(vim.fs.joinpath(dirplug_root, "after", "plugin"), "p")
vim.fn.writefile(
  { "_G.PC_COUNTS.dir_plugin = (_G.PC_COUNTS.dir_plugin or 0) + 1" },
  vim.fs.joinpath(dirplug_root, "plugin", "init.lua")
)
vim.fn.writefile(
  { "_G.PC_COUNTS.dir_after = (_G.PC_COUNTS.dir_after or 0) + 1" },
  vim.fs.joinpath(dirplug_root, "after", "plugin", "init.lua")
)

-- pack/*/start/* fixture: installed outside vim.pack entirely, directly under the isolated XDG_DATA_HOME packpath.
local startpkg_root = vim.fs.joinpath("nvim", "site", "pack", "x", "start", "sp")

-- ft-detecting dir fixture, reused below: plugin/, after/plugin/, and ftdetect/.
local ftdir_root = fresh_dir("ftdirplug")
vim.fn.mkdir(vim.fs.joinpath(ftdir_root, "ftdetect"), "p")
vim.fn.writefile(
  { [[vim.filetype.add({ extension = { pcdet = "pcdet" } })]] },
  vim.fs.joinpath(ftdir_root, "ftdetect", "pcdet.lua")
)

-- Isolated XDG dirs for the child process. A plugin/ file under the isolated config dir stands in for
-- a user's own plugin/ file, on Neovim's default rtp with no pack_companion involvement.
local xdg_config = fresh_dir("xdg-config")
local xdg_data = fresh_dir("xdg-data")
local xdg_state = fresh_dir("xdg-state")
local xdg_cache = fresh_dir("xdg-cache")
vim.fn.mkdir(vim.fs.joinpath(xdg_config, "nvim", "plugin"), "p")
vim.fn.writefile(
  { "_G.PC_COUNTS.user_plugin = (_G.PC_COUNTS.user_plugin or 0) + 1" },
  vim.fs.joinpath(xdg_config, "nvim", "plugin", "user_marker.lua")
)
vim.fn.mkdir(vim.fs.joinpath(xdg_config, "nvim", "after", "plugin"), "p")
vim.fn.writefile(
  { "_G.PC_COUNTS.user_after = (_G.PC_COUNTS.user_after or 0) + 1" },
  vim.fs.joinpath(xdg_config, "nvim", "after", "plugin", "user_after_marker.lua")
)

local startpkg_abs = vim.fs.joinpath(xdg_data, startpkg_root)
vim.fn.mkdir(vim.fs.joinpath(startpkg_abs, "plugin"), "p")
vim.fn.mkdir(vim.fs.joinpath(startpkg_abs, "after", "plugin"), "p")
vim.fn.writefile(
  { "_G.PC_COUNTS.startpkg_plugin = (_G.PC_COUNTS.startpkg_plugin or 0) + 1" },
  vim.fs.joinpath(startpkg_abs, "plugin", "init.lua")
)
vim.fn.writefile(
  { "_G.PC_COUNTS.startpkg_after = (_G.PC_COUNTS.startpkg_after or 0) + 1" },
  vim.fs.joinpath(startpkg_abs, "after", "plugin", "init.lua")
)

-- A plugin's after/ftplugin/<ft> must not override the user's own; the plugin's after/ dir must land ahead of
-- the user's config-dir after/ on rtp (source order: plugin, then user; last wins), not appended at the very end.
local afterorder_root = fresh_dir("afterorder")
vim.fn.mkdir(vim.fs.joinpath(afterorder_root, "after", "ftplugin"), "p")
vim.fn.writefile(
  { [[table.insert(_G.PC_AFTER_ORDER, "plugin")]] },
  vim.fs.joinpath(afterorder_root, "after", "ftplugin", "pcafter.lua")
)
vim.fn.mkdir(vim.fs.joinpath(xdg_config, "nvim", "after", "ftplugin"), "p")
vim.fn.writefile(
  { [[table.insert(_G.PC_AFTER_ORDER, "user")]] },
  vim.fs.joinpath(xdg_config, "nvim", "after", "ftplugin", "pcafter.lua")
)
local afterorder_pkg_abs = vim.fs.joinpath(xdg_data, "nvim", "site", "pack", "x", "opt", "afterorderpkg")
vim.fn.mkdir(vim.fs.joinpath(afterorder_pkg_abs, "after", "ftplugin"), "p")
vim.fn.writefile(
  { [[table.insert(_G.PC_AFTER_ORDER, "plugin")]] },
  vim.fs.joinpath(afterorder_pkg_abs, "after", "ftplugin", "pcafter.lua")
)

local out_path = fresh_dir("out") .. "/result.json"

local init_lines = {
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.PC_COUNTS = { src_plugin = 0, src_after = 0, dir_plugin = 0, dir_after = 0, user_plugin = 0 }",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  "  spec = {",
  string.format("    { src = %q, name = 'srcplug' },", srcplug.src),
  string.format("    { dir = %q },", dirplug_root),
  "  },",
  "})",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  callback = function()",
  "    vim.schedule(function()",
  string.format(
    "      vim.fn.writefile({ vim.json.encode({ counts = _G.PC_COUNTS, loaded_matchparen = vim.g.loaded_matchparen }) }, %q)",
    out_path
  ),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}
local init_path = fresh_dir("child-init") .. "/init.lua"
vim.fn.writefile(init_lines, init_path)

-- Shared low-level spawner: isolated XDG dirs and HOME, an arbitrary -u <init_path>, and optional extra CLI
-- args. Every scenario writes its own result JSON via a VimEnter (or later) callback and reads it back here.
local function spawn_child(init_path, extra_args, out_json_path)
  local env = vim.fn.environ()
  local home = fresh_dir("home")
  env.HOME = home
  env.XDG_CONFIG_HOME = xdg_config
  env.XDG_DATA_HOME = xdg_data
  env.XDG_STATE_HOME = xdg_state
  env.XDG_CACHE_HOME = xdg_cache
  local argv = { vim.v.progpath, "--headless", "-u", init_path }
  vim.list_extend(argv, extra_args or {})
  local result = vim.system(argv, { text = true, env = env, clear_env = true }):wait(20000)
  assert(result.code == 0, "child startup failed: " .. tostring(result.stderr))
  local lines = vim.fn.readfile(out_json_path)
  return vim.json.decode(table.concat(lines, "\n"))
end

local function run_child()
  return spawn_child(init_path, {}, out_path)
end

-- Run twice: the first installs srcplug via vim.pack.add; the second reuses the already-installed clone.
local first = run_child()
local second = run_child()

t.describe("setup() runs from a real init.lua at real Neovim startup", function()
  t.it("sources the src entry's plugin/** exactly once (first run)", function()
    t.assert.equals(1, first.counts.src_plugin)
  end)
  t.it("sources the src entry's after/plugin/** exactly once (first run)", function()
    t.assert.equals(1, first.counts.src_after)
  end)
  t.it("sources the dir entry's plugin/** exactly once (first run)", function()
    t.assert.equals(1, first.counts.dir_plugin)
  end)
  t.it("sources the dir entry's after/plugin/** exactly once (first run)", function()
    t.assert.equals(1, first.counts.dir_after)
  end)
  t.it("still sources a user's own config-dir plugin/ file exactly once (first run)", function()
    t.assert.equals(1, first.counts.user_plugin)
  end)
  t.it("still loads a $VIMRUNTIME-shipped plugin (matchparen) via Neovim's own native step", function()
    t.assert.equals(1, first.loaded_matchparen)
  end)
  t.it("loads a pack/*/start/* package's plugin/** (installed outside vim.pack)", function()
    t.assert.equals(1, first.counts.startpkg_plugin)
  end)
  t.it("loads a pack/*/start/* package's after/plugin/** (installed outside vim.pack)", function()
    t.assert.equals(1, first.counts.startpkg_after)
  end)

  t.it("sources every file exactly once again on a repeat run (already installed)", function()
    t.assert.equals(1, second.counts.src_plugin)
    t.assert.equals(1, second.counts.src_after)
    t.assert.equals(1, second.counts.dir_plugin)
    t.assert.equals(1, second.counts.dir_after)
    t.assert.equals(1, second.counts.user_plugin)
    t.assert.equals(1, second.loaded_matchparen)
    t.assert.equals(1, second.counts.startpkg_plugin)
    t.assert.equals(1, second.counts.startpkg_after)
  end)
end)

-- The user's own config-dir after/plugin/** must run as part of Neovim's native load-plugins step, before
-- -c commands run, not deferred to VimEnter (matches lazy.nvim and a bare vim.pack.add + setup()).
local after_order_result = spawn_child(init_path, {
  "-c",
  "lua _G.PC_COUNTS.after_before_dash_c = (_G.PC_COUNTS.user_after or 0) > 0",
}, out_path)

t.describe("a `-c` command runs after Neovim's own startup sequence", function()
  t.it("has already sourced the user config dir's after/plugin/** by then", function()
    t.assert.truthy(after_order_result.counts.after_before_dash_c)
  end)
end)

-- A global set after setup() returns (which a $VIMRUNTIME plugin checks to skip itself) must still be honored,
-- since Neovim's native load-plugins step only runs once init.lua finishes sourcing.
local late_global_init = fresh_dir("child-init-lateglobal") .. "/init.lua"
local late_global_out = fresh_dir("out-lateglobal") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  string.format("  spec = { { dir = %q, name = 'ftdirplug' } },", ftdir_root),
  "})",
  "vim.g.loaded_matchparen = 1",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  callback = function()",
  "    vim.schedule(function()",
  string.format(
    "      vim.fn.writefile({ vim.json.encode({ matchparen_augroup_exists = vim.fn.exists('#matchparen') }) }, %q)",
    late_global_out
  ),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}, late_global_init)
local late_global_result = spawn_child(late_global_init, {}, late_global_out)

t.describe("init.lua sets vim.g.loaded_matchparen = 1 after setup() returns", function()
  t.it("is honored by Neovim's native load-plugins step (matchparen never defines its augroup)", function()
    t.assert.equals(0, late_global_result.matchparen_augroup_exists)
  end)
end)

-- A dir entry's own ftdetect/ must be on rtp before Neovim's own :runtime! filetype.lua step runs.
local ftdetect_test_file = fresh_dir("ftdetect-buf") .. "/sample.pcdet"
vim.fn.writefile({ "x" }, ftdetect_test_file)
local ftdetect_init = fresh_dir("child-init-ftdetect") .. "/init.lua"
local ftdetect_out = fresh_dir("out-ftdetect") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  string.format("  spec = { { dir = %q, name = 'ftdirplug' } },", ftdir_root),
  "})",
  -- nested = true: without it, :edit below would not itself fire a nested filetypedetect autocmd.
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  nested = true,",
  "  callback = function()",
  string.format("    vim.cmd('edit %s')", ftdetect_test_file),
  "    vim.schedule(function()",
  string.format("      vim.fn.writefile({ vim.json.encode({ ft = vim.bo.filetype }) }, %q)", ftdetect_out),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}, ftdetect_init)
local ftdetect_result = spawn_child(ftdetect_init, {}, ftdetect_out)

t.describe("a `dir` entry's ftdetect/ defines a custom filetype", function()
  t.it("detects that filetype for a buffer of that extension", function()
    t.assert.equals("pcdet", ftdetect_result.ft)
  end)
end)

-- An uncaught error inside setup() must not prevent Neovim's own native load-plugins step from still running
-- for every other rtp entry, including $VIMRUNTIME; this loader never disables 'loadplugins'.
local badcmd_init = fresh_dir("child-init-badcmd") .. "/init.lua"
local badcmd_out = fresh_dir("out-badcmd") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  callback = function()",
  "    vim.schedule(function()",
  string.format(
    "      vim.fn.writefile({ vim.json.encode({ loaded_matchparen = vim.g.loaded_matchparen }) }, %q)",
    badcmd_out
  ),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  string.format("  spec = { { dir = %q, name = 'badcmdplug', cmd = 'lowercase' } },", ftdir_root),
  "})",
}, badcmd_init)
local badcmd_result = spawn_child(badcmd_init, {}, badcmd_out)

t.describe("setup() throws (an invalid cmd name)", function()
  t.it("still leaves $VIMRUNTIME plugins (matchparen) loaded", function()
    t.assert.equals(1, badcmd_result.loaded_matchparen)
  end)
end)

-- A keys entry whose rhs is known up front must keep working after the first press, not just once.
local rhskey_init = fresh_dir("child-init-rhskey") .. "/init.lua"
local rhskey_out = fresh_dir("out-rhskey") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.PC_COUNTS = { f9 = 0 }",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  string.format(
    "  spec = { { dir = %q, name = 'rhskeyplug', keys = { { '<F9>', '<cmd>lua _G.PC_COUNTS.f9 = _G.PC_COUNTS.f9 + 1<cr>' } } } },",
    ftdir_root
  ),
  "})",
  "vim.api.nvim_feedkeys(vim.keycode('<F9>'), 'mtx', false)",
  "vim.api.nvim_feedkeys(vim.keycode('<F9>'), 'mtx', false)",
  "vim.api.nvim_feedkeys(vim.keycode('<F9>'), 'mtx', false)",
  "vim.schedule(function()",
  string.format("  vim.fn.writefile({ vim.json.encode({ f9 = _G.PC_COUNTS.f9 }) }, %q)", rhskey_out),
  "  vim.cmd('qa!')",
  "end)",
}, rhskey_init)
local rhskey_result = spawn_child(rhskey_init, {}, rhskey_out)

t.describe("a `keys` entry with a known rhs is pressed three times", function()
  t.it("runs the rhs on every press, not just the first", function()
    t.assert.equals(3, rhskey_result.f9)
  end)
end)

-- An ft-deferred dir entry's own ftdetect/ must still detect its filetype from init.lua, even though
-- vim.g.did_load_filetypes is unset at registration time (this runs before Neovim's own filetype.lua).
local ftdeferinit_root = fresh_dir("ftdeferinit")
vim.fn.mkdir(vim.fs.joinpath(ftdeferinit_root, "ftdetect"), "p")
vim.fn.mkdir(vim.fs.joinpath(ftdeferinit_root, "plugin"), "p")
vim.fn.writefile(
  { [[vim.filetype.add({ extension = { pcdeferinit = "pcdeferinit" } })]] },
  vim.fs.joinpath(ftdeferinit_root, "ftdetect", "custom.lua")
)
vim.fn.writefile(
  { "_G.PC_COUNTS.ftdeferinit_loaded = (_G.PC_COUNTS.ftdeferinit_loaded or 0) + 1" },
  vim.fs.joinpath(ftdeferinit_root, "plugin", "init.lua")
)

local ftdeferinit_file = fresh_dir("ftdeferinit-buf") .. "/sample.pcdeferinit"
vim.fn.writefile({ "x" }, ftdeferinit_file)
local ftdeferinit_init = fresh_dir("child-init-ftdeferinit") .. "/init.lua"
local ftdeferinit_out = fresh_dir("out-ftdeferinit") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.PC_COUNTS = {}",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  string.format("  spec = { { dir = %q, name = 'ftdeferinitplug', ft = 'pcdeferinit' } },", ftdeferinit_root),
  "})",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  nested = true,",
  "  callback = function()",
  string.format("    vim.cmd('edit %s')", ftdeferinit_file),
  "    vim.schedule(function()",
  string.format(
    "      vim.fn.writefile({ vim.json.encode({ ft = vim.bo.filetype, loaded = _G.PC_COUNTS.ftdeferinit_loaded }) }, %q)",
    ftdeferinit_out
  ),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}, ftdeferinit_init)
local ftdeferinit_result = spawn_child(ftdeferinit_init, {}, ftdeferinit_out)

t.describe("an ft-deferred `dir` entry's own ftdetect/ defines its filetype from init.lua", function()
  t.it("detects the entry's own custom filetype", function()
    t.assert.equals("pcdeferinit", ftdeferinit_result.ft)
  end)
  t.it("loads the entry once its own filetype triggers", function()
    t.assert.equals(1, ftdeferinit_result.loaded)
  end)
end)

-- A deferred entry pulled in early as a dependency must not also get its own cmd/ft trigger registered, or
-- the stub collides with the dependency's real command and a later matching buffer double-fires its ftplugin.
local depB_root = fresh_dir("depB")
vim.fn.mkdir(vim.fs.joinpath(depB_root, "plugin"), "p")
vim.fn.mkdir(vim.fs.joinpath(depB_root, "ftplugin"), "p")
vim.fn.writefile({ "vim.cmd('command Bcmd let g:pc_bcmd_ran = 1')" }, vim.fs.joinpath(depB_root, "plugin", "init.lua"))
vim.fn.writefile(
  { "_G.PC_COUNTS.b_ftplugin = (_G.PC_COUNTS.b_ftplugin or 0) + 1" },
  vim.fs.joinpath(depB_root, "ftplugin", "pcb.lua")
)
local depA_root = fresh_dir("depA")
vim.fn.mkdir(vim.fs.joinpath(depA_root, "plugin"), "p")
vim.fn.writefile(
  { "_G.PC_COUNTS.a_plugin = (_G.PC_COUNTS.a_plugin or 0) + 1" },
  vim.fs.joinpath(depA_root, "plugin", "init.lua")
)

local depb_file = fresh_dir("depb-buf") .. "/sample.pcb"
vim.fn.writefile({ "x" }, depb_file)
local dep_init = fresh_dir("child-init-dep") .. "/init.lua"
local dep_out = fresh_dir("out-dep") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "vim.filetype.add({ extension = { pcb = 'pcb' } })",
  "_G.PC_COUNTS = {}",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  "  spec = {",
  string.format(
    "    { dir = %q, name = 'depA', dependencies = { { dir = %q, name = 'depB', cmd = 'Bcmd', ft = 'pcb' } } },",
    depA_root,
    depB_root
  ),
  "  },",
  "})",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  nested = true,",
  "  callback = function()",
  "    local ok, err = pcall(vim.cmd, 'Bcmd')",
  string.format("    vim.cmd('edit %s')", depb_file),
  "    vim.schedule(function()",
  string.format(
    "      vim.fn.writefile({ vim.json.encode({ ok = ok, err = tostring(err), bcmd_ran = vim.g.pc_bcmd_ran, b_ftplugin = _G.PC_COUNTS.b_ftplugin }) }, %q)",
    dep_out
  ),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}, dep_init)
local dep_result = spawn_child(dep_init, {}, dep_out)

t.describe("a deferred entry loads early as a startup entry's dependency", function()
  t.it("does not collide (E174) with the dependency's own real command", function()
    t.assert.truthy(dep_result.ok)
  end)
  t.it("runs the dependency's real command", function()
    t.assert.equals(1, dep_result.bcmd_ran)
  end)
  t.it("sources the dependency's ftplugin/ exactly once for a matching buffer (no replay double-fire)", function()
    t.assert.equals(1, dep_result.b_ftplugin)
  end)
end)

-- A build hook firing during init.lua (first install) must not double/triple-source plugin/**, and a deferred
-- entry's build hook must load it through load_entry (state becomes configured).
local buildstart_remote = gitfixture.new_remote("buildstart")
gitfixture.commit(buildstart_remote, "feat: initial", {
  ["plugin/init.lua"] = "_G.PC_COUNTS.bp_plugin = (_G.PC_COUNTS.bp_plugin or 0) + 1",
})
gitfixture.push(buildstart_remote)

local build_init = fresh_dir("child-init-build") .. "/init.lua"
local build_out = fresh_dir("out-build") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.PC_COUNTS = { bp_build_ran = 0 }",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  "  spec = {",
  string.format(
    "    { src = %q, name = 'buildstart', build = function() _G.PC_COUNTS.bp_build_ran = _G.PC_COUNTS.bp_build_ran + 1 end },",
    buildstart_remote.src
  ),
  "  },",
  "})",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  callback = function()",
  "    vim.schedule(function()",
  string.format("      vim.fn.writefile({ vim.json.encode(_G.PC_COUNTS) }, %q)", build_out),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}, build_init)
local build_result = spawn_child(build_init, {}, build_out)

t.describe("a build hook fires during init.lua (first install)", function()
  t.it("sources the plugin's plugin/** exactly once, not twice", function()
    t.assert.equals(1, build_result.bp_plugin)
  end)
  t.it("runs the build hook exactly once", function()
    t.assert.equals(1, build_result.bp_build_ran)
  end)
end)

-- At startup, rtp insertion order must equal load order: a dependency before its dependent, and a
-- higher-priority entry before a lower-priority one.
local orderA_root = fresh_dir("orderA")
vim.fn.mkdir(vim.fs.joinpath(orderA_root, "plugin"), "p")
vim.fn.writefile({ [[table.insert(_G.PC_ORDER, "orderA-plugin")]] }, vim.fs.joinpath(orderA_root, "plugin", "init.lua"))
local orderB_root = fresh_dir("orderB")
vim.fn.mkdir(vim.fs.joinpath(orderB_root, "plugin"), "p")
vim.fn.writefile({ [[table.insert(_G.PC_ORDER, "orderB-plugin")]] }, vim.fs.joinpath(orderB_root, "plugin", "init.lua"))
local prioLow_root = fresh_dir("prioLow")
vim.fn.mkdir(vim.fs.joinpath(prioLow_root, "plugin"), "p")
vim.fn.writefile(
  { [[table.insert(_G.PC_ORDER, "prioLow-plugin")]] },
  vim.fs.joinpath(prioLow_root, "plugin", "init.lua")
)
local prioHigh_root = fresh_dir("prioHigh")
vim.fn.mkdir(vim.fs.joinpath(prioHigh_root, "plugin"), "p")
vim.fn.writefile(
  { [[table.insert(_G.PC_ORDER, "prioHigh-plugin")]] },
  vim.fs.joinpath(prioHigh_root, "plugin", "init.lua")
)

-- Every entry also ships an empty after/ dir, so the multi-entry after/ insertion order (matching root
-- insertion order, not reversed or bunched at the end) is asserted across all four entries at once.
vim.fn.mkdir(vim.fs.joinpath(prioHigh_root, "after"), "p")
vim.fn.mkdir(vim.fs.joinpath(orderB_root, "after"), "p")
vim.fn.mkdir(vim.fs.joinpath(orderA_root, "after"), "p")
vim.fn.mkdir(vim.fs.joinpath(prioLow_root, "after"), "p")

local order_init = fresh_dir("child-init-order") .. "/init.lua"
local order_out = fresh_dir("out-order") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.PC_ORDER = {}",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  "  spec = {",
  string.format(
    "    { dir = %q, name = 'orderA', dependencies = { { dir = %q, name = 'orderB' } } },",
    orderA_root,
    orderB_root
  ),
  string.format("    { dir = %q, name = 'prioLow' },", prioLow_root),
  string.format("    { dir = %q, name = 'prioHigh', priority = 1000 },", prioHigh_root),
  "  },",
  "})",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  callback = function()",
  "    vim.schedule(function()",
  string.format(
    "      vim.fn.writefile({ vim.json.encode({ order = _G.PC_ORDER, rtp = vim.opt.rtp:get() }) }, %q)",
    order_out
  ),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}, order_init)
local order_result = spawn_child(order_init, {}, order_out)

local function index_of(list, value)
  for i, v in ipairs(list) do
    if v == value then
      return i
    end
  end
  return nil
end

t.describe("rtp insertion at startup covers a dependency and a priority difference", function()
  t.it("sources the dependency's plugin/ before its dependent's", function()
    local order = order_result.order or {}
    local b = index_of(order, "orderB-plugin")
    local a = index_of(order, "orderA-plugin")
    t.assert.truthy(b ~= nil and a ~= nil)
    t.assert.truthy(b < a)
  end)
  t.it("sources the higher-priority entry's plugin/ before the lower-priority one's", function()
    local order = order_result.order or {}
    local hi = index_of(order, "prioHigh-plugin")
    local lo = index_of(order, "prioLow-plugin")
    t.assert.truthy(hi ~= nil and lo ~= nil)
    t.assert.truthy(hi < lo)
  end)

  -- A dir entry must land where :packadd! would (right after the user config/site entry), not at the front.
  t.it("places a `dir` entry's directory after the user config dir, not before it", function()
    local rtp = order_result.rtp or {}
    local config_dir = index_of(rtp, vim.fs.joinpath(xdg_config, "nvim"))
    local dir_entry = index_of(rtp, orderA_root)
    t.assert.truthy(config_dir ~= nil and dir_entry ~= nil)
    t.assert.truthy(config_dir < dir_entry)
  end)

  -- Four entries this time, to catch a broken chain a two-entry check would miss.
  t.it("places every entry's after/ dir on 'runtimepath' in load order, all before the user config after", function()
    local rtp = order_result.rtp or {}
    local hi_after = index_of(rtp, vim.fs.joinpath(prioHigh_root, "after"))
    local b_after = index_of(rtp, vim.fs.joinpath(orderB_root, "after"))
    local a_after = index_of(rtp, vim.fs.joinpath(orderA_root, "after"))
    local lo_after = index_of(rtp, vim.fs.joinpath(prioLow_root, "after"))
    local user_after = index_of(rtp, vim.fs.joinpath(xdg_config, "nvim", "after"))
    t.assert.truthy(hi_after ~= nil and b_after ~= nil and a_after ~= nil and lo_after ~= nil and user_after ~= nil)
    -- Root insertion order (matching plugin/ load order): prioHigh, orderB, orderA, prioLow; each after must
    -- hold the same order, right after its own root.
    t.assert.truthy(hi_after < b_after)
    t.assert.truthy(b_after < a_after)
    t.assert.truthy(a_after < lo_after)
    t.assert.truthy(lo_after < user_after)
  end)
end)

-- This loader's own `dir` entry vs a real `:packadd!` control.
local afterorder_pc_init = fresh_dir("child-init-afterorder-pc") .. "/init.lua"
local afterorder_pc_out = fresh_dir("out-afterorder-pc") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.PC_COUNTS = {}",
  "_G.PC_AFTER_ORDER = {}",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  string.format("  spec = { { dir = %q, name = 'afterorderpc' } },", afterorder_root),
  "})",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  nested = true,",
  "  callback = function()",
  "    local buf = vim.api.nvim_create_buf(false, true)",
  "    vim.api.nvim_set_current_buf(buf)",
  "    vim.bo[buf].filetype = 'pcafter'",
  "    vim.schedule(function()",
  string.format("      vim.fn.writefile({ vim.json.encode({ order = _G.PC_AFTER_ORDER }) }, %q)", afterorder_pc_out),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}, afterorder_pc_init)
local afterorder_pc_result = spawn_child(afterorder_pc_init, {}, afterorder_pc_out)

local afterorder_native_init = fresh_dir("child-init-afterorder-native") .. "/init.lua"
local afterorder_native_out = fresh_dir("out-afterorder-native") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  "_G.PC_COUNTS = {}",
  "_G.PC_AFTER_ORDER = {}",
  "vim.cmd('packadd! afterorderpkg')",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  nested = true,",
  "  callback = function()",
  "    local buf = vim.api.nvim_create_buf(false, true)",
  "    vim.api.nvim_set_current_buf(buf)",
  "    vim.bo[buf].filetype = 'pcafter'",
  "    vim.schedule(function()",
  string.format(
    "      vim.fn.writefile({ vim.json.encode({ order = _G.PC_AFTER_ORDER }) }, %q)",
    afterorder_native_out
  ),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}, afterorder_native_init)
local afterorder_native_result = spawn_child(afterorder_native_init, {}, afterorder_native_out)

t.describe("a plugin ships after/ftplugin/<ft> and the user overrides the same filetype", function()
  t.it("sources the plugin's after/ftplugin/<ft> before the user's own (user wins)", function()
    t.assert.equals("plugin", (afterorder_pc_result.order or {})[1])
    t.assert.equals("user", (afterorder_pc_result.order or {})[2])
  end)
  t.it("matches a real :packadd! control's own order (same as plain vim.pack.add)", function()
    t.assert.equals("plugin", (afterorder_native_result.order or {})[1])
    t.assert.equals("user", (afterorder_native_result.order or {})[2])
  end)
end)

-- A startup entry's plugin/ fires a User autocmd synchronously mid native load-plugins step; a deferred
-- entry's event trigger loads in response. Its after/plugin/** must not be sourced twice.
local evtstart_dir = fresh_dir("evtstart")
vim.fn.mkdir(vim.fs.joinpath(evtstart_dir, "plugin"), "p")
vim.fn.writefile(
  { [[vim.api.nvim_exec_autocmds('User', { pattern = 'PcFromPlugin' })]] },
  vim.fs.joinpath(evtstart_dir, "plugin", "init.lua")
)

local evtdeferred_dir_dir = fresh_dir("evtdeferreddir")
vim.fn.mkdir(vim.fs.joinpath(evtdeferred_dir_dir, "plugin"), "p")
vim.fn.mkdir(vim.fs.joinpath(evtdeferred_dir_dir, "after", "plugin"), "p")
vim.fn.writefile(
  { "_G.PC_COUNTS.evtdeferred_dir_plugin = (_G.PC_COUNTS.evtdeferred_dir_plugin or 0) + 1" },
  vim.fs.joinpath(evtdeferred_dir_dir, "plugin", "init.lua")
)
vim.fn.writefile(
  { "_G.PC_COUNTS.evtdeferred_dir_after = (_G.PC_COUNTS.evtdeferred_dir_after or 0) + 1" },
  vim.fs.joinpath(evtdeferred_dir_dir, "after", "plugin", "init.lua")
)

local evtdeferredsrc_remote = gitfixture.new_remote("evtdeferredsrc")
gitfixture.commit(evtdeferredsrc_remote, "feat: initial", {
  ["plugin/init.lua"] = [[_G.PC_COUNTS.evtdeferred_src_plugin = (_G.PC_COUNTS.evtdeferred_src_plugin or 0) + 1]],
  ["after/plugin/init.lua"] = [[_G.PC_COUNTS.evtdeferred_src_after = (_G.PC_COUNTS.evtdeferred_src_after or 0) + 1]],
})
gitfixture.push(evtdeferredsrc_remote)

local evtorder_init = fresh_dir("child-init-evtorder") .. "/init.lua"
local evtorder_out = fresh_dir("out-evtorder") .. "/result.json"
vim.fn.writefile({
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.PC_COUNTS = {}",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  "  spec = {",
  string.format("    { dir = %q, name = 'evtstart' },", evtstart_dir),
  string.format(
    "    { dir = %q, name = 'evtdeferred_dir', event = { 'User', pattern = 'PcFromPlugin' } },",
    evtdeferred_dir_dir
  ),
  string.format(
    "    { src = %q, name = 'evtdeferred_src', event = { 'User', pattern = 'PcFromPlugin' } },",
    evtdeferredsrc_remote.src
  ),
  "  },",
  "})",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  callback = function()",
  "    vim.schedule(function()",
  string.format("      vim.fn.writefile({ vim.json.encode(_G.PC_COUNTS) }, %q)", evtorder_out),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
}, evtorder_init)
local evtorder_result = spawn_child(evtorder_init, {}, evtorder_out)

t.describe("a startup entry's plugin/ fires an event synchronously during native load-plugins", function()
  t.it("sources the deferred dir entry's plugin/** exactly once", function()
    t.assert.equals(1, evtorder_result.evtdeferred_dir_plugin)
  end)
  t.it(
    "sources the deferred dir entry's after/plugin/** exactly once (not doubled by the native after-pass)",
    function()
      t.assert.equals(1, evtorder_result.evtdeferred_dir_after)
    end
  )
  t.it("sources the deferred src entry's plugin/** exactly once", function()
    t.assert.equals(1, evtorder_result.evtdeferred_src_plugin)
  end)
  t.it(
    "sources the deferred src entry's after/plugin/** exactly once (not doubled by the native after-pass)",
    function()
      t.assert.equals(1, evtorder_result.evtdeferred_src_after)
    end
  )
end)

t.finish()
