-- Deferred-trigger mechanics that need no real vim.pack install: cmd stub forwarding, event-trigger replay
-- scoped to the just-loaded plugin's own groups, lhs-only keys replay, and ft-deferred ftdetect/ sourcing.
local t = require("runner")
local dirfixture = require("support.dirfixture")
local gitfixture = require("support.gitfixture")

_G.DASH_PAQ_TEST_LOG = {}
_G.DASH_PAQ_CMD_CAPTURE = nil

local cmd_dir = dirfixture.new("cmdplug", dirfixture.marker_plugin_files("cmdplug-loaded"))
local event_dir = dirfixture.new("eventplug", dirfixture.marker_plugin_files("eventplug-loaded"))
local keys_dir = dirfixture.new("keysplug", dirfixture.marker_plugin_files("keysplug-loaded"))
local buf_dir = dirfixture.new("bufplug", dirfixture.marker_plugin_files("bufplug-loaded"))
local ft_keys_dir = dirfixture.new("ftkeysplug", dirfixture.marker_plugin_files("ftkeysplug-loaded"))
local unreplaced_keys_dir =
  dirfixture.new("unreplacedkeysplug", dirfixture.marker_plugin_files("unreplacedkeysplug-loaded"))

-- A plugin whose file errors when sourced: the error must reach vim.notify, not be swallowed by the pcall guard.
local errplug_dir = dirfixture.new("errplug", { ["plugin/init.lua"] = "error('boom-errplug')" })

-- cmd-triggered entries defining a real Vimscript `command X`: :X must run it after load, for dir and src both.
local vimcmddir_dir = dirfixture.new("vimcmddir", {
  ["plugin/init.vim"] = "command VimCmdDir let g:pc_vimcmddir_ran = get(g:, 'pc_vimcmddir_ran', 0) + 1",
})

local vimcmdsrc_remote = gitfixture.new_remote("vimcmdsrc")
gitfixture.commit(vimcmdsrc_remote, "feat: initial", {
  ["plugin/init.vim"] = "command VimCmdSrc let g:pc_vimcmdsrc_ran = get(g:, 'pc_vimcmdsrc_ran', 0) + 1",
})
gitfixture.push(vimcmdsrc_remote)

-- ft-deferred entry with its own ftdetect/: never on rtp until it loads, so nothing else would source it.
local ftdetect_defer_dir =
  dirfixture.new("ftdetectdeferplug", dirfixture.marker_plugin_files("ftdetectdeferplug-loaded"))
vim.fn.mkdir(vim.fs.joinpath(ftdetect_defer_dir, "ftdetect"), "p")
vim.fn.writefile(
  { [[vim.filetype.add({ extension = { pcdeferfixture = "pcdeferfixture" } })]] },
  vim.fs.joinpath(ftdetect_defer_dir, "ftdetect", "custom.lua")
)

-- ft-deferred entry with its own native ftplugin/after-ftplugin: the ft trigger's replay must run the native
-- filetypeplugin augroup once for the loading buffer; a later buffer gets its own native run, no replay needed.
local ftplugin_defer_dir = dirfixture.new("ftpluginplug", dirfixture.marker_plugin_files("ftpluginplug-loaded"))
vim.fn.mkdir(vim.fs.joinpath(ftplugin_defer_dir, "ftplugin"), "p")
vim.fn.mkdir(vim.fs.joinpath(ftplugin_defer_dir, "after", "ftplugin"), "p")
vim.fn.writefile(
  { "_G.PC_FTPLUGIN_COUNT = (_G.PC_FTPLUGIN_COUNT or 0) + 1" },
  vim.fs.joinpath(ftplugin_defer_dir, "ftplugin", "pcftpluginlang.lua")
)
vim.fn.writefile(
  { "_G.PC_AFTER_FTPLUGIN_COUNT = (_G.PC_AFTER_FTPLUGIN_COUNT or 0) + 1" },
  vim.fs.joinpath(ftplugin_defer_dir, "after", "ftplugin", "pcftpluginlang.lua")
)

