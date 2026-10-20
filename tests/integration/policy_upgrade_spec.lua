-- A policy file from an older schema (v0.3.x wrote schema 3, without `src`) is ignored, so the first session after
-- an upgrade runs without tag pins. The startup notice must say that a restart applies them, as on first use.
local t = require("runner")
local fixture = require("support.gitfixture")
local fs = require("dash_paq.fs")
local policy = require("dash_paq.policy")

local remote = fixture.new_remote("upgraded")
fixture.commit(remote, "fix: initial", { ["README.md"] = "1" })
fixture.tag(remote, "v1.0.0")
fixture.push(remote)

fs.write_json(policy.version_policy_path(), {
  schema = 3,
  generated_at = os.time(),
  plugins = { upgraded = { strategy = "tags", latest_tag = "v1.0.0" } },
})

local notes = {}
local original_notify = vim.notify
vim.notify = function(msg)
  notes[#notes + 1] = msg
end
require("dash_paq").setup({
  spec = { { src = remote.src, name = "upgraded" } },
  dashboard = false,
  version_policy = { startup_delay_ms = 0 },
})
vim.api.nvim_exec_autocmds("VimEnter", {})
local done = vim.wait(10000, function()
  return #notes > 0
end)
vim.notify = original_notify

t.describe("WHEN the saved version policy has an older schema", function()
  t.it("SHOULD say that a restart applies the tag pins", function()
    t.assert.truthy(done, "no policy notice")
    t.assert.match("older release — restart to apply tag pins", table.concat(notes, "\n"))
  end)
end)

t.finish()
