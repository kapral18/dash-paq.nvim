local analysis = require("dash_paq.dashboard.analysis")

local M = {}

-- `local` (dev-directory) rows rank just below `same`: they are healthy by
-- definition (never installed/updated by vim.pack) but still worth seeing
-- separately from a fully-unknown row.
M.status_rank = { drift = 1, orphan = 2, risky = 3, error = 4, update = 5, same = 6, ["local"] = 7, unknown = 8 }
M.filter_modes = { "all", "updates", "issues", "selected" }

-- Spinner frames for rows whose status is being recomputed. Braille set for
-- nerd-font terminals, ASCII fallback otherwise.
function M.spinner_frames(use_nerd_font)
  if use_nerd_font then
    return { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  end
  return { "|", "/", "-", "\\" }
end

function M.icons(use_nerd_font)
  return {
    update = use_nerd_font and "\u{f062}" or "U",
    same = use_nerd_font and "\u{f058}" or "=",
    error = use_nerd_font and "\u{f057}" or "E",
    unknown = use_nerd_font and "\u{f059}" or "?",
    orphan = use_nerd_font and "\u{f1f8}" or "O",
    drift = use_nerd_font and "\u{f0e2}" or "D",
    risky = use_nerd_font and "\u{f071}" or "W",
    ["local"] = use_nerd_font and "\u{f07c}" or "L",
    risk_break = "!",
  }
end

-- Plain-words note after the version, so a row explains itself without a
-- legend. Empty when the status says it all.
local NOTES = {
  drift = "drifted from spec",
  risky = "non-release tag",
  orphan = "not in spec",
  error = "failed",
  unknown = "not checked",
}

function M.note_cell(row)
  if row.status == "update" then
    return row.breaking == true and "possibly breaking" or ""
  end
  return NOTES[row.status] or ""
end

function M.truncate_display(text, max_width)
  if type(text) ~= "string" then
    text = tostring(text or "")
  end
  if max_width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end

  local ellipsis = "…"
  if max_width == 1 then
    return ellipsis
  end

  local out = ""
  for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
    local candidate = out .. ch
    if vim.fn.strdisplaywidth(candidate .. ellipsis) > max_width then
      break
    end
    out = candidate
  end
  return out .. ellipsis
end

function M.pad_cell(text, width)
  local value = M.truncate_display(text, width)
  local pad = width - vim.fn.strdisplaywidth(value)
  if pad <= 0 then
    return value
  end
  return value .. string.rep(" ", pad)
end

-- Plain words for each status (and the breaking signal): singular, plural.
-- Shared by the summary counts and the details title.
M.status_labels = {
  update = { "update", "updates" },
  breaking = { "possibly breaking", "possibly breaking" },
  error = { "failed", "failed" },
  drift = { "drifted", "drifted" },
  risky = { "non-release tag", "non-release tags" },
  orphan = { "not in spec", "not in spec" },
  unknown = { "not checked", "not checked" },
  same = { "up to date", "up to date" },
  ["local"] = { "local", "local" },
}

function M.version_cell(row)
  if row.status == "local" then
    return "local"
  end
  local current = row.current_version or analysis.short_rev(row.rev_before) or analysis.short_rev(row.rev)
  local target = row.target_version or analysis.short_rev(row.rev_after)
  if row.status == "update" then
    return (current or "-") .. " -> " .. (target or "-")
  end
  return current or "-"
end

return M
