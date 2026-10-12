-- A deferred entry whose trigger fires after Neovim's native load-plugins step but before VimEnter must have its
-- after/plugin/** sourced immediately, not queued to VimEnter (too late for the triggering buffer/command).
-- Runs real child `nvim --headless -p <file>...` processes (this spec's own `nvim -l` can't reproduce that window)
-- with fresh, isolated XDG_*/HOME dirs; `-p` opens every argv file so all of them load, not just the first.
local t = require("runner")
local gitfixture = require("support.gitfixture")
local dirfixture = require("support.dirfixture")

local ROOT = _G.DASH_PAQ_TEST_ROOT

local function fresh_dir(label)
  return dirfixture.fresh_dir("dash-paq-deferwin", label)
end

-- ft-deferred dir entry: trigger fires from the argv .lua file's native FileType event, before VimEnter.
local ftdefer_dir_root = fresh_dir("ftdefer-dir")
dirfixture.write(
  ftdefer_dir_root,
  "plugin/init.lua",
  [[_G.DASH_PAQ_TEST.counts.ftdefer_dir_plugin = (_G.DASH_PAQ_TEST.counts.ftdefer_dir_plugin or 0) + 1]]
)
dirfixture.write(
  ftdefer_dir_root,
  "after/plugin/init.lua",
  [[_G.DASH_PAQ_TEST.counts.ftdefer_dir_after = (_G.DASH_PAQ_TEST.counts.ftdefer_dir_after or 0) + 1]]
)

-- Same scenario as a src entry (resolved via vim.pack.get, not a literal dir path).
local ftdefer_src = gitfixture.new_remote("deferwin-ftdefer-src")
gitfixture.commit(ftdefer_src, "feat: initial", {
  ["plugin/init.lua"] = [[_G.DASH_PAQ_TEST.counts.ftdefer_src_plugin = (_G.DASH_PAQ_TEST.counts.ftdefer_src_plugin or 0) + 1]],
  ["after/plugin/init.lua"] = [[_G.DASH_PAQ_TEST.counts.ftdefer_src_after = (_G.DASH_PAQ_TEST.counts.ftdefer_src_after or 0) + 1]],
})
gitfixture.push(ftdefer_src)

-- Event(BufReadPost)-deferred dir entry: isolates the event-trigger route from the ft-trigger route above.
local evtdefer_dir_root = fresh_dir("evtdefer-dir")
dirfixture.write(
  evtdefer_dir_root,
  "plugin/init.lua",
  [[_G.DASH_PAQ_TEST.counts.evtdefer_dir_plugin = (_G.DASH_PAQ_TEST.counts.evtdefer_dir_plugin or 0) + 1]]
)
dirfixture.write(
  evtdefer_dir_root,
  "after/plugin/init.lua",
  [[_G.DASH_PAQ_TEST.counts.evtdefer_dir_after = (_G.DASH_PAQ_TEST.counts.evtdefer_dir_after or 0) + 1]]
)

-- cmd trigger after VimEnter: sources immediately.
local postvim_dir_root = fresh_dir("postvim-dir")
dirfixture.write(
  postvim_dir_root,
  "plugin/init.lua",
  [[_G.DASH_PAQ_TEST.counts.postvim_plugin = (_G.DASH_PAQ_TEST.counts.postvim_plugin or 0) + 1]]
)
dirfixture.write(
  postvim_dir_root,
  "after/plugin/init.lua",
  [[_G.DASH_PAQ_TEST.counts.postvim_after = (_G.DASH_PAQ_TEST.counts.postvim_after or 0) + 1]]
)