-- Deferred entry triggered by a non-file pattern-match event (ColorScheme): the replay must re-resolve via
-- `pattern = ev.match`, not `buffer = ev.buf`, or it would never match a pattern-scoped autocmd.
local colorscheme_dir = dirfixture.new("colorschemeplug", dirfixture.marker_plugin_files("colorschemeplug-loaded"))
local colorscheme_handler_count = 0

-- keys with a string rhs and expr=true: the stub must set the real expr mapping first, not feed the raw text.
local expr_keys_dir = dirfixture.new("exprkeysplug", dirfixture.marker_plugin_files("exprkeysplug-loaded"))
_G.PCX_COUNT = 0
_G.PCX = function()
  _G.PCX_COUNT = _G.PCX_COUNT + 1
  return ""
end

-- keys with a plain string rhs: the real mapping must be noremap, even on the very first press.
local noremap_keys_dir = dirfixture.new("noremapkeysplug", dirfixture.marker_plugin_files("noremapkeysplug-loaded"))

-- lhs-only keys with mode {n, o}: the stub must stay expr=true so an operator-pending use doesn't cancel it.
local op_keys_dir = dirfixture.new("opkeysplug", dirfixture.marker_plugin_files("opkeysplug-loaded"))

local unrelated_count = 0
local new_handler_count = 0
local md_handler_count = 0

vim.api.nvim_create_autocmd("User", {
  pattern = "FixtureFire",
  callback = function()
    unrelated_count = unrelated_count + 1
  end,
})

-- A stock Vimscript autocmd (no id/callback) for the same event bufplug defers on: nvim_get_autocmds never
-- populates `id` for it, so a snapshot keyed on au.id (not group) would raise "table index is nil".
vim.cmd("autocmd BufEnter * let g:pc_test_vimscript_bufenter = get(g:, 'pc_test_vimscript_bufenter', 0) + 1")

