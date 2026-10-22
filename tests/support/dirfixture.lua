-- Local plain-directory fixture builder for the loader's `dir`/dev path (no git remote or vim.pack install).
local M = {}

-- A fresh temp dir under `namespace`; returns its path.
function M.fresh_dir(namespace, label)
  local uv = vim.uv
  local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  local dir = string.format("%s/%s/%d-%d-%s", base, namespace, uv.os_getpid(), uv.hrtime(), label)
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.tmp_dir(label)
  return M.fresh_dir("dash-paq-dirfixtures", label or "d")
end

function M.write(root, rel, lines) -- lines: a string or a list of strings; creates parent dirs as needed
  local full = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  vim.fn.writefile(type(lines) == "table" and lines or { lines }, full)
end

-- Writes `files` (path -> content) under a fresh temp dir; returns the dir.
function M.new(name, files)
  local root = M.tmp_dir(name or "plugin")
  for path, content in pairs(files or {}) do
    M.write(root, path, vim.split(content, "\n"))
  end
  return root
end

-- A `plugin/init.lua` that appends `marker` to the shared `_G.DASH_PAQ_TEST_LOG` list.
function M.marker_plugin_files(marker, extra_files)
  local files = {
    ["plugin/init.lua"] = string.format(
      [[
_G.DASH_PAQ_TEST_LOG = _G.DASH_PAQ_TEST_LOG or {}
table.insert(_G.DASH_PAQ_TEST_LOG, %q)
]],
      marker
    ),
  }
  for path, content in pairs(extra_files or {}) do
    files[path] = content
  end
  return files
end

return M
