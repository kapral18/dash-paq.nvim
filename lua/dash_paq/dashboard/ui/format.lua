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

-- The leading short hash of a `vim.pack` pending line, e.g.
-- "> f3af041ea9f8 │ chore: bump" -> "f3af041ea9f8", after any indentation.
-- nil for lines without a hash (placeholders, blanks).
function M.pending_line_hash(line)
  return line:match("^%s*>%s*(%x+)") or line:match("^%s*(%x%x%x%x%x%x%x+)%s")
end

-- Commits the update adds, and commits it reverts (vim.pack marks those `<`).
function M.pending_commit_counts(pending)
  local ahead, behind = 0, 0
  for _, line in ipairs(vim.split(type(pending) == "string" and pending or "", "\n")) do
    if line:match("^%s*<%s*%x+") then
      behind = behind + 1
    elseif M.pending_line_hash(line) then
      ahead = ahead + 1
    end
  end
  return ahead, behind
end

local function parsed_version(text)
  local ok, version = pcall(vim.version.parse, type(text) == "string" and text or "")
  return ok and version or nil
end

-- An update row says how big it is: the semver step when both ends are
-- versions, else how many commits it brings.
function M.note_cell(row)
  if row.status == "update" then
    if row.breaking == true then
      return "possibly breaking"
    end
    local current, target = parsed_version(row.current_version), parsed_version(row.target_version)
    local ahead, behind = M.pending_commit_counts(row.pending_updates)
    if (current and target and vim.version.lt(target, current)) or (ahead == 0 and behind > 0) then
      return "downgrade"
    end
    if row.semver_delta == "major" or row.semver_delta == "minor" or row.semver_delta == "patch" then
      return row.semver_delta .. " release"
    end
    return ahead > 0 and (ahead .. (ahead == 1 and " commit" or " commits")) or ""
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
