-- Minimal BDD test runner for `nvim -l <spec file>`. Each spec file runs in
-- its own `nvim` process, giving per-file isolation for Lua state, the
-- require cache, and the vim.pack/XDG dirs from minimal_init.lua. finish()
-- calls os.exit(1) on any failure so the Makefile stops at the first fail.
local M = {}

local failures = {}
local test_count = 0
local describe_stack = {}

local function full_name(name)
  if #describe_stack == 0 then
    return name
  end
  return table.concat(describe_stack, " ") .. " " .. name
end

function M.describe(name, fn)
  table.insert(describe_stack, name)
  local ok, err = pcall(fn)
  table.remove(describe_stack)
  if not ok then
    failures[#failures + 1] = { name = full_name(name) .. " [describe block itself errored]", err = err }
  end
end

function M.it(name, fn)
  test_count = test_count + 1
  local label = full_name(name)
  local ok, err = pcall(fn)
  if not ok then
    failures[#failures + 1] = { name = label, err = err }
  end
end

local function fail(msg)
  -- level 0: the message already carries all the context needed; a Lua
  -- location prefix from `error()` would only point at this helper file.
  error(msg, 0)
end

local assert_mod = {}
M.assert = assert_mod

function assert_mod.truthy(value, msg)
  if not value then
    fail(msg or ("expected a truthy value, got " .. vim.inspect(value)))
  end
end

function assert_mod.falsy(value, msg)
  if value then
    fail(msg or ("expected a falsy value, got " .. vim.inspect(value)))
  end
end

function assert_mod.is_nil(value, msg)
  if value ~= nil then
    fail(msg or ("expected nil, got " .. vim.inspect(value)))
  end
end

function assert_mod.equals(expected, actual, msg)
  if expected ~= actual then
    fail(msg or string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual)))
  end
end

function assert_mod.same(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    fail(msg or string.format("expected (deep-equal) %s, got %s", vim.inspect(expected), vim.inspect(actual)))
  end
end

function assert_mod.match(pattern, text, msg)
  if type(text) ~= "string" or not text:match(pattern) then
    fail(msg or string.format("expected %s to match pattern %s", vim.inspect(text), pattern))
  end
end

-- `pattern`, if given, is a plain Lua pattern, not a regex.
function assert_mod.raises(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then
    fail(msg or "expected the function to raise an error, it returned normally")
  end
  if pattern and not tostring(err):match(pattern) then
    fail(msg or string.format("expected error %s to match pattern %s", vim.inspect(tostring(err)), pattern))
  end
end

-- Pumps the event loop so vim.schedule/vim.defer_fn/vim.system callbacks run.
function M.wait_until(predicate, timeout_ms, msg)
  timeout_ms = timeout_ms or 5000
  local ok = vim.wait(timeout_ms, predicate, 10)
  if not ok then
    fail(msg or ("wait_until: condition not satisfied within " .. timeout_ms .. "ms"))
  end
end

function M.finish()
  local failed = #failures
  if failed > 0 then
    io.stderr:write(string.format("\n%d/%d test(s) failed:\n", failed, test_count))
    for _, f in ipairs(failures) do
      io.stderr:write(string.format("  FAIL: %s\n        %s\n", f.name, tostring(f.err)))
    end
    io.stderr:write("\n")
    os.exit(1)
  end
  io.stdout:write(string.format("%d/%d test(s) passed\n", test_count, test_count))
  os.exit(0)
end

return M
