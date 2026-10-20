-- Validates setup(opts) and merges defaults.
local M = {}

local policy = require("dash_paq.policy")

-- Drop hosts missing a compare or commit template.
local function sanitize_hosts(hosts)
  local out = {}
  for name, entry in pairs(hosts) do
    if
      type(name) == "string"
      and name ~= ""
      and type(entry) == "table"
      and type(entry.compare) == "string"
      and entry.compare ~= ""
      and type(entry.commit) == "string"
      and entry.commit ~= ""
    then
      out[name] = entry
    end
  end
  return out
end

M.defaults = {
  dashboard = {
    height_ratio = 0.68,
    min_height = 18,
    margin = 6,
    refresh_on_open = true,
    ascii = false,
    fast_scroll = true,
    fetch_concurrency = 8,
    apply_batch_size = 4,
    skip_risk_confirm = false,
    skip_clean_confirm = false,
  },
  version_policy = vim.deepcopy(policy.DEFAULTS),
  default_host = "https://github.com/",
  -- Built-in compare/commit URL templates; `opts.hosts` extends (or
  -- overrides) this table with additional git-forge hosts.
  hosts = {
    ["github.com"] = { compare = "compare/%s...%s", commit = "commit/%s" },
    ["codeberg.org"] = { compare = "compare/%s...%s", commit = "commit/%s" },
  },
  dev = {
    path = "~/projects",
    patterns = {},
    fallback = true,
  },
}

local function resolve_section(value, defaults)
  if value == false then
    return false
  end
  return vim.tbl_deep_extend("force", vim.deepcopy(defaults), type(value) == "table" and value or {})
end

function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "dash_paq.setup(opts): opts must be a table")

  local modules = type(opts.modules) == "table" and opts.modules or {}
  local spec = type(opts.spec) == "table" and opts.spec or {}
  -- next(): a single spec table with no [1] is valid.
  assert(
    #modules > 0 or #spec > 0 or next(spec) ~= nil,
    "dash_paq.setup(opts): at least one of opts.spec or opts.modules is required"
  )

  local resolved = {
    modules = modules,
    spec = spec,
    default_host = type(opts.default_host) == "string" and opts.default_host or M.defaults.default_host,
    hosts = sanitize_hosts(
      vim.tbl_deep_extend("force", vim.deepcopy(M.defaults.hosts), type(opts.hosts) == "table" and opts.hosts or {})
    ),
  }

  resolved.dashboard = resolve_section(opts.dashboard, M.defaults.dashboard)
  resolved.version_policy = resolve_section(opts.version_policy, M.defaults.version_policy)
  resolved.dev = resolve_section(opts.dev, M.defaults.dev) or nil
  policy.configure(resolved.version_policy or {})

  return resolved
end

return M
