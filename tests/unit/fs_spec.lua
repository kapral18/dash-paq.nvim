local t = require("runner")
local fs = require("dash_paq.fs")

t.describe("WHEN a state file holds JSON null", function()
  t.it("SHOULD read it as a missing value, not vim.NIL", function()
    local path = vim.fn.tempname() .. ".json"
    vim.fn.writefile({ '{"plugins":{"p":{"target_version":null,"list":[1,null]}}}' }, path)
    local decoded = fs.read_json(path)
    vim.fn.delete(path)
    t.assert.is_nil(decoded.plugins.p.target_version)
    t.assert.falsy(vim.tbl_contains(decoded.plugins.p.list, vim.NIL))
  end)
end)

t.finish()
