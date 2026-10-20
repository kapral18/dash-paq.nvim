-- `opts`/`config = true` call `setup()` on a module derived from the plugin name. When none provides it, or the
-- module itself fails to load, the user's opts would be dropped silently; both must be reported.
local t = require("runner")
local dirfixture = require("support.dirfixture")

local notes = {}
local original_notify = vim.notify
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end
require("dash_paq").setup({
  spec = {
    { dir = dirfixture.new("nosetup", { ["lua/unrelated.lua"] = "return {}" }), name = "nosetup", opts = { a = 1 } },
    {
      dir = dirfixture.new("brokenmod", { ["lua/brokenmod.lua"] = 'error("boom in module")' }),
      name = "brokenmod",
      opts = { a = 1 },
    },
    {
      dir = dirfixture.new("goodsetup", {
        ["lua/goodsetup.lua"] = "return { setup = function(o) vim.g.goodsetup_opts = o end }",
      }),
      name = "goodsetup",
      opts = { b = 2 },
    },
  },
  dashboard = false,
  version_policy = false,
})
vim.wait(100, function()
  return #notes >= 2
end)
vim.notify = original_notify

local function note_matching(name, text)
  for _, note in ipairs(notes) do
    if note.msg:find(name, 1, true) and note.msg:find(text, 1, true) then
      return note
    end
  end
end

t.describe("WHEN opts are given", function()
  t.it("SHOULD pass them to the derived module's setup()", function()
    t.assert.same({ b = 2 }, vim.g.goodsetup_opts)
  end)

  t.it("SHOULD warn when no derived module has setup()", function()
    local note = note_matching("nosetup", "setup()")
    t.assert.truthy(note and note.level == vim.log.levels.WARN, vim.inspect(notes))
  end)

  t.it("SHOULD report the error of a derived module that fails to load", function()
    local note = note_matching("brokenmod", "boom in module")
    t.assert.truthy(note and note.level == vim.log.levels.ERROR, vim.inspect(notes))
  end)
end)

t.finish()
