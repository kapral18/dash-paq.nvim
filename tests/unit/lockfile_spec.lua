local t = require("runner")
local lock = require("dash_paq.dashboard.lockfile")
local original = { '{"plugins":{}}' }
local source = vim.fn.tempname() .. ".json"
local function try_import(plugins)
  vim.fn.writefile(original, lock.path())
  vim.fn.writefile({ vim.json.encode({ plugins = plugins }) }, source)
  return lock.import(source)
end

local bad_names = { "../sentinel", "..", ".", "", "a/b", "a\\b", "C:escape", "a\0b" }
for _, name in ipairs(bad_names) do
  t.describe("WHEN a lockfile name is an unsafe path: " .. vim.inspect(name), function()
    t.it("SHOULD reject it without replacing the live lockfile", function()
      local ok = try_import({ [name] = { src = "file:///fixture.git", rev = string.rep("a", 40) } })
      t.assert.falsy(ok)
      t.assert.same(original, vim.fn.readfile(lock.path()))
    end)
  end)
end

local bad_records = {
  {},
  { src = "file:///fixture.git" },
  { rev = string.rep("a", 40) },
  { src = "", rev = string.rep("a", 40) },
  { src = "file:///fixture.git", rev = "not-a-revision" },
  { src = "file:///fixture.git", rev = string.rep("a", 40), version = 42 },
  { src = "file:///fixture.git", rev = string.rep("a", 40), version = "not a range" },
}
for _, record in ipairs(bad_records) do
  t.describe("WHEN an imported plugin record is malformed: " .. vim.inspect(record), function()
    t.it("SHOULD leave the live lockfile intact", function()
      t.assert.falsy(try_import({ plugin = record }))
      t.assert.same(original, vim.fn.readfile(lock.path()))
    end)
  end)
end

t.describe("WHEN importing valid native lock data", function()
  t.it("SHOULD accept an empty plugin map", function()
    t.assert.truthy(try_import(vim.empty_dict()))
  end)

  t.it("SHOULD accept Unicode names and literal versions", function()
    t.assert.truthy(
      try_import({ ["插件"] = { src = "file:///fixture.git", rev = string.rep("a", 40), version = "'release/2.x'" } })
    )
  end)

  t.it("SHOULD accept serialized version ranges", function()
    t.assert.truthy(
      try_import({ plugin = { src = "file:///fixture.git", rev = string.rep("a", 40), version = "^1.0.0" } })
    )
  end)
end)

t.finish()
