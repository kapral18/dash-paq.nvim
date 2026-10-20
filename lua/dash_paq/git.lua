-- Every git shell-out goes through `M.run`: it clears the caller's
-- `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` (a bare-dotfiles shell, or nvim
-- spawned from a git hook), which would otherwise override `git -C <path>`
-- and point the command at another repository. Upstream vim.pack's `git_cmd`
-- clears `GIT_DIR`/`GIT_WORK_TREE` the same way.
local M = {}

-- Match vim.pack's source identity: removing .git can conflate different repositories.
function M.same_remote(a, b)
  return type(a) == "string" and type(b) == "string" and a == b
end

local function clean_env()
  local env = vim.fn.environ()
  env.GIT_DIR = nil
  env.GIT_WORK_TREE = nil
  env.GIT_INDEX_FILE = nil
  return env
end

-- `vim.system({ "git", unpack(args) }, opts, on_exit)` with a clean git env.
---@param args string[]
---@param opts? vim.SystemOpts
---@param on_exit? fun(out: vim.SystemCompleted)
---@return vim.SystemObj
function M.run(args, opts, on_exit)
  local cmd = vim.list_extend({ "git" }, args)
  opts = vim.tbl_extend("force", opts or {}, { env = clean_env(), clear_env = true })
  return vim.system(cmd, opts, on_exit)
end

return M