require("dash_paq").setup({
  spec = {
    {
      dir = cmd_dir,
      name = "cmdplug",
      cmd = "FixtureCmd",
      config = function()
        vim.api.nvim_create_user_command("FixtureCmd", function(ctx)
          _G.DASH_PAQ_CMD_CAPTURE = {
            bang = ctx.bang,
            args = ctx.args,
            mods = ctx.mods,
            range = ctx.range,
            line1 = ctx.line1,
            line2 = ctx.line2,
          }
        end, { nargs = "*", bang = true, range = true })
      end,
    },
    {
      dir = event_dir,
      name = "eventplug",
      event = { "User", pattern = "FixtureFire" },
      config = function()
        -- In its own augroup, since the replay is scoped to newly-created groups, not individual autocmd ids.
        vim.api.nvim_create_autocmd("User", {
          group = vim.api.nvim_create_augroup("fixture_eventplug", { clear = true }),
          pattern = "FixtureFire",
          callback = function()
            new_handler_count = new_handler_count + 1
          end,
        })
      end,
    },
    {
      dir = keys_dir,
      name = "keysplug",
      keys = { { "<leader>zz" } }, -- lhs-only: no rhs.
      config = function()
        vim.keymap.set("n", "<leader>zz", function()
          table.insert(_G.DASH_PAQ_TEST_LOG, "keysplug-real-mapping-ran")
        end)
      end,
    },
    {
      dir = buf_dir,
      name = "bufplug",
      event = "BufEnter",
      config = function()
        -- Patterned + once handler: replay must honor both (matching buffer, first time only).
        vim.api.nvim_create_autocmd("BufEnter", {
          group = vim.api.nvim_create_augroup("fixture_bufplug", { clear = true }),
          pattern = "*.pcmdfixture",
          once = true,
          callback = function()
            md_handler_count = md_handler_count + 1
          end,
        })
      end,
    },
    {
      -- lhs-only, ft-scoped: the plugin maps the lhs globally, so the buffer-local stub must be deleted before
      -- load or it would shadow the real mapping instead of the replay reaching it.
      dir = ft_keys_dir,
      name = "ftkeysplug",
      keys = { { "<F6>", ft = "pcfixturelang" } },
      config = function()
        vim.keymap.set("n", "<F6>", function()
          table.insert(_G.DASH_PAQ_TEST_LOG, "ftkeysplug-global-mapping-ran")
        end)
      end,
    },
    {
      -- lhs-only key, never redefined: the stub must still be deleted before load, or the replay recurses.
      dir = unreplaced_keys_dir,
      name = "unreplacedkeysplug",
      keys = { { "<F5>" } },
    },
    {
      dir = ftdetect_defer_dir,
      name = "ftdetectdeferplug",
      ft = "pcdeferfixture",
    },
    {
      dir = ftplugin_defer_dir,
      name = "ftpluginplug",
      ft = "pcftpluginlang",
    },
    {
      dir = colorscheme_dir,
      name = "colorschemeplug",
      event = "ColorScheme",
      config = function()
        vim.api.nvim_create_autocmd("ColorScheme", {
          group = vim.api.nvim_create_augroup("fixture_colorschemeplug", { clear = true }),
          pattern = "pcfixturescheme",
          callback = function()
            colorscheme_handler_count = colorscheme_handler_count + 1
          end,
        })
      end,
    },
    {
      dir = expr_keys_dir,
      name = "exprkeysplug",
      keys = { { "<F7>", "v:lua.PCX()", expr = true } },
    },
    {
      dir = noremap_keys_dir,
      name = "noremapkeysplug",
      keys = { { "<F8>", "j" } },
    },
    {
      dir = op_keys_dir,
      name = "opkeysplug",
      keys = { { "<F2>", mode = { "n", "o" } } },
      config = function()
        vim.keymap.set({ "n", "o" }, "<F2>", "e", {})
      end,
    },
    {
      dir = errplug_dir,
      name = "errplug",
      cmd = "FixtureErrCmd",
    },
    {
      dir = vimcmddir_dir,
      name = "vimcmddir",
      cmd = "VimCmdDir",
    },
    {
      src = vimcmdsrc_remote.src,
      name = "vimcmdsrc",
      cmd = "VimCmdSrc",
    },
  },
  dashboard = false,
  version_policy = false,
})

t.describe("a deferred cmd-triggered plugin's command is invoked", function()
  t.it("does not source the plugin before the command runs", function()
    t.assert.falsy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "cmdplug-loaded"))
  end)

  -- Buffer needs >=10 lines for a `5,10` range to be valid.
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn["repeat"]({ "x" }, 12))
  vim.cmd("vertical 5,10FixtureCmd! foo bar")

  t.it("loads the plugin on first invocation", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "cmdplug-loaded"))
  end)

  t.it("forwards <bang> to the real command", function()
    t.assert.truthy(_G.DASH_PAQ_CMD_CAPTURE ~= nil)
    t.assert.equals(true, _G.DASH_PAQ_CMD_CAPTURE.bang)
  end)

  t.it("forwards args to the real command", function()
    t.assert.equals("foo bar", _G.DASH_PAQ_CMD_CAPTURE.args)
  end)

  t.it("forwards <mods> to the real command", function()
    t.assert.equals("vertical", _G.DASH_PAQ_CMD_CAPTURE.mods)
  end)

  t.it("forwards the range to the real command", function()
    t.assert.equals(5, _G.DASH_PAQ_CMD_CAPTURE.line1)
    t.assert.equals(10, _G.DASH_PAQ_CMD_CAPTURE.line2)
  end)
end)

t.describe("an event trigger fires and the loaded plugin adds its own handler for the same event", function()
  vim.api.nvim_exec_autocmds("User", { pattern = "FixtureFire" })

  t.it("loads the deferred plugin exactly once", function()
    local count = 0
    for _, m in ipairs(_G.DASH_PAQ_TEST_LOG) do
      if m == "eventplug-loaded" then
        count = count + 1
      end
    end
    t.assert.equals(1, count)
  end)

  t.it("runs the plugin's own newly-registered handler exactly once (replay)", function()
    t.assert.equals(1, new_handler_count)
  end)

  t.it("does not re-fire the pre-existing unrelated handler for the same event", function()
    t.assert.equals(1, unrelated_count)
  end)
end)

