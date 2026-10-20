-- One entry's invalid trigger (an unknown event such as lazy.nvim's `VeryLazy`) must be reported against that
-- entry and must not stop later entries from registering their triggers.
local t = require("runner")
local dirfixture = require("support.dirfixture")

local notes = {}
local original_notify = vim.notify
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end

local setup_ok, setup_err = pcall(require("dash_paq").setup, {
  spec = {
    { dir = dirfixture.new("verylazy", {}), name = "verylazy", event = "VeryLazy" },
    { dir = dirfixture.new("lazyfile", {}), name = "lazyfile", event = "LazyFile" },
    {
      dir = dirfixture.new("toplist", {}),
      name = "toplist",
      event = { "BufFilePost", "FocusGained" },
      config = function()
        vim.g.toplist_loaded = true
      end,
    },
    {
      dir = dirfixture.new("eventkey", {}),
      name = "eventkey",
      event = { event = "FocusLost" },
      config = function()
        vim.g.eventkey_loaded = true
      end,
    },
    {
      dir = dirfixture.new("patternlist", {}),
      name = "patternlist",
      event = { event = "User", pattern = { "ListA", "ListB" } },
      config = function()
        vim.g.patternlist_loaded = true
      end,
    },
    {
      dir = dirfixture.new("emptyname", {}),
      name = "emptyname",
      event = "",
      config = function()
        vim.g.emptyname_loaded = true
      end,
    },
    {
      dir = dirfixture.new("emptylist", {}),
      name = "emptylist",
      event = {},
      config = function()
        vim.g.emptylist_loaded = true
      end,
    },
    {
      dir = dirfixture.new("badpattern", {}),
      name = "badpattern",
      event = { event = "User", pattern = 5 },
      config = function()
        vim.g.badpattern_loaded = true
      end,
    },
    {
      dir = dirfixture.new("mixedpatterns", {}),
      name = "mixedpatterns",
      event = { event = "User", pattern = { "VeryLazy", "MixedReady" } },
      config = function()
        vim.g.mixedpatterns_loaded = true
      end,
    },
    { dir = dirfixture.new("dupe", {}), name = "dupe", event = { event = "User", pattern = { "DupReady" } } },
    { name = "dupe", event = { event = "User", pattern = { "DupReady" } } },
    {
      dir = dirfixture.new("anyuser", {}),
      name = "anyuser",
      event = { event = "User", pattern = {} },
      config = function()
        vim.g.anyuser_loaded = true
      end,
    },
    {
      dir = dirfixture.new("positional", {}),
      name = "positional",
      event = { "User", pattern = "PositionalReady" },
      config = function()
        vim.g.positional_loaded = true
      end,
    },
    { dir = dirfixture.new("noname", {}), name = "noname", event = { pattern = "Nothing" } },
    {
      dir = dirfixture.new("eventlist", {}),
      name = "eventlist",
      event = { { "BufReadPost", "User" } },
      config = function()
        vim.g.eventlist_loaded = true
      end,
    },
    {
      dir = dirfixture.new("eventtable", {}),
      name = "eventtable",
      event = { { event = { "BufReadPost", "User" }, pattern = "TableReady" } },
      config = function()
        vim.g.eventtable_loaded = true
      end,
    },
    { dir = dirfixture.new("tablelazy", {}), name = "tablelazy", event = { "user VeryLazy" } },
    {
      dir = dirfixture.new("commalist", {}),
      name = "commalist",
      event = "BufReadPost,BufNewFile",
      config = function()
        vim.g.commalist_loaded = true
      end,
    },
    {
      dir = dirfixture.new("typoevent", {}),
      name = "typoevent",
      event = "BufEntr",
      config = function()
        vim.g.typoevent_loaded = true
      end,
    },
    { dir = dirfixture.new("userlazy", {}), name = "userlazy", event = { event = "User", pattern = { "VeryLazy" } } },
    { dir = dirfixture.new("badmode", {}), name = "badmode", keys = { { "<F12>", mode = { "n", "z" } } } },
    {
      dir = dirfixture.new("patterned", {}),
      name = "patterned",
      event = "BufEnter *.patterned",
      config = function()
        vim.g.patterned_loaded = true
      end,
    },
    {
      dir = dirfixture.new("later", {}),
      name = "later",
      cmd = "LaterCmd",
      config = function()
        vim.api.nvim_create_user_command("LaterCmd", function()
          vim.g.later_ran = true
        end, {})
      end,
    },
  },
  dashboard = false,
  version_policy = false,
})
-- Errors are delivered through `vim.schedule`.
vim.wait(100, function()
  return #notes >= 12
end)
vim.notify = original_notify
-- Before any test fires a User event.
local anyuser_at_startup = vim.g.anyuser_loaded

