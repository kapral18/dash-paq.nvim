-- Pure spec-resolution helpers for the dash-paq loader: normalizing
-- lazy.nvim-shaped plugin specs into flat entries, opts, versions, and load order.
local M = {}

local semver = require("dash_paq.semver")
local notify = require("dash_paq.notify")

---@class dash_paq.Entry
---@field name string
---@field index integer spec order of the entry's first spec
---@field specs table[] every spec merged into this entry
---@field deps table<string, true> dependency entry names
---@field src string? git source; nil when no spec gives one (a `dir`-only entry)
---@field dir string? local directory
---@field is_dev boolean
---@field dev_base string? per-plugin dev base dir, from a string `spec.dev`
---@field enabled boolean
---@field dep_only boolean true while only `dependencies` declared it

function M.as_list(value)
  if value == nil then
    return {}
  end
  if type(value) == "table" then
    if vim.islist(value) then
      return value
    end
    return { value }
  end
  return { value }
end

function M.repo_to_name(repo)
  if type(repo) ~= "string" or repo == "" then
    return nil
  end
  local name = repo:match("/([^/]+)$") or repo
  return name:gsub("%.git$", "")
end

function M.repo_to_src(repo, default_host)
  default_host = default_host or "https://github.com/"
  if type(repo) ~= "string" or repo == "" then
    return nil
  end
  if repo:match("^[%a][%w+.-]*://") or repo:match("^git@") or repo:match("^gh:") then
    return repo
  end
  if repo:match("^[%w%._-]+/[%w%._-]+$") then
    local host = default_host
    if host:sub(-1) ~= "/" then
      host = host .. "/"
    end
    return host .. repo .. ".git"
  end
  return repo
end

function M.normalize_spec(spec)
  if type(spec) == "string" then
    return { spec }
  end
  if type(spec) ~= "table" then
    return nil
  end
  return spec
end

function M.eval_gate(value, default)
  if value == nil then
    return default
  end
  if type(value) == "function" then
    local ok, result = pcall(value)
    if not ok then
      return false
    end
    return result and true or false
  end
  return value and true or false
end

function M.key_opts_from_spec(spec)
  local rhs = spec.rhs or spec[2]
  local opts = {
    desc = spec.desc,
    expr = spec.expr,
    nowait = spec.nowait,
    silent = spec.silent,
  }

  if spec.noremap ~= nil then
    opts.noremap = spec.noremap
  elseif spec.remap ~= nil then
    opts.remap = spec.remap
  elseif type(rhs) == "string" and rhs:match("^<Plug>") then
    -- <Plug> mappings usually need remap semantics.
    opts.remap = true
  end

  return opts
end

-- A `keys` entry needs only an `lhs` to define a load trigger (lazy.nvim
-- semantics): an lhs-only spec has no `rhs`, and the trigger replays the
-- lhs itself once the plugin (and its real mapping) has loaded.
function M.normalize_key_specs(specs, plugin_spec, notify_err)
  notify_err = notify_err or notify.err
  if type(specs) == "function" then
    local ok, resolved = pcall(specs, plugin_spec, {})
    if not ok then
      notify_err("Failed to resolve key specs for " .. (plugin_spec.name or plugin_spec[1] or "<unknown>"))
      return {}
    end
    specs = resolved
  end

  local normalized = {}
  for _, spec in ipairs(M.as_list(specs)) do
    if type(spec) == "table" then
      local lhs = spec.lhs or spec[1]
      local rhs = spec.rhs or spec[2]
      if lhs and M.eval_gate(spec.enabled, true) then
        normalized[#normalized + 1] = {
          lhs = lhs,
          rhs = rhs,
          mode = spec.mode or "n",
          ft = spec.ft,
          opts = M.key_opts_from_spec(spec),
        }
      end
    end
  end
  return normalized
end

