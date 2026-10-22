local state = require("dash_paq.dashboard.state")
local analysis = require("dash_paq.dashboard.analysis")

local M = {}

local function parse_pack_report_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then
    return
  end

  local current_group = nil
  local current_plugin = nil
  local plugins = {}

  for _, line in ipairs(lines) do
    local section = line:match("^#%s+(%u%l+)")
    if section then
      local normalized = section:lower()
      if normalized == "update" or normalized == "same" or normalized == "error" then
        current_group = normalized
      else
        current_group = nil
      end
      current_plugin = nil
    elseif current_group then
      local name = line:match("^##%s+(.+)$")
      if name then
        name = vim.trim(name:gsub("%s*%(.+%)$", ""))
        current_plugin = {
          status = current_group,
          pending_lines = {},
          collect_pending = current_group == "error",
        }
        plugins[name] = current_plugin
      elseif current_plugin then
        local path = line:match("^Path:%s+(.+)$")
        if path then
          current_plugin.path = vim.trim(path)
        end

        local source = line:match("^Source:%s+(.+)$")
        if source then
          current_plugin.source = vim.trim(source)
        end

        local rev_before = line:match("^Revision before:%s+([0-9a-fA-F]+)")
        if rev_before then
          current_plugin.rev_before = rev_before
        end

        local rev_after_line = line:match("^Revision after:%s+(.+)$")
        if rev_after_line then
          current_plugin.rev_after = rev_after_line:match("^([0-9a-fA-F]+)") or current_plugin.rev_after
          current_plugin.target_version = rev_after_line:match("%(([^)]+)%)")
        end

        local rev_line = line:match("^Revision:%s+(.+)$")
        if rev_line then
          current_plugin.rev = rev_line:match("^([0-9a-fA-F]+)") or current_plugin.rev
          current_plugin.current_version = rev_line:match("%(([^)]+)%)")
        end

        if line:match("^Pending updates:%s*$") then
          current_plugin.collect_pending = true
        elseif current_plugin.collect_pending then
          if
            line:match("^#%s+")
            or line:match("^##%s+")
            or line:match("^Path:%s+")
            or line:match("^Source:%s+")
            or line:match("^Revision%s+")
          then
            current_plugin.collect_pending = false
          elseif line ~= "" then
            current_plugin.pending_lines[#current_plugin.pending_lines + 1] = line
          end
        end
      end
    end
  end

  -- Native error sections omit Source. Bind them now so a later source change
  -- cannot reuse an error belonging to the previous repository.
  local sources = {}
  local ok, installed = pcall(vim.pack.get, nil, { info = false })
  if ok and type(installed) == "table" then
    for _, plugin in ipairs(installed) do
      sources[plugin.spec.name] = plugin.spec.src
    end
  end
  for name, p_data in pairs(plugins) do
    p_data.source = p_data.source or sources[name]
    p_data.pending_updates = table.concat(p_data.pending_lines, "\n")
    p_data.breaking = analysis.infer_breaking_status(p_data)
    p_data.diff_url = analysis.source_to_compare_url(p_data.source, p_data.rev_before, p_data.rev_after)
    p_data.pending_lines = nil
    p_data.collect_pending = nil
  end

  state.pack_report_cache.plugins = plugins
  state.pack_report_cache.updated_at = os.time()
  state.write_persisted_state()
end

local function is_pack_report_buffer(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr):match("^nvim%-pack://confirm#") ~= nil
end

local function pack_report_buffers()
  local set = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_pack_report_buffer(bufnr) then
      set[bufnr] = true
    end
  end
  return set
end

-- `stale`: set of report buffers to skip, e.g. ones left open by an earlier check.
local function find_pack_report_buffer(stale)
  stale = stale or {}
  local current = vim.api.nvim_get_current_buf()
  if is_pack_report_buffer(current) and not stale[current] then
    return current
  end

  local matched = nil
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_pack_report_buffer(bufnr) and not stale[bufnr] then
      matched = bufnr
    end
  end

  return matched
end

-- Records `mode` with the parsed report in one persisted write. With no new
-- report buffer (e.g. no managed plugins) the cache keeps the last check's mode.
local function refresh_pack_report_cache_from_report_buffer(stale, mode)
  local bufnr = find_pack_report_buffer(stale)
  if not bufnr then
    return
  end
  local previous = state.pack_report_cache.mode
  state.pack_report_cache.mode = mode
  -- A failed parse keeps the old report, so it keeps the old mode too.
  local ok, err = pcall(parse_pack_report_buffer, bufnr)
  if not ok then
    state.pack_report_cache.mode = previous
    error(err, 0)
  end
end

M.parse_pack_report_buffer = parse_pack_report_buffer
M.pack_report_buffers = pack_report_buffers
M.find_pack_report_buffer = find_pack_report_buffer
M.refresh_pack_report_cache_from_report_buffer = refresh_pack_report_cache_from_report_buffer

return M