t.describe("WHEN a spec uses an event Neovim does not know", function()
  t.it("SHOULD finish setup", function()
    t.assert.truthy(setup_ok, setup_err)
  end)

  t.it("SHOULD name the entry and the event in an error", function()
    local found = false
    for _, note in ipairs(notes) do
      if
        note.level == vim.log.levels.ERROR
        and note.msg:find("verylazy", 1, true)
        and note.msg:find("VeryLazy", 1, true)
      then
        found = true
      end
    end
    t.assert.truthy(found, vim.inspect(notes))
  end)

  t.it("SHOULD report lazy.nvim's User VeryLazy, which nothing fires here", function()
    local found = false
    for _, note in ipairs(notes) do
      if note.level == vim.log.levels.ERROR and note.msg:find("userlazy", 1, true) then
        found = true
      end
    end
    t.assert.truthy(found, vim.inspect(notes))
  end)

  t.it("SHOULD report a key with an invalid mode once, without mapping it", function()
    local count = 0
    for _, note in ipairs(notes) do
      if note.msg:find("badmode", 1, true) then
        count = count + 1
      end
    end
    t.assert.equals(1, count)
    t.assert.equals("", vim.fn.maparg("<F12>", "n"))
    for _, note in ipairs(notes) do
      if note.msg:find("badmode", 1, true) then
        t.assert.falsy(note.msg:find("%.lua:%d"), "source location in: " .. note.msg)
      end
    end
  end)

  t.it("SHOULD report a misspelled event and fall back to loading at startup", function()
    local found = false
    for _, note in ipairs(notes) do
      if note.level == vim.log.levels.ERROR and note.msg:find("typoevent: unknown event BufEntr", 1, true) then
        found = true
      end
    end
    t.assert.truthy(found, vim.inspect(notes))
    t.assert.truthy(vim.g.typoevent_loaded)
  end)

  t.it("SHOULD report a table-form, lowercase user VeryLazy", function()
    local found = false
    for _, note in ipairs(notes) do
      if note.msg:find("tablelazy: event VeryLazy", 1, true) then
        found = true
      end
    end
    t.assert.truthy(found, vim.inspect(notes))
  end)

  t.it("SHOULD report a comma list of events and still load the plugin", function()
    local found = false
    for _, note in ipairs(notes) do
      if note.msg:find("commalist: unknown event BufReadPost,BufNewFile", 1, true) then
        found = true
      end
    end
    t.assert.truthy(found, vim.inspect(notes))
    t.assert.truthy(vim.g.commalist_loaded)
  end)

  t.it("SHOULD report LazyFile", function()
    local found = false
    for _, note in ipairs(notes) do
      if note.msg:find("lazyfile: event LazyFile", 1, true) then
        found = true
      end
    end
    t.assert.truthy(found, vim.inspect(notes))
  end)

  t.it("SHOULD still register later entries' triggers", function()
    vim.cmd("LaterCmd")
    t.assert.truthy(vim.g.later_ran)
  end)
end)

