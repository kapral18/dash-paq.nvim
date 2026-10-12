local semver = require("dash_paq.semver")
local git = require("dash_paq.git")

local M = {}

local semver_major = semver.semver_major
local parse_release_tag = semver.parse_release_tag

-- Per-process caches keyed by `path[@rev]`. Tags rarely change within a single
-- nvim session, and these queries shell out to git, so caching keeps the
-- dashboard render path cheap on repeated opens.
local revision_tag_cache = {}
local revision_tags_cache = {}
local repo_tags_cache = {}
local commit_messages_cache = {}
local commit_records_cache = {}
local pending_updates_cache = {}

local function git_tags(path, args, cache, key)
  if type(path) ~= "string" or path == "" then
    return {}
  end
  if cache[key] ~= nil then
    return cache[key]
  end

  local command = { "-C", path, "tag" }
  vim.list_extend(command, args)
  local result = git.run(command, { text = true }):wait()
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    cache[key] = {}
    return cache[key]
  end

  cache[key] = vim.split(result.stdout, "\n", { trimempty = true })
  return cache[key]
end

local function tags_on_revision(path, rev)
  if type(rev) ~= "string" or rev == "" then
    return {}
  end
  local key = path .. "@" .. rev
  return git_tags(path, { "--sort=-v:refname", "--points-at", rev }, revision_tags_cache, key)
end

local function all_tags(path)
  return git_tags(path, { "--list", "--sort=-v:refname" }, repo_tags_cache, path)
end

-- Tie-break by actual semver comparison, not string order (lexically "1.9.0"
-- > "1.10.0"). Every release tag must outrank every non-release tag, not
-- just pairwise, or mixed tag shapes produce a non-transitive order that
-- `table.sort` cannot use as a comparator.
local function tag_gt(a, b)
  local va, vb = parse_release_tag(a), parse_release_tag(b)
  if va and vb then
    return vim.version.gt(va, vb)
  end
  if va and not vb then
    return true
  end
  if vb and not va then
    return false
  end
  -- Neither side is a strict release tag: best-effort numeric major
  -- comparison, then lexical order, purely for stable non-release ranking.
  local ma, mb = semver_major(a) or -1, semver_major(b) or -1
  if ma ~= mb then
    return ma > mb
  end
  return a > b
end

-- The sync (`:wait()`) functions below and `M.prefetch_range`'s async spawns
-- build the SAME git args and parse the SAME `vim.system` result shape through
-- these helpers, so the two call paths cannot diverge.

local function tag_on_revision_cmd(path, rev)
  return { "-C", path, "tag", "--points-at", rev }
end

