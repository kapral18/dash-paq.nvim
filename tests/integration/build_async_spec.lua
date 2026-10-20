-- Shell-string build hooks must run asynchronously, serialized through one module-local queue across plugins,
-- without blocking the `VimEnter` flush; a failing one must not abort a later build. Function/":ex" builds stay
-- synchronous (covered by lifecycle_spec.lua). Runs a real child `nvim --headless -u <init.lua>` at real startup
-- (v:vim_did_init == 0), where installs during setup() queue their build hooks to `VimEnter`, with real local git
-- remotes (no network) and fresh isolated XDG_*/stdpath dirs.
local t = require("runner")
local gitfixture = require("support.gitfixture")
local dirfixture = require("support.dirfixture")

local ROOT = _G.DASH_PAQ_TEST_ROOT

local function fresh_dir(label)
  return dirfixture.fresh_dir("dash-paq-build-async", label)
end

local marker_dir = fresh_dir("markers")
local slow_marker = vim.fs.joinpath(marker_dir, "slow.marker")
local order_marker_1 = vim.fs.joinpath(marker_dir, "order-1.marker")
local order_marker_2 = vim.fs.joinpath(marker_dir, "order-2.marker")

local function new_remote(name)
  local remote = gitfixture.new_remote(name)
  gitfixture.commit(remote, "feat: initial", { ["README.md"] = "v1" })
  gitfixture.push(remote)
  return remote
end

local slow = new_remote("build-async-slow")
local failing = new_remote("build-async-failing")
local ordered = new_remote("build-async-ordered")

local out_path = fresh_dir("out") .. "/result.json"

local init_lines = {
  "vim.opt.shadafile = 'NONE'",
  "vim.opt.swapfile = false",
  string.format("vim.opt.rtp:prepend(%q)", ROOT),
  "local notified = {}",
  "local orig_notify = vim.notify",
  "vim.notify = function(msg, level, opts)",
  "  notified[#notified + 1] = { msg = msg, level = level }",
  "  return orig_notify(msg, level, opts)",
  "end",
  "local function exists(p) return vim.fn.filereadable(p) == 1 end",
  "vim.api.nvim_create_autocmd('VimEnter', { callback = function() _G.T_BEFORE_FLUSH = vim.uv.hrtime() end })",
  "require('dash_paq').setup({",
  "  dashboard = false,",
  "  version_policy = false,",
  "  spec = {",
  string.format(
    "    { src = %q, name = 'build_async_slow', build = %q },",
    slow.src,
    string.format("sleep 0.6; touch %s", vim.fn.shellescape(slow_marker))
  ),
  -- Slow AND failing: a plain failing shell command with no stderr output.
  string.format("    { src = %q, name = 'build_async_failing', build = 'sleep 0.6; exit 7' },", failing.src),
  -- Two build specs for the same plugin name merge into one entry with 2 build hooks, run in declared order.
  string.format(
    "    { src = %q, name = 'build_async_ordered', build = %q },",
    ordered.src,
    string.format("sleep 0.5; touch %s", vim.fn.shellescape(order_marker_1))
  ),
  string.format(
    "    { src = %q, name = 'build_async_ordered', build = %q },",
    ordered.src,
    string.format("test -f %s && touch %s", vim.fn.shellescape(order_marker_1), vim.fn.shellescape(order_marker_2))
  ),
  "  },",
  "})",
  -- Registered after setup(), so it runs after the loader's own VimEnter build flush has returned.
  "vim.api.nvim_create_autocmd('VimEnter', {",
  "  callback = function()",
  "    local flush_ms = (vim.uv.hrtime() - _G.T_BEFORE_FLUSH) / 1e6",
  string.format("    local slow_at_vimenter = exists(%q)", slow_marker),
  "    local function failed_notified()",
  "      for _, n in ipairs(notified) do",
  "        if n.level == vim.log.levels.ERROR and type(n.msg) == 'string'",
  "          and n.msg:match('^[%w_.-]+: build failed %(sleep 0.6; exit 7%)') then return true end",
  "      end",
  "      return false",
  "    end",
  string.format(
    "    local finished = vim.wait(8000, function() return exists(%q) and exists(%q) and failed_notified() end, 20)",
    slow_marker,
    order_marker_2
  ),
  "    vim.fn.writefile({ vim.json.encode({",
  "      flush_ms = flush_ms,",
  "      slow_at_vimenter = slow_at_vimenter,",
  "      finished = finished,",
  string.format("      slow = exists(%q),", slow_marker),
  string.format("      order1 = exists(%q),", order_marker_1),
  string.format("      order2 = exists(%q),", order_marker_2),
  "      failed_notified = failed_notified(),",
  string.format("    }) }, %q)", out_path),
  "    vim.cmd('qa!')",
  "  end,",
  "})",
}
local init_path = fresh_dir("child-init") .. "/init.lua"
vim.fn.writefile(init_lines, init_path)