function M.derive_module_candidates(entry)
  local seen = {}
  local out = {}

  local function add(value)
    if type(value) ~= "string" or value == "" then
      return
    end
    if seen[value] then
      return
    end
    seen[value] = true
    out[#out + 1] = value
  end

  local base = entry.name
  add(base)
  if base then
    add(base:gsub("%.nvim$", ""))
    add(base:gsub("%.vim$", ""))
    add(base:gsub("^nvim%-", ""))
    add(base:gsub("^vim%-", ""))
    add(base:gsub("%-", "_"))
  end

  return out
end

function M.is_dev_entry(name, spec_dev, dev_cfg)
  if not dev_cfg then
    return false
  end
  if spec_dev == true then
    return true
  end
  if spec_dev == false then
    return false
  end
  -- A non-boolean, non-empty string is a per-plugin dev base dir (see
  -- `entry.dev_base` in `add_spec`), not a pattern-matched name.
  if type(spec_dev) == "string" and spec_dev ~= "" then
    return true
  end
  for _, pattern in ipairs(dev_cfg.patterns or {}) do
    if type(pattern) == "string" and pattern ~= "" and name:match(pattern) then
      return true
    end
  end
  return false
end

function M.dev_path_for(name, dev_cfg)
  if not dev_cfg or type(dev_cfg.path) ~= "string" or dev_cfg.path == "" then
    return nil
  end
  return vim.fs.joinpath(vim.fn.expand(dev_cfg.path), name)
end

-- opts: { dev?, default_host?, notify_err? }
function M.flatten_specs(module_names, direct_specs, opts)
  opts = opts or {}
  local notify_err = opts.notify_err or notify.err
  local default_host = opts.default_host
  local dev_cfg = opts.dev

  local entries = {} ---@type table<string, dash_paq.Entry>
  local order = 0

  local function get_or_create(name)
    local entry = entries[name]
    if entry then
      return entry
    end
    order = order + 1
    ---@type dash_paq.Entry
    entry = {
      name = name,
      index = order,
      specs = {},
      deps = {},
      src = nil,
      dir = nil,
      is_dev = false,
      dev_base = nil,
      enabled = true,
      dep_only = true,
    }
    entries[name] = entry
    return entry
  end

  local function add_spec(spec, is_dependency)
    spec = M.normalize_spec(spec)
    if not spec then
      return nil
    end

    local source = spec.src or spec[1]
    local name = spec.name or M.repo_to_name(source)
    if not name and type(spec.dir) == "string" then
      name = vim.fs.basename(spec.dir)
    end
    if not name then
      return nil
    end

    local entry = get_or_create(name)
    entry.specs[#entry.specs + 1] = spec
    if not is_dependency then
      entry.dep_only = false
    end

    if not entry.src and type(source) == "string" then
      entry.src = M.repo_to_src(source, default_host)
    end
    if not entry.dir and type(spec.dir) == "string" then
      entry.dir = spec.dir
    end
    if spec.dev ~= nil then
      entry.is_dev = M.is_dev_entry(name, spec.dev, dev_cfg)
      -- Last explicit `dev` wins for the base too: a later boolean spec
      -- reverts a plugin to the shared `dev.path/<name>` convention.
      if type(spec.dev) == "string" and spec.dev ~= "" then
        entry.dev_base = vim.fn.expand(spec.dev)
      else
        entry.dev_base = nil
      end
    elseif #entry.specs == 1 then
      entry.is_dev = M.is_dev_entry(name, nil, dev_cfg)
    end

    if not M.eval_gate(spec.enabled, true) or not M.eval_gate(spec.cond, true) then
      entry.enabled = false
    end

    local deps = M.as_list(spec.dependencies)
    for _, dep in ipairs(deps) do
      if type(dep) == "string" then
        local dep_name = M.repo_to_name(dep)
        if dep_name then
          entry.deps[dep_name] = true
          if dep:find("/") then
            add_spec({ dep }, true)
          end
        end
      elseif type(dep) == "table" then
        local dep_entry = add_spec(dep, true)
        if dep_entry and dep.optional ~= true then
          entry.deps[dep_entry.name] = true
        end
      end
    end

    return entry
  end

  -- as_list: a single spec table is one item.
  for _, spec in ipairs(M.as_list(direct_specs)) do
    add_spec(spec, false)
  end

  for _, module_name in ipairs(module_names or {}) do
    local ok, mod = pcall(require, module_name)
    if not ok then
      notify_err("Failed loading plugin module: " .. module_name)
    else
      for _, spec in ipairs(M.as_list(mod)) do
        add_spec(spec, false)
      end
    end
  end

  return entries
end

function M.resolve_opts(entry, notify_err)
  notify_err = notify_err or notify.err
  local opts = {}
  local has_opts = false
  for _, spec in ipairs(entry.specs) do
    local spec_opts = spec.opts
    if type(spec_opts) == "function" then
      -- An opts function counts even if it returns nil (in-place edit).
      has_opts = true
      local ok, result = pcall(spec_opts, spec, opts)
      if not ok then
        notify_err("opts() failed for " .. entry.name)
      elseif result ~= nil then
        opts = result
      end
    elseif type(spec_opts) == "table" then
      opts = vim.tbl_deep_extend("force", opts, vim.deepcopy(spec_opts))
      has_opts = true
    end
  end
  return opts, has_opts
end

function M.ordered_entries(entries)
  local keys = {}
  for name in pairs(entries) do
    keys[#keys + 1] = name
  end
  table.sort(keys, function(a, b)
    return entries[a].index < entries[b].index
  end)

  local out = {}
  local visiting = {}
  local visited = {}

  local function visit(name)
    if visited[name] then
      return
    end
    if visiting[name] then
      return
    end
    visiting[name] = true
    local entry = entries[name]
    for dep in pairs(entry.deps) do
      if entries[dep] then
        visit(dep)
      end
    end
    visiting[name] = nil
    visited[name] = true
    out[#out + 1] = entry
  end

  for _, name in ipairs(keys) do
    visit(name)
  end

  return out
end

function M.normalize_pack_version(version)
  if version == nil or version == false then
    return nil
  end
  if type(version) ~= "string" then
    return version
  end

  local v = vim.trim(version)
  if v == "" then
    return nil
  end

  -- lazy.nvim-compatible shorthand: `version = "*"` means "latest semver tag".
  -- `vim.pack` would reject the literal string "*" (it expects a branch/tag/
  -- commit) so we translate to an open-ended semver range which vim.pack
  -- resolves to the greatest matching tag.
  if v == "*" then
    local ok, range = pcall(vim.version.range, "*")
    if ok then
      return range
    end
  end

  if v:find("[%^~><=]") then
    local ok, range = pcall(vim.version.range, v)
    if ok then
      return range
    end
  end

  return v
end

function M.policy_tag_to_range(tag_str)
  local parsed = semver.parse_release_tag(tag_str)
  if not parsed then
    return tag_str
  end
  local major = parsed.major or 0
  local minor = parsed.minor or 0
  if major >= 1 then
    local ok, range = pcall(vim.version.range, "^" .. major .. ".0")
    if ok then
      return range
    end
  else
    local ok, range = pcall(vim.version.range, "~0." .. minor)
    if ok then
      return range
    end
  end
  return tag_str
end

function M.resolve_entry_version(entry, version_policy)
  local version = nil
  local is_explicit = false
  local is_force_branch = false

  for _, spec in ipairs(entry.specs) do
    if type(spec.commit) == "string" and spec.commit ~= "" then
      version = spec.commit
      is_explicit = true
    elseif type(spec.tag) == "string" and spec.tag ~= "" then
      version = spec.tag
      is_explicit = true
    elseif type(spec.branch) == "string" and spec.branch ~= "" then
      version = spec.branch
      is_explicit = true
    elseif spec.version == false then
      is_force_branch = true
    elseif spec.version ~= nil then
      version = spec.version
      is_explicit = true
    end
  end

  if is_force_branch then
    return nil
  end

  if is_explicit then
    return M.normalize_pack_version(version)
  end

  local policy_plugins = type(version_policy) == "table" and version_policy.plugins or nil
  local policy_item = type(policy_plugins) == "table" and policy_plugins[entry.name]
  if
    type(policy_item) == "table"
    and policy_item.strategy == "tags"
    and type(policy_item.latest_tag) == "string"
    and policy_item.latest_tag ~= ""
  then
    return M.policy_tag_to_range(policy_item.latest_tag)
  end

  return nil
end

return M
