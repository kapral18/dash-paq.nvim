local t = require("runner")
local fixture = require("support.dirfixture")

local function run(specs, env)
  local command = { "bash", DASH_PAQ_TEST_ROOT .. "/tests/run_specs.sh" }
  vim.list_extend(command, specs)
  return vim
    .system(command, {
      cwd = DASH_PAQ_TEST_ROOT,
      env = vim.tbl_extend("force", { DASH_PAQ_NVIM = vim.v.progpath }, env or {}),
      text = true,
    })
    :wait()
end

local function spec(content)
  local dir = fixture.new("runner-café", { ["case.lua"] = content })
  return dir .. "/case.lua"
end

t.describe("WHEN the test runner cannot launch Neovim", function()
  t.it("SHOULD fail instead of reporting unexecuted specs as passed", function()
    local result = run({ "tests/unit/url_spec.lua" }, { DASH_PAQ_NVIM = DASH_PAQ_TEST_TMP .. "/missing-nvim" })
    t.assert.equals(1, result.code)
    t.assert.match("FAILED", result.stderr)
    t.assert.falsy(result.stdout:find("passed", 1, true))
  end)
end)

t.describe("WHEN the test runner executes a spec", function()
  t.it("SHOULD report a successful Neovim exit", function()
    local result = run({ spec("os.exit(0)") })
    t.assert.equals(0, result.code)
    t.assert.match("1 spec file%(s%) passed", result.stdout)
  end)

  t.it("SHOULD ignore an inherited NVIM server address", function()
    local result = run({ spec("os.exit(0)") }, { NVIM = DASH_PAQ_TEST_TMP .. "/nvim.socket" })
    t.assert.equals(0, result.code, result.stderr)
    t.assert.match("1 spec file%(s%) passed", result.stdout)
  end)

  t.it("SHOULD pass an explicit executable through make, including spaces and symlinks", function()
    local dir = fixture.new("runner-executable", {})
    local binary = dir .. "/nvim with spaces"
    assert(vim.uv.fs_symlink(vim.v.progpath, binary))
    local result = vim
      .system({ "make", "test-unit", "DASH_PAQ_NVIM=" .. binary, "UNIT_SPECS=" .. spec("os.exit(0)") }, {
        cwd = DASH_PAQ_TEST_ROOT,
        text = true,
      })
      :wait()
    t.assert.equals(0, result.code, result.stderr)
    t.assert.match("1 spec file%(s%) passed", result.stdout)
  end)

  t.it("SHOULD stop before the next spec after a failure", function()
    local result = run({ spec("os.exit(1)"), "not-run.lua" })
    t.assert.equals(1, result.code)
    t.assert.falsy(result.stdout:find("not-run.lua", 1, true))
  end)

  t.it("SHOULD fail a spec that exceeds its timeout", function()
    local result = run({ spec("vim.wait(10000, function() return false end)") }, { DASH_PAQ_SPEC_TIMEOUT = "1" })
    t.assert.equals(1, result.code)
    t.assert.match("timed out after 1s", result.stderr)
  end)

  t.it("SHOULD reject an empty spec list", function()
    local result = run({})
    t.assert.equals(1, result.code)
    t.assert.match("no spec files given", result.stderr)
  end)
end)

t.finish()
