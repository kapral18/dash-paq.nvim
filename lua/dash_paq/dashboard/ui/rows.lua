local fmt = require("dash_paq.dashboard.ui.format")

local M = {}

function M.visible(ctx)
  local out = {}
  for _, row in ipairs(ctx.rows) do
    local include = true
    if ctx.filter_mode == "updates" then
      include = row.status == "update"
    elseif ctx.filter_mode == "issues" then
      include = row.status == "update"
        or row.status == "error"
        or row.status == "orphan"
        or row.status == "drift"
        or row.status == "risky"
    elseif ctx.filter_mode == "selected" then
      include = ctx.selected[row.name] == true
    end

    if include and ctx.search_text and ctx.search_text ~= "" then
      include = row.name:lower():find(ctx.search_text:lower(), 1, true) ~= nil
    end

    if include then
      out[#out + 1] = row
    end
  end

  if ctx.sort_mode == "name" then
    table.sort(out, function(a, b)
      return a.name < b.name
    end)
  else
    table.sort(out, function(a, b)
      local ra = fmt.status_rank[a.status] or fmt.status_rank.unknown
      local rb = fmt.status_rank[b.status] or fmt.status_rank.unknown
      if ra ~= rb then
        return ra < rb
      end
      return a.name < b.name
    end)
  end
  return out
end

function M.summary_counts(ctx)
  local counts =
    { update = 0, same = 0, error = 0, unknown = 0, orphan = 0, drift = 0, risky = 0, breaking = 0, ["local"] = 0 }
  for _, row in ipairs(ctx.rows) do
    counts[row.status] = (counts[row.status] or 0) + 1
    if row.breaking == true then
      counts.breaking = counts.breaking + 1
    end
  end
  return counts
end

function M.selected_count(ctx, visible_only)
  return #M.selected_names(ctx, visible_only)
end

function M.selected_names(ctx, visible_only)
  local names = {}
  local scope = visible_only and M.visible(ctx) or ctx.rows
  for _, row in ipairs(scope) do
    if ctx.selected[row.name] then
      names[#names + 1] = row.name
    end
  end
  return names
end

-- Select every visible row, or deselect them all when every visible row is
-- already selected. Selection on rows hidden by filter/search is left as-is.
function M.toggle_all_visible(ctx)
  local visible = M.visible(ctx)
  local all_selected = #visible > 0
  for _, row in ipairs(visible) do
    if not ctx.selected[row.name] then
      all_selected = false
      break
    end
  end
  for _, row in ipairs(visible) do
    ctx.selected[row.name] = not all_selected or nil
  end
end

function M.row_at_cursor(ctx)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return ctx.row_by_line[line]
end

return M
