-- Filesystem helpers: real paths and the JSON state files under
-- `stdpath("state")/dash-paq/`.
local M = {}

-- `path` with symlinks/`..`/trailing slashes resolved, so two spellings of
-- one directory compare equal (macOS's `/tmp` -> `/private/tmp`, a symlinked
-- checkout). A path that doesn't exist is only normalized. nil for a
-- non-string or empty `path`.
function M.real_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

function M.state_dir()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "dash-paq")
end

function M.state_path(name)
  return vim.fs.joinpath(M.state_dir(), name)
end

-- The decoded table in `path`, or nil when it is missing, empty, unreadable,
-- or not a JSON object/array.
function M.read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read or type(lines) ~= "table" or #lines == 0 then
    return nil
  end
  local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_decode or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

-- Writes `value` as JSON to `path`, creating its directory. Returns whether
-- the write succeeded.
function M.write_json(path, value)
  local ok_json, encoded = pcall(vim.json.encode, value)
  if not ok_json or type(encoded) ~= "string" or encoded == "" then
    return false
  end
  local dir = vim.fs.dirname(path)
  if vim.fn.isdirectory(dir) ~= 1 then
    pcall(vim.fn.mkdir, dir, "p")
  end
  return (pcall(vim.fn.writefile, { encoded }, path))
end

return M
