-- `:DashPaq toggle-dev <plugin>`: flips a dev-capable plugin between its upstream
-- clone and its dev checkout, without the dashboard. Saves the choice to
-- dev.json and offers a restart, exactly like the dashboard's `L` key; `L`
-- remains the way to pick a specific worktree.
local commands = require("dash_paq.commands")
local dev = require("dash_paq.loader.dev")

local M = {}

-- `dev_capable`: name -> { base, has_src } (every dev-capable entry,
-- whatever its resolved choice). `hooks` (confirm/restart) are for tests.
function M.toggle(dev_capable, name, hooks)
  if not name then
    vim.notify("Usage: :DashPaq toggle-dev <plugin>", vim.log.levels.WARN)
    return
  end
  local info = dev_capable[name]
  if not info then
    vim.notify(name .. ": no dev checkout configured", vim.log.levels.WARN)
    return
  end
  local target, reason = dev.toggle_target(info.base, info.has_src, dev.load_choices()[name])
  if not target then
    vim.notify(name .. ": " .. reason, vim.log.levels.WARN)
    return
  end
  local from = target == "upstream" and "the dev checkout" or "upstream (vim.pack clone)"
  dev.set_choice(name, target, vim.tbl_extend("force", hooks or {}, { from = from }))
end

function M.setup(dev_capable)
  commands.register("toggle-dev", {
    usage = "toggle-dev <plugin>",
    impl = function(args)
      M.toggle(dev_capable, args[1])
    end,
    complete = function(arglead, done)
      if #done > 0 then
        return {}
      end
      return commands.filter(vim.tbl_keys(dev_capable), arglead)
    end,
  })
end

return M
