-- `:PackLoad` and `:PackTrace`: manual load + a load-state table for
-- debugging deferred plugins.
local M = {}

local function trigger_summary(meta)
  local parts = {}
  if #meta.cmds > 0 then
    parts[#parts + 1] = "cmd(" .. table.concat(meta.cmds, ",") .. ")"
  end
  if #meta.events > 0 then
    local events = {}
    for _, ev in ipairs(meta.events) do
      if ev.pattern then
        events[#events + 1] = ev.event .. ":" .. tostring(ev.pattern)
      else
        events[#events + 1] = ev.event
      end
    end
    parts[#parts + 1] = "event(" .. table.concat(events, ",") .. ")"
  end
  if #meta.fts > 0 then
    parts[#parts + 1] = "ft(" .. table.concat(meta.fts, ",") .. ")"
  end
  if meta.has_keys then
    parts[#parts + 1] = "keys"
  end
  if #parts == 0 then
    return "startup"
  end
  return table.concat(parts, " ")
end

-- `ctx`: { entries, sorted, entry_state, entry_meta, load_entry, entry_name_complete }
function M.setup(ctx)
  vim.api.nvim_create_user_command("PackLoad", function(cmd)
    local name = vim.trim(cmd.args or "")
    if name == "" then
      vim.notify("Usage: PackLoad <plugin-name>", vim.log.levels.WARN)
      return
    end
    local entry = ctx.entries[name]
    if not entry or not entry.enabled then
      vim.notify("Unknown or disabled plugin: " .. name, vim.log.levels.ERROR)
      return
    end
    local was_loaded = ctx.entry_state[name] and ctx.entry_state[name].status == "loaded"
    ctx.load_entry(name, "manual:PackLoad")
    local state = ctx.entry_state[name]
    if was_loaded then
      vim.notify(name .. " already loaded", vim.log.levels.INFO)
    else
      vim.notify(string.format("%s loaded (%s)", name, state and state.loaded_by or "manual"), vim.log.levels.INFO)
    end
  end, {
    nargs = 1,
    complete = ctx.entry_name_complete,
    desc = "Force-load one deferred plugin by name",
  })

  vim.api.nvim_create_user_command("PackTrace", function(cmd)
    local filter = vim.trim(cmd.args or "")
    local lines = {
      "vim.pack trace",
      "status | plugin | loaded_by | loaded_at | count | triggers",
      "",
    }

    for _, entry in ipairs(ctx.sorted) do
      if entry.enabled and (filter == "" or entry.name == filter) then
        local state = ctx.entry_state[entry.name] or {}
        local meta = ctx.entry_meta[entry.name] or { cmds = {}, events = {}, fts = {}, has_keys = false }
        local status = state.status == "loaded" and "loaded " or "defer  "
        local loaded_by = state.loaded_by or "-"
        local loaded_at = state.loaded_at or "-"
        local count = tostring(state.load_count or 0)
        lines[#lines + 1] = string.format(
          "%s | %s | %s | %s | %s | %s",
          status,
          entry.name,
          loaded_by,
          loaded_at,
          count,
          trigger_summary(meta)
        )
      end
    end

    if #lines == 3 then
      lines[#lines + 1] = "No matching enabled plugin: " .. filter
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].filetype = "packtrace"
    local ui = vim.api.nvim_list_uis()[1]
    if ui then
      local width = math.max(80, math.floor(ui.width * 0.9))
      local height = math.max(12, math.min(#lines + 2, math.floor(ui.height * 0.8)))
      local row = math.floor((ui.height - height) / 2)
      local col = math.floor((ui.width - width) / 2)
      local win = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        title = " Pack Trace ",
        title_pos = "center",
        width = width,
        height = height,
        row = row,
        col = col,
      })
      vim.wo[win].cursorline = true
    else
      vim.cmd.sbuffer({ bufnr })
    end
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = bufnr, nowait = true, silent = true })
  end, {
    nargs = "?",
    complete = ctx.entry_name_complete,
    desc = "Show deferred/loaded plugin trace table",
  })
end

return M
