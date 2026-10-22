-- Source/repo/compare/commit URL derivation. `configure(hosts)` merges extra
-- git-forge hosts over the built-in ones (`dash_paq.config` defaults).
local M = {}

local DEFAULT_HOSTS = require("dash_paq.config").defaults.hosts

local configured_hosts = DEFAULT_HOSTS

function M.configure(hosts)
  configured_hosts = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_HOSTS), hosts or {})
end

local function parse_source_coordinates(src)
  if type(src) ~= "string" or src == "" then
    return nil
  end

  local normalized = vim.trim(src):gsub("/+$", "")
  local host, owner, repo = normalized:match("^https?://([^/]+)/([^/]+)/([^/]+)$")
  if not host then
    host, owner, repo = normalized:match("^git@([^:]+):([^/]+)/([^/]+)$")
  end
  if not host then
    host, owner, repo = normalized:match("^ssh://git@([^/]+)/([^/]+)/([^/]+)$")
  end
  if not host then
    return nil
  end

  repo = repo:gsub("%.git$", "")
  return host, owner, repo
end

local function source_to_repo_url(src)
  local host, owner, repo = parse_source_coordinates(src)
  if not host then
    return nil
  end
  return ("https://%s/%s/%s"):format(host, owner, repo)
end

local function repo_template(repo_url)
  if type(repo_url) ~= "string" then
    return nil
  end
  local host = repo_url:match("^https://([^/]+)/[^/]+/[^/]+$")
  return host and configured_hosts[host]
end

local function repo_to_compare_url(repo_url, from_ref, to_ref)
  if type(from_ref) ~= "string" or from_ref == "" or type(to_ref) ~= "string" or to_ref == "" then
    return nil
  end

  local template = repo_template(repo_url)
  if not template then
    return nil
  end
  return repo_url .. "/" .. template.compare:format(from_ref, to_ref)
end

local function source_to_compare_url(src, rev_before, rev_after)
  return repo_to_compare_url(source_to_repo_url(src), rev_before, rev_after)
end

local function repo_to_commit_url(repo_url, hash)
  if type(hash) ~= "string" or not hash:match("^%x%x%x%x%x%x%x+$") then
    return nil
  end

  local template = repo_template(repo_url)
  if not template then
    return nil
  end
  return repo_url .. "/" .. template.commit:format(hash)
end

M.parse_source_coordinates = parse_source_coordinates
M.source_to_compare_url = source_to_compare_url
M.source_to_repo_url = source_to_repo_url
M.repo_to_compare_url = repo_to_compare_url
M.repo_to_commit_url = repo_to_commit_url

return M