t.describe("WHEN an event is written as 'Event pattern'", function()
  t.it("SHOULD load on that event for a matching buffer only", function()
    vim.cmd("edit other.txt")
    t.assert.falsy(vim.g.patterned_loaded)
    vim.cmd("edit file.patterned")
    t.assert.truthy(vim.g.patterned_loaded)
  end)
end)

t.describe("WHEN events are given in lazy.nvim's list forms", function()
  t.it("SHOULD report an event table with no event name", function()
    local found = false
    for _, note in ipairs(notes) do
      if note.msg:find("noname: event table has no event name", 1, true) then
        found = true
      end
    end
    t.assert.truthy(found, vim.inspect(notes))
  end)

  t.it("SHOULD register every event of a list", function()
    t.assert.falsy(vim.g.eventlist_loaded)
    vim.api.nvim_exec_autocmds("User", { pattern = "Anything" })
    t.assert.truthy(vim.g.eventlist_loaded)
  end)

  t.it("SHOULD register every event of a table's event list with its pattern", function()
    t.assert.falsy(vim.g.eventtable_loaded)
    vim.api.nvim_exec_autocmds("User", { pattern = "TableReady" })
    t.assert.truthy(vim.g.eventtable_loaded)
  end)

  t.it("SHOULD defer an event named in position 1 next to its pattern", function()
    t.assert.falsy(vim.g.positional_loaded)
    vim.api.nvim_exec_autocmds("User", { pattern = "PositionalReady" })
    t.assert.truthy(vim.g.positional_loaded)
  end)
end)

t.describe("WHEN more of lazy.nvim's event shapes are used", function()
  t.it("SHOULD register each name of a top-level list", function()
    t.assert.falsy(vim.g.toplist_loaded)
    vim.api.nvim_exec_autocmds("FocusGained", {})
    t.assert.truthy(vim.g.toplist_loaded)
  end)

  t.it("SHOULD register { event = name } with no pattern", function()
    t.assert.falsy(vim.g.eventkey_loaded)
    vim.api.nvim_exec_autocmds("FocusLost", {})
    t.assert.truthy(vim.g.eventkey_loaded)
  end)

  t.it("SHOULD keep the user's own pattern next to a skipped VeryLazy", function()
    local reported = false
    for _, note in ipairs(notes) do
      reported = reported or note.msg:find("mixedpatterns: event VeryLazy", 1, true) ~= nil
    end
    t.assert.truthy(reported, vim.inspect(notes))
    t.assert.falsy(vim.g.mixedpatterns_loaded)
    vim.api.nvim_exec_autocmds("User", { pattern = "MixedReady" })
    t.assert.truthy(vim.g.mixedpatterns_loaded)
  end)

  t.it("SHOULD register a repeated event with the same pattern list once", function()
    t.assert.equals(1, #vim.api.nvim_get_autocmds({ event = "User", pattern = "DupReady" }))
  end)

  t.it("SHOULD keep an empty User pattern list as any User event", function()
    t.assert.falsy(anyuser_at_startup)
    vim.api.nvim_exec_autocmds("User", { pattern = "AnyUserReady" })
    t.assert.truthy(vim.g.anyuser_loaded)
  end)

  t.it("SHOULD register each pattern of a pattern list", function()
    t.assert.falsy(vim.g.patternlist_loaded)
    vim.api.nvim_exec_autocmds("User", { pattern = "ListB" })
    t.assert.truthy(vim.g.patternlist_loaded)
  end)
end)

t.describe("WHEN an event is empty or its pattern is not text", function()
  local function reported(name)
    for _, note in ipairs(notes) do
      if note.level == vim.log.levels.ERROR and note.msg:find(name .. ":", 1, true) then
        return true
      end
    end
    return false
  end

  t.it("SHOULD report each and load the plugin as if the event were not set", function()
    for _, name in ipairs({ "emptyname", "emptylist", "badpattern" }) do
      t.assert.truthy(reported(name), name .. " " .. vim.inspect(notes))
      t.assert.truthy(vim.g[name .. "_loaded"], name)
    end
  end)
end)

t.finish()
