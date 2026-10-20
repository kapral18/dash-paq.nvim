-- Validates setup(opts) and merges defaults.
local M = {}

local policy = require("dash_paq.policy")
local notify = require("dash_paq.notify")

-- Drop hosts missing a compare or commit template, noting each in `problems`.
local function sanitize_hosts(hosts, problems)
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
    else
      problems[#problems + 1] = "opts.hosts." .. tostring(name) .. " needs both compare and commit (dropped)"
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

-- `false`, or `value`'s known, correctly typed keys over `defaults` (`true`
-- means the defaults); anything
-- else is noted in `problems` and falls back to the default.
local function resolve_section(value, defaults, path, problems)
  if value == false then
    return false
  end
  if value == true then
    value = nil
  end
  if value ~= nil and type(value) ~= "table" then
    problems[#problems + 1] = path .. " must be true, false, or a table"
    value = nil
  end
  local valid = {}
  for key, v in pairs(value or {}) do
    if defaults[key] == nil then
      problems[#problems + 1] = "unknown option " .. path .. "." .. tostring(key)
    elseif type(v) ~= type(defaults[key]) then
      problems[#problems + 1] = path .. "." .. key .. " must be a " .. type(defaults[key])
    else
      valid[key] = v
    end
  end
  return vim.tbl_deep_extend("force", vim.deepcopy(defaults), valid)
end

local TOP_LEVEL = {
  spec = true,
  modules = true,
  dashboard = true,
  version_policy = true,
  dev = true,
  default_host = true,
  hosts = true,
}

function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "dash_paq.setup(opts): opts must be a table")

  -- A single string is one spec or one module.
  local modules = type(opts.modules) == "string" and { opts.modules } or opts.modules
  local spec = type(opts.spec) == "string" and { opts.spec } or opts.spec
  modules = type(modules) == "table" and modules or {}
  spec = type(spec) == "table" and spec or {}
  -- next(): a single spec table with no [1] is valid.
  assert(
    #modules > 0 or #spec > 0 or next(spec) ~= nil,
    "dash_paq.setup(opts): at least one of opts.spec or opts.modules is required"
  )

  local problems = {}
  for key in pairs(opts) do
    if not TOP_LEVEL[key] then
      problems[#problems + 1] = "unknown option opts." .. tostring(key)
    end
  end
  if opts.default_host ~= nil and type(opts.default_host) ~= "string" then
    problems[#problems + 1] = "opts.default_host must be a string"
  end
  if opts.hosts ~= nil and type(opts.hosts) ~= "table" then
    problems[#problems + 1] = "opts.hosts must be a table"
  end

  local resolved = {
    modules = modules,
    spec = spec,
    default_host = type(opts.default_host) == "string" and opts.default_host or M.defaults.default_host,
    hosts = sanitize_hosts(
      vim.tbl_deep_extend("force", vim.deepcopy(M.defaults.hosts), type(opts.hosts) == "table" and opts.hosts or {}),
      problems
    ),
  }

  resolved.dashboard = resolve_section(opts.dashboard, M.defaults.dashboard, "opts.dashboard", problems)
  resolved.version_policy =
    resolve_section(opts.version_policy, M.defaults.version_policy, "opts.version_policy", problems)
  resolved.dev = resolve_section(opts.dev, M.defaults.dev, "opts.dev", problems) or nil
  policy.configure(resolved.version_policy or {})

  if #problems > 0 then
    table.sort(problems)
    notify.warn("dash-paq setup: " .. table.concat(problems, "; "))
  end

  return resolved
end

return M