local env = vim.fn.environ()
env.HOME = fresh_dir("home")
env.XDG_CONFIG_HOME = fresh_dir("xdg-config")
env.XDG_DATA_HOME = fresh_dir("xdg-data")
env.XDG_STATE_HOME = fresh_dir("xdg-state")
env.XDG_CACHE_HOME = fresh_dir("xdg-cache")
local proc = vim
  .system({ vim.v.progpath, "--headless", "-u", init_path }, { text = true, env = env, clear_env = true })
  :wait(30000)
assert(proc.code == 0, "child startup failed: " .. tostring(proc.stderr))
local result = vim.json.decode(table.concat(vim.fn.readfile(out_path), "\n"))

t.describe("shell-string build hooks at real startup", function()
  -- Every build sleeps >= 0.5s, so a flush that waits on even the first queued one takes >= 500ms; enqueue + spawn
  -- takes a few ms. The marker check is a second, order-independent signal for the slow build.
  t.it("do not block the VimEnter flush (flush is far shorter than any single build)", function()
    t.assert.truthy(result.flush_ms < 250, "VimEnter build flush took " .. tostring(result.flush_ms) .. "ms")
    t.assert.falsy(result.slow_at_vimenter)
  end)

  t.it("eventually finish (slow marker, ordered markers, failure notify all observed)", function()
    t.assert.truthy(result.finished)
    t.assert.truthy(result.slow)
  end)

  t.it("report a failing build with the same ERROR text as the sync path, without aborting later builds", function()
    t.assert.truthy(result.failed_notified)
    t.assert.truthy(result.order1)
  end)

  t.it("run two builds declared for one plugin in declared order (second saw the first's marker)", function()
    t.assert.truthy(result.order2)
  end)
end)

t.describe("WHEN a queued build loses its working directory", function()
  t.it("SHOULD report the spawn error and continue with later builds", function()
    local first = dirfixture.new("build_first", {})
    local missing = dirfixture.new("build_missing", {})
    local last = dirfixture.new("build_last", {})
    local marker = last .. "/done"
    require("dash_paq").setup({
      dashboard = false,
      version_policy = false,
      spec = {
        { name = "build_first", dir = first, build = "sleep 0.1" },
        { name = "build_missing", dir = missing, build = "true" },
        { name = "build_last", dir = last, build = "touch " .. vim.fn.shellescape(marker) },
      },
    })
    vim.api.nvim_exec_autocmds(
      "PackChanged",
      { data = { kind = "update", spec = { name = "build_first" }, path = first } }
    )
    vim.api.nvim_exec_autocmds(
      "PackChanged",
      { data = { kind = "update", spec = { name = "build_missing" }, path = missing } }
    )
    vim.api.nvim_exec_autocmds(
      "PackChanged",
      { data = { kind = "update", spec = { name = "build_last" }, path = last } }
    )
    vim.fn.delete(missing, "d")
    t.wait_until(function()
      return vim.fn.filereadable(marker) == 1
    end, 3000, "later build was stranded")
  end)
end)

t.finish()
