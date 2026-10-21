local semver = require("dash_paq.semver")
local git = require("dash_paq.git")

local M = {}

local semver_major = semver.semver_major
local parse_release_tag = semver.parse_release_tag

-- Tag caches hold one table per repo; a fetch drops its repo's table, an update
-- drops all. A query still waiting on Git writes into the dropped table, never
-- the live cache.
local revision_tag_cache = {} -- [path][rev] = tag or false
local revision_tags_cache = {} -- [path][rev] = tags
local repo_tags_cache = {} -- [path] = { all = tags }
local commit_range_cache = {}

local function repo_cache(cache, path)
  local repo = cache[path]
  if not repo then
    repo = {}
    cache[path] = repo
  end
  return repo
end

-- `path` limits the reset to one repo, so one plugin's fetch keeps the tags
-- other plugins already prefetched; nil resets every repo.
function M.invalidate_tags(path)
  if path == nil then
    revision_tag_cache = {}
    revision_tags_cache = {}
    repo_tags_cache = {}
    return
  end
  revision_tag_cache[path] = nil
  revision_tags_cache[path] = nil
  repo_tags_cache[path] = nil
end

-- Calls `done(tags)` from the main loop; never waits on Git.
local function git_tags(path, args, cache, key, done)
  if type(path) ~= "string" or path == "" then
    vim.schedule(function()
      done({})
    end)
    return
  end
  local repo = repo_cache(cache, path)
  if repo[key] ~= nil then
    local tags = repo[key]
    vim.schedule(function()
      done(tags)
    end)
    return
  end

  local command = { "-C", path, "tag" }
  vim.list_extend(command, args)
  git.run_async(command, function(result)
    local tags = {}
    if result.code == 0 and type(result.stdout) == "string" then
      tags = vim.split(result.stdout, "\n", { trimempty = true })
    end
    -- A spawn failure answers empty without caching, so a later query retries.
    if not result.spawn_error then
      repo[key] = tags
    end
    done(tags)
  end)
end

local function tags_on_revision(path, rev, done)
  if type(rev) ~= "string" or rev == "" then
    vim.schedule(function()
      done({})
    end)
    return
  end
  git_tags(path, { "--sort=-v:refname", "--points-at", rev }, revision_tags_cache, rev, done)
end

local function all_tags(path, done)
  git_tags(path, { "--list", "--sort=-v:refname" }, repo_tags_cache, "all", done)
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

-- Sync queries and async prefetch share command builders, parsers, and caches.

local function tag_on_revision_cmd(path, rev)
  return { "-C", path, "tag", "--points-at", rev }
end

-- Picks the single semver-greatest tag pointing at `rev` (or `false` on a
-- git failure / no tags), matching `tag_on_revision`'s cache value shape.
local function parse_tag_on_revision(result)
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    return false
  end

  local tags = vim.split(result.stdout, "\n", { trimempty = true })

  table.sort(tags, tag_gt)
  return tags[1] or false
end

-- Require a path and both endpoints before forming a Git range.
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

local function commit_range_cmd(path, rev_before, rev_after)
  return { "-C", path, "log", "--format=%h%x00%s%n%b%x00", rev_before .. ".." .. rev_after }
end

-- One log supplies risk inference, pending subjects, and per-commit breaking markers.
-- NUL delimits fields without treating control characters in messages as records.
local function parse_commit_range(result)
  if result.code ~= 0 or type(result.stdout) ~= "string" then
    return false
  end
  local records, messages, pending = {}, {}, {}
  for hash, message in result.stdout:gmatch("(%x+)%z(.-)%z") do
    message = vim.trim(message)
    records[#records + 1] = { hash = hash, message = message }
    messages[#messages + 1] = message
    pending[#pending + 1] = hash .. " │ " .. message:match("^[^\n]*")
  end
  if #records == 0 then
    return false
  end
  local text = vim.trim(table.concat(messages, "\n\n"))
  return {
    records = records,
    messages = text ~= "" and text or nil,
    pending = vim.trim(table.concat(pending, "\n")),
  }
end

local function tag_on_revision(path, rev)
  if type(path) ~= "string" or path == "" or type(rev) ~= "string" or rev == "" then
    return nil
  end
  local cache = repo_cache(revision_tag_cache, path)
  if cache[rev] ~= nil then
    return cache[rev] or nil
  end

  local result = git.run(tag_on_revision_cmd(path, rev), { text = true }):wait()
  cache[rev] = parse_tag_on_revision(result)
  return cache[rev] or nil
end

local function commit_range(path, rev_before, rev_after)
  local key = range_key(path, rev_before, rev_after)
  if not key then
    return nil
  end
  if commit_range_cache[key] == nil then
    local result = git.run(commit_range_cmd(path, rev_before, rev_after), { text = true }):wait()
    commit_range_cache[key] = parse_commit_range(result)
  end
  return commit_range_cache[key] or nil
end

local function commit_messages_between(path, rev_before, rev_after)
  local range = commit_range(path, rev_before, rev_after)
  return range and range.messages
end

local function commit_records_between(path, rev_before, rev_after)
  local range = commit_range(path, rev_before, rev_after)
  return range and range.records
end

local function pending_updates_between(path, rev_before, rev_after)
  local range = commit_range(path, rev_before, rev_after)
  return range and range.pending
end

-- Prefetch tags and commit text for an update row, skipping cached queries.
-- Git failures cache false, matching the sync path. Schedule completion out of
-- fast-event callbacks before callers touch the UI.
function M.prefetch_range(path, rev_before, rev_after, done)
  local jobs = {}

  local function queue(cmd, cache, key, parse)
    if cache[key] ~= nil then
      return
    end
    jobs[#jobs + 1] = function(job_done)
      git.run(cmd, { text = true }, function(result)
        cache[key] = parse(result)
        vim.schedule(job_done)
      end)
    end
  end

  if type(path) == "string" and path ~= "" then
    if type(rev_before) == "string" and rev_before ~= "" then
      queue(
        tag_on_revision_cmd(path, rev_before),
        repo_cache(revision_tag_cache, path),
        rev_before,
        parse_tag_on_revision
      )
    end
    if type(rev_after) == "string" and rev_after ~= "" and rev_after ~= rev_before then
      queue(
        tag_on_revision_cmd(path, rev_after),
        repo_cache(revision_tag_cache, path),
        rev_after,
        parse_tag_on_revision
      )
    end

    local key = range_key(path, rev_before, rev_after)
    if key then
      queue(commit_range_cmd(path, rev_before, rev_after), commit_range_cache, key, parse_commit_range)
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
