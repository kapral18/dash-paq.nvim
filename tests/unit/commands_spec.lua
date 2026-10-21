local t = require("runner")
local commands = require("dash_paq.commands")

local calls = {}
local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end

local function reset()
  calls = {}
  notes = {}
end

commands.register_default({
  usage = "[!]",
  bang = true,
  impl = function(args, opts)
    calls[#calls + 1] = { name = "default", args = args, opts = opts }
  end,
})
commands.register("trace", {
  usage = "trace [plugin]",
  impl = function(args, opts)
    calls[#calls + 1] = { name = "trace", args = args, opts = opts }
  end,
  complete = function(arglead, done)
    calls[#calls + 1] = { name = "trace-complete", arglead = arglead, done = done }
    return commands.filter({ "beta", "alpha" }, arglead)
  end,
})
commands.register("pair", {
  usage = "pair <first> <second>",
  impl = function(args, opts)
    calls[#calls + 1] = { name = "pair", args = args, opts = opts }
  end,
  complete = function(arglead, done)
    calls[#calls + 1] = { name = "pair-complete", arglead = arglead, done = done }
    return {}
  end,
})
commands.register("sync", {
  usage = "sync",
  impl = function()
    calls[#calls + 1] = { name = "sync" }
  end,
})

t.describe("running :DashPaq", function()
  t.it("runs the default subcommand with no arguments", function()
    reset()
    vim.cmd("DashPaq")
    t.assert.equals(1, #calls)
    t.assert.equals("default", calls[1].name)
    t.assert.falsy(calls[1].opts.bang)
  end)

  t.it("passes the bang to a subcommand that accepts it", function()
    reset()
    vim.cmd("DashPaq!")
    t.assert.equals("default", calls[1].name)
    t.assert.truthy(calls[1].opts.bang)
  end)

  t.it("dispatches to a named subcommand with the remaining arguments", function()
    reset()
    vim.cmd("DashPaq trace alpha")
    t.assert.equals("trace", calls[1].name)
    t.assert.same({ "alpha" }, calls[1].args)
  end)

  t.it("rejects '!' on a subcommand that does not accept it", function()
    reset()
    vim.cmd("DashPaq! sync")
    t.assert.equals(0, #calls)
    t.assert.equals(vim.log.levels.ERROR, notes[1].level)
    t.assert.match("'!' is not valid for 'sync'", notes[1].msg)
  end)

  t.it("reports an unknown subcommand with the usage list", function()
    reset()
    vim.cmd("DashPaq nope")
    t.assert.equals(0, #calls)
    t.assert.equals(vim.log.levels.ERROR, notes[1].level)
    t.assert.match("unknown subcommand 'nope'", notes[1].msg)
    t.assert.match(":DashPaq%[!%]", notes[1].msg)
    t.assert.match(":DashPaq trace %[plugin%]", notes[1].msg)
    t.assert.match(":DashPaq sync", notes[1].msg)
  end)
end)

t.describe("completing :DashPaq", function()
  t.it("lists subcommands", function()
    t.assert.same({ "pair", "sync", "trace" }, vim.fn.getcompletion("DashPaq ", "cmdline"))
  end)

  t.it("filters subcommands by the typed prefix", function()
    t.assert.same({ "trace" }, vim.fn.getcompletion("DashPaq tr", "cmdline"))
  end)

  t.it("completes after a bang", function()
    t.assert.same({ "sync" }, vim.fn.getcompletion("DashPaq! sy", "cmdline"))
  end)

  t.it("delegates argument completion to the subcommand", function()
    reset()
    t.assert.same({ "alpha", "beta" }, vim.fn.getcompletion("DashPaq trace ", "cmdline"))
    t.assert.same({}, calls[1].done)
    t.assert.equals("", calls[1].arglead)
  end)

  t.it("passes the typed argument prefix to the subcommand", function()
    reset()
    t.assert.same({ "alpha" }, vim.fn.getcompletion("DashPaq trace al", "cmdline"))
    t.assert.equals("al", calls[1].arglead)
    t.assert.same({}, calls[1].done)
  end)

  t.it("passes earlier arguments as done", function()
    reset()
    commands.complete("", "DashPaq pair one ")
    t.assert.same({ "one" }, calls[1].done)
    reset()
    commands.complete("tw", "DashPaq pair one tw")
    t.assert.same({ "one" }, calls[1].done)
    t.assert.equals("tw", calls[1].arglead)
  end)

  t.it("returns nothing for an unknown subcommand", function()
    t.assert.same({}, commands.complete("", "DashPaq nope "))
  end)
end)

t.describe("WHEN completion runs before existing arguments", function()
  t.it("SHOULD complete the subcommand at the cursor", function()
    t.assert.same({ "trace" }, commands.complete("tr", "DashPaq tr alpha", 10))
  end)

  t.it("SHOULD pass only arguments before the cursor", function()
    reset()
    commands.complete("tw", "DashPaq pair one tw ignored", 19)
    t.assert.same({ "one" }, calls[1].done)
  end)
end)

t.describe("WHEN :DashPaq is abbreviated, prefixed, or filtered by a non-prefix", function()
  t.it("SHOULD complete an abbreviated command name", function()
    t.assert.same({ "pair", "sync", "trace" }, commands.complete("", "DashP "))
  end)

  t.it("SHOULD complete after a command modifier", function()
    t.assert.same({ "trace" }, commands.complete("tr", "silent DashPaq tr"))
  end)

  t.it("SHOULD match subcommands by prefix only", function()
    t.assert.same({}, commands.complete("ac", "DashPaq ac"))
  end)
end)

t.finish()