-- Picks the single semver-greatest tag pointing at `rev` (or `false` on a
-- git failure / no tags), matching `tag_on_revision`'s cache value shape.
local function parse_tag_on_revision(result)
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    return false
  end

  local tags = {}
  for _, line in ipairs(vim.split(result.stdout, "\n", { trimempty = true })) do
    if line ~= "" then
      tags[#tags + 1] = line
    end
  end

  table.sort(tags, tag_gt)
  return tags[1] or false
end

-- Both range queries below share the same arg contract: non-empty path and
-- both endpoints. Returns the cache key when valid, nil otherwise.
local function range_key(path, rev_before, rev_after)
  if
    type(path) ~= "string"
    or path == ""
    or type(rev_before) ~= "string"
    or rev_before == ""
    or type(rev_after) ~= "string"
    or rev_after == ""
  then
    return nil
  end
  return path .. "@" .. rev_before .. ".." .. rev_after
end

local function commit_messages_cmd(path, rev_before, rev_after)
  return { "-C", path, "log", "--format=%s%n%b", rev_before .. ".." .. rev_after }
end

-- Rebuilds the "Pending updates:" text for a row refreshed by the per-row
-- pipeline rather than the `:DashPaq sync`/`:DashPaq status` report parser, in the
-- same `hash │ subject`-per-line shape `popups.lua` parses.
local function pending_updates_cmd(path, rev_before, rev_after)
  return { "-C", path, "log", "--format=%h │ %s", rev_before .. ".." .. rev_after }
end

-- Trims stdout to `false` (git failure / empty range), matching both the
-- commit-messages and pending-updates cache value shape.
local function parse_trimmed_or_false(result)
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    return false
  end
  local normalized = vim.trim(result.stdout)
  return normalized ~= "" and normalized or false
end

local function tag_on_revision(path, rev)
  if type(path) ~= "string" or path == "" or type(rev) ~= "string" or rev == "" then
    return nil
  end
  local key = path .. "@" .. rev
  if revision_tag_cache[key] ~= nil then
    return revision_tag_cache[key] or nil
  end

  local result = git.run(tag_on_revision_cmd(path, rev), { text = true }):wait()
  revision_tag_cache[key] = parse_tag_on_revision(result)
  return revision_tag_cache[key] or nil
end

local function commit_messages_between(path, rev_before, rev_after)
  local key = range_key(path, rev_before, rev_after)
  if not key then
    return nil
  end
  if commit_messages_cache[key] ~= nil then
    return commit_messages_cache[key] or nil
  end

  local result = git.run(commit_messages_cmd(path, rev_before, rev_after), { text = true }):wait()
  commit_messages_cache[key] = parse_trimmed_or_false(result)
  return commit_messages_cache[key] or nil
end

-- Per-commit `{ hash, message }` records for the range, newest first, where
-- `hash` is the short hash and `message` is the full commit message (subject +
-- body). Preserves commit boundaries so callers can attribute a breaking marker
-- to the specific commit that carries it (in subject OR body) and key it by
-- hash. Uses ASCII record/unit separators (RS \30, US \31) as delimiters: git
-- never emits them in messages.
local function commit_records_between(path, rev_before, rev_after)
  local key = range_key(path, rev_before, rev_after)
  if not key then
    return nil
  end
  if commit_records_cache[key] ~= nil then
    return commit_records_cache[key] or nil
  end

  local result = git
    .run({ "-C", path, "log", "--format=%h%x1f%s%n%b%x1e", rev_before .. ".." .. rev_after }, { text = true })
    :wait()
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    commit_records_cache[key] = false
    return nil
  end

  local records = {}
  for _, record in ipairs(vim.split(result.stdout, "\30", { trimempty = true })) do
    local hash, message = record:match("^%s*(%x+)\31(.*)$")
    if hash and hash ~= "" then
      records[#records + 1] = { hash = hash, message = vim.trim(message or "") }
    end
  end

  commit_records_cache[key] = #records > 0 and records or false
  return commit_records_cache[key] or nil
end

local function pending_updates_between(path, rev_before, rev_after)
  local key = range_key(path, rev_before, rev_after)
  if not key then
    return nil
  end
  if pending_updates_cache[key] ~= nil then
    return pending_updates_cache[key] or nil
  end

  local result = git.run(pending_updates_cmd(path, rev_before, rev_after), { text = true }):wait()
  pending_updates_cache[key] = parse_trimmed_or_false(result)
  return pending_updates_cache[key] or nil
end

-- Async prefetch for the four breaking-change-inference git calls the sync
-- functions above run per "update" row (`tag_on_revision` x2, plus
-- `commit_messages_between`/`pending_updates_between` for the same range):
-- spawns them in parallel via `vim.system` callbacks (never `:wait()`, so this
-- never blocks the main thread), using the SAME git-args builders and result
-- parsers as the sync path above, into the SAME caches/keys, so a later sync
-- call for the same path/rev(s) is a pure cache hit. Skips any query whose
-- cache slot is already filled. `done` is always called exactly once, even
-- when one or more of the git calls fail (each failing query still caches
-- `false`, matching the sync path).
--
-- `vim.system`'s callback fires in a fast-event context: the callbacks below
-- only touch the plain-Lua caches there, then `vim.schedule` before running
-- anything that could reach `done` (which may end up driving row/UI work).
function M.prefetch_range(path, rev_before, rev_after, done)
  local jobs = {}

  local function queue(cmd, cache, key)
    jobs[#jobs + 1] = function(job_done)
      git.run(cmd, { text = true }, function(result)
        cache[key] = parse_trimmed_or_false(result)
        vim.schedule(job_done)
      end)
    end
  end

  local function queue_tag(rev)
    local key = path .. "@" .. rev
    if revision_tag_cache[key] ~= nil then
      return
    end
    jobs[#jobs + 1] = function(job_done)
      git.run(tag_on_revision_cmd(path, rev), { text = true }, function(result)
        revision_tag_cache[key] = parse_tag_on_revision(result)
        vim.schedule(job_done)
      end)
    end
  end

  if type(path) == "string" and path ~= "" then
    if type(rev_before) == "string" and rev_before ~= "" then
      queue_tag(rev_before)
    end
    if type(rev_after) == "string" and rev_after ~= "" then
      queue_tag(rev_after)
    end

    local key = range_key(path, rev_before, rev_after)
    if key then
      if commit_messages_cache[key] == nil then
        queue(commit_messages_cmd(path, rev_before, rev_after), commit_messages_cache, key)
      end
      if pending_updates_cache[key] == nil then
        queue(pending_updates_cmd(path, rev_before, rev_after), pending_updates_cache, key)
      end
    end
  end

  if #jobs == 0 then
    vim.schedule(done)
    return
  end

  local remaining = #jobs
  local function job_done()
    remaining = remaining - 1
    if remaining == 0 then
      done()
    end
  end

  for _, spawn in ipairs(jobs) do
    spawn(job_done)
  end
end

M.tags_on_revision = tags_on_revision
M.all_tags = all_tags
M.tag_on_revision = tag_on_revision
M.commit_messages_between = commit_messages_between
M.commit_records_between = commit_records_between
M.pending_updates_between = pending_updates_between

return M