-- Event-deferred entry whose own after/plugin/** registers grouped BufReadPost+FileType autocmds; both must fire
-- once for the triggering buffer (BufReadPost via this loader's replay, FileType natively with no replay needed).
local grouped_argv_root = fresh_dir("grouped-argv-dir")
dirfixture.write(grouped_argv_root, "after/plugin/init.lua", {
  "local grp = vim.api.nvim_create_augroup('dw_grouped_after', { clear = true })",
  "vim.api.nvim_create_autocmd('BufReadPost', {",
  "  group = grp,",
  "  pattern = '*.lua',",
  "  callback = function()",
  "    _G.DASH_PAQ_TEST.counts.grouped_bufreadpost = (_G.DASH_PAQ_TEST.counts.grouped_bufreadpost or 0) + 1",
  "  end,",
  "})",
  "vim.api.nvim_create_autocmd('FileType', {",
  "  group = grp,",
  "  pattern = 'lua',",
  "  callback = function()",
  "    _G.DASH_PAQ_TEST.counts.grouped_filetype = (_G.DASH_PAQ_TEST.counts.grouped_filetype or 0) + 1",
  "  end,",
  "})",
})

-- Startup dir entry whose plugin/init.lua fires a User event nested inside Neovim's own native load-plugins pass.
local nested_outer_root = fresh_dir("nested-outer-dir")
dirfixture.write(
  nested_outer_root,
  "plugin/init.lua",
  [[vim.api.nvim_exec_autocmds('User', { pattern = 'DashPaqNestedTrigger' })]]
)

-- User-event-deferred entry loaded from nested_outer_root's plugin/init.lua above; its root lands on 'runtimepath'
-- mid native load, so this loader must queue its after/plugin/** instead of also sourcing it, or it sources twice.
local nested_evt_root = fresh_dir("nested-evt-dir")
dirfixture.write(
  nested_evt_root,
  "plugin/init.lua",
  [[_G.DASH_PAQ_TEST.counts.nested_plugin = (_G.DASH_PAQ_TEST.counts.nested_plugin or 0) + 1]]
)
dirfixture.write(
  nested_evt_root,
  "after/plugin/init.lua",
  [[_G.DASH_PAQ_TEST.counts.nested_after = (_G.DASH_PAQ_TEST.counts.nested_after or 0) + 1]]
)

-- Reused by both the ft-deferred entries above (FileType trigger) and the grouped-autocmd entry (BufReadPost).
local lua_argv_file = fresh_dir("argv-lua") .. "/sample.lua"
vim.fn.writefile({ "-- sample" }, lua_argv_file)
local brp_argv_file = fresh_dir("argv-brp") .. "/sample.dashpaqbrp"
vim.fn.writefile({ "x" }, brp_argv_file)

local out_path = fresh_dir("out") .. "/result.json"

local init_lines = {
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.DASH_PAQ_TEST = { counts = {} }",
  "require('dash_paq').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  "  spec = {",
  string.format("    { dir = %q, name = 'dw_ftdefer_dir', ft = 'lua' },", ftdefer_dir_root),
  string.format("    { src = %q, name = 'dw_ftdefer_src', ft = 'lua' },", ftdefer_src.src),
  string.format(
    "    { dir = %q, name = 'dw_evtdefer_dir', event = { 'BufReadPost', pattern = '*.dashpaqbrp' } },",
    evtdefer_dir_root
  ),
  string.format(
    "    { dir = %q, name = 'dw_postvim_dir', cmd = 'DashPaqPostVimCmd', "
      .. "config = function() vim.api.nvim_create_user_command('DashPaqPostVimCmd', function() end, {}) end },",
    postvim_dir_root
  ),
  string.format(
    "    { dir = %q, name = 'dw_grouped_argv', event = { 'BufReadPost', pattern = '*.lua' } },",
    grouped_argv_root
  ),
  string.format("    { dir = %q, name = 'dw_nested_outer' },", nested_outer_root),
  string.format(
    "    { dir = %q, name = 'dw_nested_evt', event = { 'User', pattern = 'DashPaqNestedTrigger' } },",
    nested_evt_root
  ),
  "  },",
  "})",
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  callback = function()",
  "    vim.cmd('DashPaqPostVimCmd')",
  "    vim.schedule(function()",
  string.format("      vim.fn.writefile({ vim.json.encode(_G.DASH_PAQ_TEST) }, %q)", out_path),
  "      vim.cmd('qa!')",
  "    end)",
  "  end,",
  "})",
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
  local argv = { vim.v.progpath, "--headless", "-u", init_path, "-p", lua_argv_file, brp_argv_file }
  local result = vim.system(argv, { text = true, env = env, clear_env = true }):wait(30000)
  assert(result.code == 0, "child startup failed: " .. tostring(result.stderr))
  local lines = vim.fn.readfile(out_path)
  return vim.json.decode(table.concat(lines, "\n"))
end

local r = spawn_child()

t.describe("a ft-deferred entry's trigger fires from an argv file, before VimEnter", function()
  t.it("sources the dir entry's plugin/** once", function()
    t.assert.equals(1, r.counts.ftdefer_dir_plugin)
  end)
  t.it("sources the dir entry's after/plugin/** once, immediately", function()
    t.assert.equals(1, r.counts.ftdefer_dir_after)
  end)
  t.it("sources the src entry's plugin/** once", function()
    t.assert.equals(1, r.counts.ftdefer_src_plugin)
  end)
  t.it("sources the src entry's after/plugin/** once, immediately", function()
    t.assert.equals(1, r.counts.ftdefer_src_after)
  end)
end)

t.describe("an event(BufReadPost)-deferred entry's trigger fires from an argv file", function()
  t.it("sources the entry's plugin/** once", function()
    t.assert.equals(1, r.counts.evtdefer_dir_plugin)
  end)
  t.it("sources the entry's after/plugin/** once, immediately", function()
    t.assert.equals(1, r.counts.evtdefer_dir_after)
  end)
end)

t.describe("a cmd-deferred entry's trigger fires after VimEnter (v:vim_did_enter == 1)", function()
  t.it("sources the entry's plugin/** once", function()
    t.assert.equals(1, r.counts.postvim_plugin)
  end)
  t.it("sources the entry's after/plugin/** once, immediately", function()
    t.assert.equals(1, r.counts.postvim_after)
  end)
end)

t.describe(
  "an event(BufReadPost)-deferred entry's own after/plugin/** registers grouped BufReadPost+FileType "
    .. "autocmds for the triggering argv buffer",
  function()
    t.it("fires the grouped BufReadPost autocmd once for that buffer (via this loader's event replay)", function()
      t.assert.equals(1, r.counts.grouped_bufreadpost)
    end)
    t.it("fires the grouped FileType autocmd once for that buffer (native, no replay needed)", function()
      t.assert.equals(1, r.counts.grouped_filetype)
    end)
  end
)

t.describe(
  "a User-event-deferred entry loads nested inside a startup entry's own plugin/init.lua "
    .. "(mid native load-plugins non-after sub-pass)",
  function()
    t.it("sources the entry's plugin/** exactly once", function()
      t.assert.equals(1, r.counts.nested_plugin)
    end)
    t.it("sources the entry's after/plugin/** exactly once, not twice", function()
      t.assert.equals(1, r.counts.nested_after)
    end)
  end
)

-- Separate child: a cmd-deferred entry triggered from a +cmd command-line command, strictly before VimEnter fires.
-- The real command (defined by config()) must see after/plugin/** already sourced, same as any other load route.
local cmdwindow_root = fresh_dir("cmdwindow-dir")
dirfixture.write(cmdwindow_root, "after/plugin/init.lua", [[_G.DASH_PAQ_AFTER_RAN = true]])

local cmdwindow_out_path = fresh_dir("cmdwindow-out") .. "/result.json"
local cmdwindow_init_lines = {
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "_G.DASH_PAQ_AFTER_RAN = false",
  "require('dash_paq').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  "  spec = {",
  string.format(
    "    { dir = %q, name = 'dw_cmdwindow', cmd = 'DashPaqCmdWindow', config = function() "
      .. "vim.api.nvim_create_user_command('DashPaqCmdWindow', function() "
      .. string.format(
        "vim.fn.writefile({ vim.json.encode({ saw_after = _G.DASH_PAQ_AFTER_RAN }) }, %q) ",
        cmdwindow_out_path
      )
      .. "end, {}) end },",
    cmdwindow_root
  ),
  "  },",
  "})",
}
local cmdwindow_init_path = fresh_dir("cmdwindow-child-init") .. "/init.lua"
vim.fn.writefile(cmdwindow_init_lines, cmdwindow_init_path)

local function spawn_cmdwindow_child()
  local env = vim.fn.environ()
  env.HOME = fresh_dir("cmdwindow-home")
  env.XDG_CONFIG_HOME = fresh_dir("cmdwindow-xdg-config")
  env.XDG_DATA_HOME = fresh_dir("cmdwindow-xdg-data")
  env.XDG_STATE_HOME = fresh_dir("cmdwindow-xdg-state")
  env.XDG_CACHE_HOME = fresh_dir("cmdwindow-xdg-cache")
  local argv = { vim.v.progpath, "--headless", "-u", cmdwindow_init_path, "+DashPaqCmdWindow", "+qa" }
  local result = vim.system(argv, { text = true, env = env, clear_env = true }):wait(30000)
  assert(result.code == 0, "cmd-window child startup failed: " .. tostring(result.stderr))
  local lines = vim.fn.readfile(cmdwindow_out_path)
  return vim.json.decode(table.concat(lines, "\n"))
end

local rc = spawn_cmdwindow_child()

t.describe("a cmd-deferred entry's trigger fires from a +cmd command-line command, before VimEnter", function()
  t.it("has sourced the entry's after/plugin/** before the real command body runs", function()
    t.assert.equals(true, rc.saw_after)
  end)
end)

t.finish()
