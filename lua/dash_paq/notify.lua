-- Scheduled notifications, safe to call from fast-event callbacks.
local M = {}

function M.err(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.ERROR)
  end)
end

function M.warn(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.WARN)
  end)
end

return M
