-- Semver helpers shared between the dashboard and the version-policy engine;
-- kept free of Neovim UI/git/filesystem concerns for standalone unit testing.
local M = {}

function M.parse_release_tag(tag)
  if type(tag) ~= "string" then
    return nil
  end
  local t = vim.trim(tag)
  if t == "" then
    return nil
  end

  -- strict, like vim.pack
  local looks_like_version = t:match("^v?%d+%.%d+%.%d+[%-%+].+$") or t:match("^v?%d+%.%d+%.%d+$")
  if not looks_like_version then
    return nil
  end

  local ok, parsed = pcall(vim.version.parse, t, { strict = true })
  if ok then
    return parsed
  end
  return nil
end

function M.semver_major(version)
  if type(version) ~= "string" or version == "" then
    return nil
  end
  local major = version:match("^v?(%d+)%.") or version:match("^v?(%d+)$")
  return major and tonumber(major) or nil
end

function M.semver_triplet(version)
  if type(version) ~= "string" or version == "" then
    return nil
  end
  local major, minor, patch = version:match("^v?(%d+)%.(%d+)%.(%d+)")
  if not major then
    major, minor = version:match("^v?(%d+)%.(%d+)")
    patch = "0"
  end
  if not major then
    major = version:match("^v?(%d+)$")
    minor = "0"
    patch = "0"
  end
  if not major then
    return nil
  end
  return {
    major = tonumber(major),
    minor = tonumber(minor) or 0,
    patch = tonumber(patch) or 0,
  }
end

function M.semver_delta(before_version, after_version)
  local before_triplet = M.semver_triplet(before_version)
  local after_triplet = M.semver_triplet(after_version)
  if not before_triplet or not after_triplet then
    return nil
  end
  if after_triplet.major ~= before_triplet.major then
    return "major"
  end
  if after_triplet.minor ~= before_triplet.minor then
    return "minor"
  end
  if after_triplet.patch ~= before_triplet.patch then
    return "patch"
  end
  return "same"
end

return M