t.describe("a lhs-only `keys` trigger is pressed", function()
  vim.api.nvim_feedkeys(vim.keycode("<leader>zz"), "mtx", false)

  t.it("loads the plugin", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "keysplug-loaded"))
  end)

  t.it("replays the lhs so the plugin's real mapping runs", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "keysplug-real-mapping-ran"))
  end)
end)

-- Runs before any other buffer-switching test below, so bufplug's BufEnter trigger fires first on this buffer.
t.describe("a BufEnter trigger fires alongside a pre-existing Vimscript autocmd for the same event", function()
  -- Opened first, and does not match bufplug's own pattern; a replay bypassing pattern/buffer matching would
  -- incorrectly fire on this buffer too.
  vim.cmd("edit fixture-nomatch.pctxtfixture")

  t.it("does not replay the plugin's patterned handler for a non-matching buffer", function()
    t.assert.equals(0, md_handler_count)
  end)

  vim.cmd("edit fixture.pcmdfixture")

  t.it("does not error despite the Vimscript (id-less) autocmd sharing the event", function()
    t.assert.truthy(vim.g.pc_test_vimscript_bufenter ~= nil and vim.g.pc_test_vimscript_bufenter > 0)
  end)

  t.it("loads the deferred plugin", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "bufplug-loaded"))
  end)

  t.it("replays the plugin's own patterned `once` handler for the matching buffer", function()
    t.assert.equals(1, md_handler_count)
  end)

  t.it("does not fire that handler again for a non-matching buffer (`once` still honored)", function()
    vim.cmd("edit fixture2.pctxtfixture")
    t.assert.equals(1, md_handler_count)
  end)
end)

t.describe("an ft-scoped lhs-only key fires and the plugin maps the lhs globally", function()
  -- Sets filetype in place (fires FileType only, no BufEnter), independent of the BufEnter fixture above.
  vim.bo.filetype = "pcfixturelang"
  vim.api.nvim_feedkeys(vim.keycode("<F6>"), "mtx", false)

  t.it("loads the plugin", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "ftkeysplug-loaded"))
  end)

  t.it("does not let the (deleted) buffer-local stub shadow the plugin's real global mapping", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "ftkeysplug-global-mapping-ran"))
  end)
end)

t.describe("a lhs-only key fires and the plugin never redefines the lhs", function()
  vim.api.nvim_feedkeys(vim.keycode("<F5>"), "mtx", false)

  t.it("loads the plugin exactly once without hanging/recursing", function()
    local count = 0
    for _, m in ipairs(_G.DASH_PAQ_TEST_LOG) do
      if m == "unreplacedkeysplug-loaded" then
        count = count + 1
      end
    end
    t.assert.equals(1, count)
  end)
end)

t.describe("an ft-deferred entry has its own native ftplugin/ and after/ftplugin/", function()
  local buf1 = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf1)
  vim.bo[buf1].filetype = "pcftpluginlang"

  t.it("loads the plugin on the first matching buffer", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "ftpluginplug-loaded"))
  end)

  t.it("sources ftplugin/ and after/ftplugin/ exactly once for the first buffer", function()
    t.assert.equals(1, _G.PC_FTPLUGIN_COUNT)
    t.assert.equals(1, _G.PC_AFTER_FTPLUGIN_COUNT)
  end)

  -- The ft trigger is once=true and already gone; this buffer's sourcing must come from Neovim's own native
  -- filetypeplugin handling now that the entry is on rtp, not from any further replay.
  local buf2 = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf2)
  vim.bo[buf2].filetype = "pcftpluginlang"

  t.it("sources ftplugin/ and after/ftplugin/ exactly once more for the second buffer", function()
    t.assert.equals(2, _G.PC_FTPLUGIN_COUNT)
    t.assert.equals(2, _G.PC_AFTER_FTPLUGIN_COUNT)
  end)
end)

