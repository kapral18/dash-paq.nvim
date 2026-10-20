-- One spec with an invalid `version` must not stop the other plugins from installing on a fresh machine.
local t = require("runner")
local fixture = require("support.gitfixture")

local good = fixture.new_remote("goodplug")
fixture.commit(good, "feat: initial", { ["plugin/goodplug.lua"] = "vim.g.goodplug_loaded = true" })
fixture.push(good)
local bad = fixture.new_remote("badplug")
fixture.commit(bad, "feat: initial", { ["README.md"] = "bad" })
fixture.push(bad)

local notes = {}
local original_notify = vim.notify
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end
require("dash_paq").setup({
  spec = {
    { src = bad.src, name = "badplug", version = 123 },
    { src = good.src, name = "goodplug" },
  },
  dashboard = false,
  version_policy = false,
})
vim.wait(100, function()
  return #notes > 0
end)
vim.notify = original_notify

t.describe("WHEN one spec on a fresh machine has an invalid version", function()
  t.it("SHOULD still install and load the other plugins", function()
    t.assert.truthy(vim.pack.get({ "goodplug" }, { info = false })[1] ~= nil)
    t.assert.truthy(vim.g.goodplug_loaded)
  end)

  t.it("SHOULD name the failing plugin", function()
    local found = false
    for _, note in ipairs(notes) do
      if note.level == vim.log.levels.ERROR and note.msg:find("badplug", 1, true) then
        found = true
      end
    end
    t.assert.truthy(found, vim.inspect(notes))
  end)
end)

t.finish()
