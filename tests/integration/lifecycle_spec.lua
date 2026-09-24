-- The loader lifecycle's route x kind matrix: every way an entry can load (startup, a dependency, a cmd/key/
-- event/ft trigger, :PackLoad, a build hook, or a trigger during init.lua after setup() returned), for both a
-- src (git) and a dir entry, against one real `nvim --headless -u <init.lua>` startup with isolated XDG/HOME.
local t = require("runner")
local gitfixture = require("support.gitfixture")
local dirfixture = require("support.dirfixture")

local ROOT = _G.PACK_COMPANION_TEST_ROOT

local function fresh_dir(label)
  return dirfixture.fresh_dir("pack-companion-lifecycle", label)
end

-- src fixtures (real local git remotes, no network).

local startsrc = gitfixture.new_remote("lc-startsrc")
gitfixture.commit(startsrc, "feat: initial", {
  ["plugin/init.lua"] = [[_G.PC.counts.startsrc_plugin = (_G.PC.counts.startsrc_plugin or 0) + 1]],
  ["after/plugin/init.lua"] = [[_G.PC.counts.startsrc_after = (_G.PC.counts.startsrc_after or 0) + 1]],
  ["lua/lcstartsrcmod/init.lua"] = [[
local M = {}
function M.hi()
  _G.PC.log[#_G.PC.log + 1] = "startsrc-config-ok"
end
return M
]],
})
gitfixture.push(startsrc)

local cmdtrigsrc = gitfixture.new_remote("lc-cmdtrigsrc")
gitfixture.commit(cmdtrigsrc, "feat: initial", {
  ["plugin/init.lua"] = [[_G.PC.counts.cmdtrigsrc_plugin = (_G.PC.counts.cmdtrigsrc_plugin or 0) + 1]],
})
gitfixture.push(cmdtrigsrc)

local fttrigsrc = gitfixture.new_remote("lc-fttrigsrc")
gitfixture.commit(fttrigsrc, "feat: initial", {
  ["plugin/init.lua"] = [[_G.PC.counts.fttrigsrc_plugin = (_G.PC.counts.fttrigsrc_plugin or 0) + 1]],
  ["after/plugin/init.lua"] = [[_G.PC.counts.fttrigsrc_after = (_G.PC.counts.fttrigsrc_after or 0) + 1]],
  ["ftdetect/custom.lua"] = [[
vim.filetype.add({ extension = { lcft = "lcft" } })
_G.PC.counts.fttrigsrc_ftdetect = (_G.PC.counts.fttrigsrc_ftdetect or 0) + 1
]],
})
gitfixture.push(fttrigsrc)

local startbuild = gitfixture.new_remote("lc-startbuild")
gitfixture.commit(startbuild, "feat: initial", {
  ["plugin/init.lua"] = [[_G.PC.counts.startbuild_plugin = (_G.PC.counts.startbuild_plugin or 0) + 1]],
})
gitfixture.push(startbuild)

local msbuild = gitfixture.new_remote("lc-msbuild")
gitfixture.commit(msbuild, "feat: initial", {
  ["plugin/init.lua"] = [[_G.PC.counts.msbuild_plugin = (_G.PC.counts.msbuild_plugin or 0) + 1]],
})
gitfixture.push(msbuild)

-- dir fixtures (plain directories).

local depstart_dir = fresh_dir("depstart")
dirfixture.write(
  depstart_dir,
  "plugin/init.lua",
  [[_G.PC.counts.depstart_plugin = (_G.PC.counts.depstart_plugin or 0) + 1]]
)

local startdirmain_dir = fresh_dir("startdirmain")
dirfixture.write(
  startdirmain_dir,
  "plugin/init.lua",
  [[_G.PC.counts.startdirmain_plugin = (_G.PC.counts.startdirmain_plugin or 0) + 1]]
)
dirfixture.write(startdirmain_dir, "lua/lcstartdirmainmod/init.lua", {
  "local M = {}",
  "function M.hi()",
  [[  _G.PC.log[#_G.PC.log + 1] = "startdirmain-config-ok"]],
  "end",
  "return M",
})

local startlazyfalsekeys_dir = fresh_dir("startlazyfalsekeys")
dirfixture.write(
  startlazyfalsekeys_dir,
  "plugin/init.lua",
  [[_G.PC.counts.startlazyfalsekeys_plugin = (_G.PC.counts.startlazyfalsekeys_plugin or 0) + 1]]
)

local depdeferdep_dir = fresh_dir("depdeferdep")
dirfixture.write(
  depdeferdep_dir,
  "plugin/init.lua",
  [[_G.PC.counts.depdeferdep_plugin = (_G.PC.counts.depdeferdep_plugin or 0) + 1]]
)

local deferwithdep_dir = fresh_dir("deferwithdep")
dirfixture.write(
  deferwithdep_dir,
  "plugin/init.lua",
  [[_G.PC.counts.deferwithdep_plugin = (_G.PC.counts.deferwithdep_plugin or 0) + 1]]
)

local keytrig_dir = fresh_dir("keytrig")
dirfixture.write(
  keytrig_dir,
  "plugin/init.lua",
  [[_G.PC.counts.keytrig_plugin = (_G.PC.counts.keytrig_plugin or 0) + 1]]
)

local eventfiletrig_dir = fresh_dir("eventfiletrig")
dirfixture.write(
  eventfiletrig_dir,
  "plugin/init.lua",
  [[_G.PC.counts.eventfiletrig_plugin = (_G.PC.counts.eventfiletrig_plugin or 0) + 1]]
)

local eventpatterntrig_dir = fresh_dir("eventpatterntrig")
dirfixture.write(
  eventpatterntrig_dir,
  "plugin/init.lua",
  [[_G.PC.counts.eventpatterntrig_plugin = (_G.PC.counts.eventpatterntrig_plugin or 0) + 1]]
)

local ftkeytrig_dir = fresh_dir("ftkeytrig")
dirfixture.write(
  ftkeytrig_dir,
  "plugin/init.lua",
  [[_G.PC.counts.ftkeytrig_plugin = (_G.PC.counts.ftkeytrig_plugin or 0) + 1]]
)

-- lhs-only key whose plugin never redefines it: the stub must be gone before the replay, or it recurses forever.
local unreplacedkeytrig_dir = fresh_dir("unreplacedkeytrig")
dirfixture.write(
  unreplacedkeytrig_dir,
  "plugin/init.lua",
  [[_G.PC.counts.unreplacedkeytrig_plugin = (_G.PC.counts.unreplacedkeytrig_plugin or 0) + 1]]
)

local packloadtrig_dir = fresh_dir("packloadtrig")
dirfixture.write(
  packloadtrig_dir,
  "plugin/init.lua",
  [[_G.PC.counts.packloadtrig_plugin = (_G.PC.counts.packloadtrig_plugin or 0) + 1]]
)

local lateload_dir = fresh_dir("lateload")
dirfixture.write(
  lateload_dir,
  "plugin/init.lua",
  [[_G.PC.counts.lateload_plugin = (_G.PC.counts.lateload_plugin or 0) + 1]]
)
dirfixture.write(lateload_dir, "lua/lclatemod/init.lua", {
  "local M = {}",
  "function M.hi()",
  [[  _G.PC.log[#_G.PC.log + 1] = "lateload-config-ok"]],
  "end",
  "return M",
})

-- ft-deferred dependency of lc_lateload: also declares its own ft trigger, and gets pulled onto rtp early by
-- the dependency load while still sourcing init.lua.
local lateftdep_dir = fresh_dir("lateftdep")
dirfixture.write(
  lateftdep_dir,
  "plugin/init.lua",
  [[_G.PC.counts.lateftdep_plugin = (_G.PC.counts.lateftdep_plugin or 0) + 1]]
)
dirfixture.write(lateftdep_dir, "ftdetect/custom.lua", {
  "vim.filetype.add({ extension = { lclateftdep = 'lclateftdep' } })",
  "_G.PC.counts.lateftdep_ftdetect = (_G.PC.counts.lateftdep_ftdetect or 0) + 1",
})

-- Files for the event-file / ft-trigger buffer scenarios below.
local eventfile_target = fresh_dir("eventfile-buf") .. "/sample.lcevfile"
vim.fn.writefile({ "x" }, eventfile_target)
local ft_target_a = fresh_dir("ft-buf-a") .. "/a.lcft"
vim.fn.writefile({ "x" }, ft_target_a)
local ft_target_b = fresh_dir("ft-buf-b") .. "/b.lcft"
vim.fn.writefile({ "x" }, ft_target_b)

local out_path = fresh_dir("out") .. "/result.json"

-- Child init.lua.

local init_lines = {
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.PC = { counts = {}, log = {}, checks = {} }",
  [[_G.PC_EXPR = function() _G.PC.counts.f3_expr = (_G.PC.counts.f3_expr or 0) + 1 return "" end]],
  "vim.filetype.add({ extension = { lcft2 = 'lcft2' } })",
  "require('pack_companion').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  "  spec = {",
  -- Startup, src kind: config requires its own module, so the entry must already be on rtp.
  string.format(
    "    { src = %q, name = 'lc_startsrc', priority = 100, config = function() "
      .. "local ok, m = pcall(require, 'lcstartsrcmod'); if ok then m.hi() else "
      .. "_G.PC.log[#_G.PC.log + 1] = 'startsrc-require-failed' end end },",
    startsrc.src
  ),
  -- Dependency of a startup entry (dir), pulled in before its dependent.
  string.format("    { dir = %q, name = 'lc_depstart' },", depstart_dir),
  -- Startup, dir kind, same rtp-before-config requirement; depends on the entry above.
  string.format(
    "    { dir = %q, name = 'lc_startdirmain', priority = 60, "
      .. "dependencies = { { dir = %q, name = 'lc_depstart' } }, "
      .. "config = function() local ok, m = pcall(require, 'lcstartdirmainmod'); "
      .. "if ok then m.hi() else _G.PC.log[#_G.PC.log + 1] = 'startdirmain-require-failed' end end },",
    startdirmain_dir,
    depstart_dir
  ),
  -- Startup, lazy = false + keys: every key with rhs must become a real mapping regardless.
  string.format(
    "    { dir = %q, name = 'lc_startlazyfalsekeys', lazy = false, priority = 10, "
      .. "keys = { { '<F21>', function() _G.PC.counts.f21 = (_G.PC.counts.f21 or 0) + 1 end } } },",
    startlazyfalsekeys_dir
  ),
  -- Startup with a build hook: must run on VimEnter with the plugin already loaded.
  string.format(
    "    { src = %q, name = 'lc_startbuild', build = function() "
      .. "_G.PC.checks.startbuild_loaded_at_build = (_G.PC.counts.startbuild_plugin or 0) > 0; "
      .. "_G.PC.counts.startbuild_build = (_G.PC.counts.startbuild_build or 0) + 1 end },",
    startbuild.src
  ),
  -- Dependency of a deferred entry: only loads when the deferred entry does.
  string.format("    { dir = %q, name = 'lc_depdeferdep' },", depdeferdep_dir),
  string.format(
    "    { dir = %q, name = 'lc_deferwithdep', cmd = 'LcDeferDepCmd', "
      .. "dependencies = { { dir = %q, name = 'lc_depdeferdep' } }, "
      .. "config = function() vim.api.nvim_create_user_command('LcDeferDepCmd', function() "
      .. "_G.PC.counts.deferwithdep_cmd_ran = (_G.PC.counts.deferwithdep_cmd_ran or 0) + 1 end, {}) end },",
    deferwithdep_dir,
    depdeferdep_dir
  ),
  -- cmd trigger, `src` kind: the plugin defines its own real command.
  string.format(
    "    { src = %q, name = 'lc_cmdtrigsrc', cmd = 'LcCmdTrig', "
      .. "config = function() vim.api.nvim_create_user_command('LcCmdTrig', function() "
      .. "_G.PC.counts.cmdtrigsrc_cmd_ran = (_G.PC.counts.cmdtrigsrc_cmd_ran or 0) + 1 end, {}) end },",
    cmdtrigsrc.src
  ),
  -- Multi-key entry: function/string/expr/lhs-only rhs, plus an operator-pending lhs-only key (mode n+o).
  string.format(
    "    { dir = %q, name = 'lc_keytrig', keys = {"
      .. " { '<F1>', function() _G.PC.counts.f1 = (_G.PC.counts.f1 or 0) + 1 end },"
      .. " { '<F2>', '<cmd>lua _G.PC.counts.f2 = (_G.PC.counts.f2 or 0) + 1<cr>' },"
      .. " { '<F3>', 'v:lua.PC_EXPR()', expr = true },"
      .. " { '<F4>' },"
      .. " { '<F22>', mode = { 'n', 'o' } },"
      .. " }, config = function()"
      .. " vim.keymap.set('n', '<F4>', function() _G.PC.counts.f4 = (_G.PC.counts.f4 or 0) + 1 end)"
      .. " vim.keymap.set({ 'n', 'o' }, '<F22>', 'e', {})"
      .. " end },",
    keytrig_dir
  ),
  -- Event trigger, file event (matched by buffer).
  string.format(
    "    { dir = %q, name = 'lc_eventfiletrig', event = { 'BufEnter', pattern = '*.lcevfile' } },",
    eventfiletrig_dir
  ),
  -- Event trigger, pattern-match event (`User`).
  string.format(
    "    { dir = %q, name = 'lc_eventpatterntrig', event = { 'User', pattern = 'LcUserEvent' } },",
    eventpatterntrig_dir
  ),
  -- ft trigger, src kind, own ftdetect/ (sourced exactly once, even for a src entry).
  string.format("    { src = %q, name = 'lc_fttrigsrc', ft = 'lcft' },", fttrigsrc.src),
  -- ft-scoped key on a separate entry, not tied to this entry's own ftdetect.
  string.format(
    "    { dir = %q, name = 'lc_ftkeytrig', keys = { { '<F9>', function() "
      .. "_G.PC.counts.f9 = (_G.PC.counts.f9 or 0) + 1 end, ft = 'lcft2' } } },",
    ftkeytrig_dir
  ),
  -- lhs-only key, no config: the replay must not recurse into a stub that should already be gone.
  string.format("    { dir = %q, name = 'lc_unreplacedkeytrig', keys = { { '<F30>' } } },", unreplacedkeytrig_dir),
  -- `:PackLoad` only (no other trigger at all).
  string.format("    { dir = %q, name = 'lc_packloadtrig', lazy = true },", packloadtrig_dir),
  -- Deferred cmd + build, first install (mason-shaped).
  string.format(
    "    { src = %q, name = 'lc_msbuild', cmd = 'LcMs', build = ':LcMsUpdate', opts = {}, "
      .. "config = function()"
      .. " vim.api.nvim_create_user_command('LcMs', function() "
      .. "_G.PC.counts.ms_ran = (_G.PC.counts.ms_ran or 0) + 1 end, {})"
      .. " vim.api.nvim_create_user_command('LcMsUpdate', function() "
      .. "_G.PC.counts.msupdate_ran = (_G.PC.counts.msupdate_ran or 0) + 1 end, {})"
      .. " end },",
    msbuild.src
  ),
  -- Loaded during init.lua after setup() returned, triggered by vim.cmd.colorscheme(...) below.
  string.format(
    "    { dir = %q, name = 'lc_lateload', event = 'ColorScheme', "
      .. "dependencies = { { dir = %q, name = 'lc_lateftdep', ft = 'lclateftdep' } }, "
      .. "config = function() "
      .. "local ok, m = pcall(require, 'lclatemod'); if ok then m.hi() else "
      .. "_G.PC.log[#_G.PC.log + 1] = 'lateload-require-failed' end end },",
    lateload_dir,
    lateftdep_dir
  ),
  "  },",
  "})",
  -- Capture rtp order right after setup() returns, before any deferred load inserts anything else.
  [[local function rtp_idx_dir(path) local expanded = vim.fn.expand(path) for i, p in ipairs(vim.opt.rtp:get()) do if p == expanded then return i end end return -1 end]],
  [[local function rtp_idx_src(name) local ok, info = pcall(vim.pack.get, { name }, { info = false }) if ok and info[1] then for i, p in ipairs(vim.opt.rtp:get()) do if p == info[1].path then return i end end end return -1 end]],
  "_G.PC.rtp_idx = {",
  "  startsrc = rtp_idx_src('lc_startsrc'),",
  string.format("  depstart = rtp_idx_dir(%q),", depstart_dir),
  string.format("  startdirmain = rtp_idx_dir(%q),", startdirmain_dir),
  string.format("  startlazyfalsekeys = rtp_idx_dir(%q),", startlazyfalsekeys_dir),
  "  startbuild = rtp_idx_src('lc_startbuild'),",
  "}",
  -- vim.cmd.colorscheme fires ColorScheme, still while v:vim_did_init == 0.
  "vim.cmd.colorscheme('habamax')",
  "vim.api.nvim_create_autocmd('VimEnter', { nested = true, callback = function()",
  "  vim.schedule(function()",
  "    local function press(k) vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false) end",
  -- Fire F1 (loads), F2 (real mapping, not a dead stub), F3 (expr), F4 (lhs-only replay), d<F22> (operator-pending).
  "    press('<F1>')",
  "    press('<F2>')",
  "    press('<F3>')",
  "    press('<F4>')",
  -- Startup lazy=false+keys entry: real mapping set at startup load, no key trigger of its own.
  "    press('<F21>')",
  -- lhs-only key, no config redefinition: must load exactly once, not hang.
  "    press('<F30>')",
  "    local opbuf = vim.api.nvim_create_buf(false, true)",
  "    vim.api.nvim_set_current_buf(opbuf)",
  "    vim.api.nvim_buf_set_lines(opbuf, 0, -1, false, { 'hello world foo' })",
  "    vim.api.nvim_win_set_cursor(0, { 1, 0 })",
  "    press('d<F22>')",
  "    _G.PC.checks.f22_delete_result = vim.api.nvim_buf_get_lines(opbuf, 0, -1, false)[1]",
  -- Dependency of a deferred entry.
  "    vim.cmd('LcDeferDepCmd')",
  -- cmd trigger (`src`).
  "    vim.cmd('LcCmdTrig')",
  -- Event triggers.
  string.format("    vim.cmd('edit %s')", eventfile_target),
  "    vim.api.nvim_exec_autocmds('User', { pattern = 'LcUserEvent' })",
  -- ft trigger (src, own ftdetect) — two buffers, ftdetect must fire once.
  string.format("    vim.cmd('edit %s')", ft_target_a),
  "    _G.PC.checks.lcft_a = vim.bo.filetype",
  string.format("    vim.cmd('edit %s')", ft_target_b),
  "    _G.PC.checks.lcft_b = vim.bo.filetype",
  -- ft-scoped key: press in the first lcft2 buffer, confirm the mapping is also set in a second one, unpressed.
  "    local ftbuf1 = vim.api.nvim_create_buf(true, false)",
  "    vim.api.nvim_set_current_buf(ftbuf1)",
  "    vim.bo[ftbuf1].filetype = 'lcft2'",
  "    press('<F9>')",
  "    local ftbuf2 = vim.api.nvim_create_buf(true, false)",
  "    vim.api.nvim_set_current_buf(ftbuf2)",
  "    vim.bo[ftbuf2].filetype = 'lcft2'",
  "    _G.PC.checks.f9_mapped_buf2 = vim.fn.maparg('<F9>', 'n', false, true).callback ~= nil",
  "    press('<F9>')",
  -- `:PackLoad`.
  "    vim.cmd('PackLoad lc_packloadtrig')",
  -- Build already ran (queued to this VimEnter); confirm the real Ms command still works afterward.
  "    _G.PC.checks.ms_exists_before_manual_call = vim.fn.exists(':LcMs')",
  "    vim.cmd('LcMs')",
  string.format("    vim.fn.writefile({ vim.json.encode(_G.PC) }, %q)", out_path),
  "    vim.cmd('qa!')",
  "  end)",
  "end })",
}

local init_path = fresh_dir("child-init") .. "/init.lua"
vim.fn.writefile(init_lines, init_path)

local function spawn_child()
  local env = vim.fn.environ()
  local home = fresh_dir("home")
  env.HOME = home
  env.XDG_CONFIG_HOME = fresh_dir("xdg-config")
  env.XDG_DATA_HOME = fresh_dir("xdg-data")
  env.XDG_STATE_HOME = fresh_dir("xdg-state")
  env.XDG_CACHE_HOME = fresh_dir("xdg-cache")
  local argv = { vim.v.progpath, "--headless", "-u", init_path }
  local result = vim.system(argv, { text = true, env = env, clear_env = true }):wait(30000)
  assert(result.code == 0, "child startup failed: " .. tostring(result.stderr))
  local lines = vim.fn.readfile(out_path)
  return vim.json.decode(table.concat(lines, "\n"))
end

local r = spawn_child()

t.describe("plugin/** and after/plugin/** are sourced exactly once, every route", function()
  t.it("sources the startup src entry's plugin/** and after/plugin/** once", function()
    t.assert.equals(1, r.counts.startsrc_plugin)
    t.assert.equals(1, r.counts.startsrc_after)
  end)
  t.it("sources the dependency-of-startup entry's plugin/** once", function()
    t.assert.equals(1, r.counts.depstart_plugin)
  end)
  t.it("sources the startup dir entry's plugin/** once", function()
    t.assert.equals(1, r.counts.startdirmain_plugin)
  end)
  t.it("sources the lazy=false+keys entry's plugin/** once", function()
    t.assert.equals(1, r.counts.startlazyfalsekeys_plugin)
  end)
  t.it("sources the dependency-of-deferred entry's plugin/** once", function()
    t.assert.equals(1, r.counts.depdeferdep_plugin)
  end)
  t.it("sources the deferred entry's plugin/** once (dep route)", function()
    t.assert.equals(1, r.counts.deferwithdep_plugin)
  end)
  t.it("sources the cmd-triggered src entry's plugin/** once", function()
    t.assert.equals(1, r.counts.cmdtrigsrc_plugin)
  end)
  t.it("sources the key-triggered entry's plugin/** once", function()
    t.assert.equals(1, r.counts.keytrig_plugin)
  end)
  t.it("sources the file-event-triggered entry's plugin/** once", function()
    t.assert.equals(1, r.counts.eventfiletrig_plugin)
  end)
  t.it("sources the pattern-event-triggered entry's plugin/** once", function()
    t.assert.equals(1, r.counts.eventpatterntrig_plugin)
  end)
  t.it("sources the ft-triggered src entry's plugin/** and after/plugin/** once", function()
    t.assert.equals(1, r.counts.fttrigsrc_plugin)
    t.assert.equals(1, r.counts.fttrigsrc_after)
  end)
  t.it("sources the ft-key entry's plugin/** once", function()
    t.assert.equals(1, r.counts.ftkeytrig_plugin)
  end)
  t.it("sources the :PackLoad entry's plugin/** once", function()
    t.assert.equals(1, r.counts.packloadtrig_plugin)
  end)
  t.it("sources the build startup entry's plugin/** once", function()
    t.assert.equals(1, r.counts.startbuild_plugin)
  end)
  t.it("sources the deferred build (mason-shaped) entry's plugin/** once", function()
    t.assert.equals(1, r.counts.msbuild_plugin)
  end)
  t.it("sources the load-during-init-after-setup entry's plugin/** once", function()
    t.assert.equals(1, r.counts.lateload_plugin)
  end)
end)

t.describe("config()/opts run with the entry and its deps already on 'runtimepath'", function()
  t.it("lets a startup src entry's config require its own module", function()
    t.assert.truthy(vim.tbl_contains(r.log, "startsrc-config-ok"))
  end)
  t.it("does not report a require failure for the startup src entry", function()
    t.assert.falsy(vim.tbl_contains(r.log, "startsrc-require-failed"))
  end)
  t.it("lets a startup dir entry (with a dependency) require its own module", function()
    t.assert.truthy(vim.tbl_contains(r.log, "startdirmain-config-ok"))
  end)
  t.it("lets an entry loaded during init after setup() returned require its own module", function()
    t.assert.truthy(vim.tbl_contains(r.log, "lateload-config-ok"))
  end)
end)

t.describe("no stub remains after load; real commands/keys work on every route", function()
  t.it("runs the dependency-of-deferred entry's real command", function()
    t.assert.equals(1, r.counts.deferwithdep_cmd_ran)
  end)
  t.it("runs the src cmd-triggered entry's real command", function()
    t.assert.equals(1, r.counts.cmdtrigsrc_cmd_ran)
  end)
  t.it("runs the function-rhs key (first key of a multi-key entry)", function()
    t.assert.equals(1, r.counts.f1)
  end)
  t.it("runs the string-rhs key (second key of the same multi-key entry)", function()
    t.assert.equals(1, r.counts.f2)
  end)
  t.it("evaluates the expr-rhs key's real mapping (not feed raw expression text)", function()
    t.assert.equals(1, r.counts.f3_expr)
  end)
  t.it("replays a lhs-only key into the plugin's own real mapping", function()
    t.assert.equals(1, r.counts.f4)
  end)
  t.it("applies an operator-pending lhs-only key on the very first press (operator not cancelled)", function()
    t.assert.equals(" world foo", r.checks.f22_delete_result)
  end)
  t.it("runs the lazy=false+keys entry's real key mapping", function()
    t.assert.equals(1, r.counts.f21)
  end)
  t.it("loads an lhs-only key trigger with no config redefinition exactly once, without recursing", function()
    t.assert.equals(1, r.counts.unreplacedkeytrig_plugin)
  end)
  t.it("detects the ft entry's custom filetype for both buffers", function()
    t.assert.equals("lcft", r.checks.lcft_a)
    t.assert.equals("lcft", r.checks.lcft_b)
  end)
  t.it("sets the ft-scoped key's real mapping for a later buffer of that filetype too", function()
    t.assert.truthy(r.checks.f9_mapped_buf2)
  end)
  t.it("runs the ft-scoped key's rhs in both the loading buffer and a later buffer", function()
    t.assert.equals(2, r.counts.f9)
  end)
  t.it("loads and configures the :PackLoad entry", function()
    t.assert.equals(1, r.counts.packloadtrig_plugin)
  end)
  t.it("has the build entry's real Ms command defined before it is manually invoked", function()
    t.assert.equals(2, r.checks.ms_exists_before_manual_call)
  end)
  t.it("still runs the real Ms command after the build (config()'s command was not deleted)", function()
    t.assert.equals(1, r.counts.ms_ran)
  end)
end)

t.describe("startup 'runtimepath' order equals load order", function()
  t.it("puts the highest-priority startup src entry ahead of a lower-priority one", function()
    t.assert.truthy(r.rtp_idx.startsrc < r.rtp_idx.startlazyfalsekeys)
  end)
  t.it("puts a dependency ahead of its dependent", function()
    t.assert.truthy(r.rtp_idx.depstart < r.rtp_idx.startdirmain)
  end)
  t.it("puts a higher-priority startup entry ahead of a lower-priority one (dir vs dir)", function()
    t.assert.truthy(r.rtp_idx.startdirmain < r.rtp_idx.startlazyfalsekeys)
  end)
  t.it("has inserted every tracked startup root (none missing from 'runtimepath')", function()
    t.assert.truthy(r.rtp_idx.startsrc > 0)
    t.assert.truthy(r.rtp_idx.depstart > 0)
    t.assert.truthy(r.rtp_idx.startdirmain > 0)
    t.assert.truthy(r.rtp_idx.startlazyfalsekeys > 0)
    t.assert.truthy(r.rtp_idx.startbuild > 0)
  end)
end)

t.describe("an entry's own ftdetect/ is sourced exactly once", function()
  t.it("sources the src ft-triggered entry's ftdetect/ exactly once, across two buffers", function()
    t.assert.equals(1, r.counts.fttrigsrc_ftdetect)
  end)
  t.it(
    "sources an ft-deferred entry's ftdetect/ exactly once when pulled in as a dependency during init after setup() returned",
    function()
      t.assert.equals(1, r.counts.lateftdep_ftdetect)
    end
  )
end)

t.describe("build runs with the plugin loaded, once per install", function()
  t.it("runs the startup entry's build exactly once", function()
    t.assert.equals(1, r.counts.startbuild_build)
  end)
  t.it("has the plugin already loaded when the startup entry's build runs", function()
    t.assert.truthy(r.checks.startbuild_loaded_at_build)
  end)
  t.it("runs the deferred cmd+build (mason-shaped) entry's build exactly once on first install", function()
    t.assert.equals(1, r.counts.msupdate_ran)
  end)
end)

t.describe("an entry loaded during init after setup() returned is on rtp, plugin/ runs once", function()
  t.it("has sourced its plugin/** exactly once", function()
    t.assert.equals(1, r.counts.lateload_plugin)
  end)
  t.it("has had it on 'runtimepath' in time for its own require() to succeed", function()
    t.assert.truthy(vim.tbl_contains(r.log, "lateload-config-ok"))
  end)
end)

t.finish()
