-- setup() re-clones a declared plugin whose installed remote differs from its spec `src`. A config that first
-- adds a plugin with a bare `vim.pack.add` of `…/repo` and then declares it as `owner/repo` (which expands to
-- `…/repo.git`) names the same remote and must not re-clone it on every startup.
local t = require("runner")
local gitfixture = require("support.gitfixture")

local same = gitfixture.new_remote("sameplug")
gitfixture.commit(same, "feat: initial", { ["README.md"] = "same" })
gitfixture.push(same)

local old = gitfixture.new_remote("movedold")
gitfixture.commit(old, "feat: initial", { ["README.md"] = "old" })
gitfixture.push(old)

local new = gitfixture.new_remote("movednew")
gitfixture.commit(new, "feat: initial", { ["README.md"] = "new" })
gitfixture.push(new)

local function noop() end
vim.pack.add({
  { src = (same.src:gsub("%.git$", "")), name = "sameplug" },
  { src = old.src, name = "movedplug" },
}, { confirm = false, load = noop })

-- Survives only if setup() leaves the existing clone in place.
local same_path = vim.pack.get({ "sameplug" }, { info = false })[1].path
local marker = vim.fs.joinpath(same_path, "kept.marker")
vim.fn.writefile({ "x" }, marker)

local notes = {}
local orig_notify = vim.notify
vim.notify = function(msg)
  notes[#notes + 1] = msg
end

require("dash_paq").setup({
  spec = {
    { src = same.src, name = "sameplug" },
    { src = new.src, name = "movedplug" },
  },
  dashboard = false,
  version_policy = false,
})

local reinstall_note
t.wait_until(function()
  for _, msg in ipairs(notes) do
    if msg:find("Reinstalled (src changed)", 1, true) then
      reinstall_note = msg
    end
  end
  return reinstall_note ~= nil
end, 5000, "reinstall notification")
vim.notify = orig_notify

local function origin(name)
  local path = vim.pack.get({ name }, { info = false })[1].path
  return vim.trim(vim.fn.system({ "git", "-C", path, "remote", "get-url", "origin" }))
end

t.describe("setup() with an installed remote that differs from the spec src", function()
  t.it("keeps a clone whose remote differs only by a trailing .git", function()
    t.assert.equals(1, vim.fn.filereadable(marker))
    t.assert.falsy(reinstall_note:find("sameplug", 1, true))
  end)

  t.it("re-clones a plugin whose remote moved", function()
    t.assert.equals("Reinstalled (src changed): movedplug", reinstall_note)
    t.assert.equals(new.src, origin("movedplug"))
  end)
end)

t.finish()