t.describe("a pattern-matched (non-`User`) event trigger fires", function()
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "pcfixturescheme" })

  t.it("loads the deferred plugin", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "colorschemeplug-loaded"))
  end)

  t.it("replays the plugin's own pattern-scoped handler via pattern, not buffer", function()
    t.assert.equals(1, colorscheme_handler_count)
  end)
end)

t.describe("an ft-deferred entry's own ftdetect/ defines its filetype", function()
  -- If ftdetect/ were sourced only on load (not at trigger registration), the ft trigger could never fire.
  vim.cmd("edit fixture.pcdeferfixture")

  t.it("detects the entry's own custom filetype", function()
    t.assert.equals("pcdeferfixture", vim.bo.filetype)
  end)

  t.it("loads the entry once its own filetype triggers", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "ftdetectdeferplug-loaded"))
  end)
end)

t.describe("a `keys` entry with a string expr rhs is pressed", function()
  vim.api.nvim_feedkeys(vim.keycode("<F7>"), "mtx", false)

  t.it("loads the plugin", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "exprkeysplug-loaded"))
  end)

  t.it("evaluates the real expr mapping on the first press, not feed the raw expression text", function()
    t.assert.equals(1, _G.PCX_COUNT)
  end)

  vim.api.nvim_feedkeys(vim.keycode("<F7>"), "mtx", false)
  vim.api.nvim_feedkeys(vim.keycode("<F7>"), "mtx", false)

  t.it("keeps evaluating it on every later press", function()
    t.assert.equals(3, _G.PCX_COUNT)
  end)
end)

t.describe("a `keys` entry with a plain string rhs is pressed and the user has separately remapped that rhs", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three", "four", "five" })
  vim.keymap.set("n", "j", "G", { remap = true })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  vim.api.nvim_feedkeys(vim.keycode("<F8>"), "mtx", false)

  t.it("loads the plugin", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "noremapkeysplug-loaded"))
  end)

  t.it("runs the rhs as noremap, not the user's j remap", function()
    t.assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  vim.keymap.del("n", "j")
end)

t.describe("an operator-pending lhs-only `keys` entry is used as `d<key>` on the first press", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world foo" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  vim.api.nvim_feedkeys(vim.keycode("d<F2>"), "mtx", false)

  t.it("loads the plugin", function()
    t.assert.truthy(vim.tbl_contains(_G.DASH_PAQ_TEST_LOG, "opkeysplug-loaded"))
  end)

  t.it("has applied the delete on the very first press (operator not cancelled)", function()
    t.assert.equals(" world foo", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
  end)
end)

t.describe("a deferred entry's own plugin/ file errors while sourcing", function()
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level, ...)
    notified[#notified + 1] = { msg = msg, level = level }
    return orig_notify(msg, level, ...)
  end

  -- FixtureErrCmd is never defined, so this also errors (unrelated); only the sourcing failure above is under test.
  pcall(vim.cmd, "FixtureErrCmd")

  t.wait_until(function()
    return #notified > 0
  end, 5000, "vim.notify was never called for the plugin/ sourcing error")
  vim.notify = orig_notify

  t.it("reports the failure via vim.notify at ERROR level", function()
    t.assert.truthy(notified[1] ~= nil)
    t.assert.equals(vim.log.levels.ERROR, notified[1].level)
  end)

  t.it("includes the failing file's path in the notification", function()
    t.assert.match(vim.pesc(errplug_dir) .. "/plugin/init%.lua", notified[1].msg)
  end)
end)

t.describe("a cmd-triggered entry's plugin/ defines the real command with Vimscript `command X`", function()
  vim.cmd("VimCmdDir")

  t.it("runs the dir entry's real Vimscript-defined command after load", function()
    t.assert.equals(1, vim.g.pc_vimcmddir_ran)
  end)

  vim.cmd("VimCmdSrc")

  t.it("runs the src entry's real Vimscript-defined command after load", function()
    t.assert.equals(1, vim.g.pc_vimcmdsrc_ran)
  end)
end)

t.finish()
