# pack-companion.nvim

Neovim >= 0.12 ships [`vim.pack`](https://neovim.io/doc/user/pack.html#vim.pack) for install, update, and a
lockfile. pack-companion.nvim adds a lazy.nvim-shaped spec layer, a tag-vs-branch version policy, and an
interactive update dashboard. Installs, updates, deletes, and the lockfile stay `vim.pack`'s own.

## Features

- Lazy-loading spec layer over `vim.pack`: `cmd`/`event`/`ft`/`keys` triggers, dependencies, `init`/`config`/`opts`,
  build hooks, and priority-ordered startup loading.
- Local development overrides (`dev`) that load a plugin from a local directory instead of its `vim.pack` clone.
- A tag-vs-branch version policy, cached under `stdpath("state")`.
- An interactive update dashboard (`:PackDashboard`) with drift/orphan/risky-pin detection and breaking-change
  signals from commit messages.
- `:PackTrace`/`:PackLoad` for inspecting and forcing deferred loads, plus lockfile export/import commands.
- `:checkhealth pack_companion`.

## Requirements

- Neovim >= 0.12.4 (tested; `vim.pack` itself needs only Neovim 0.12). `:checkhealth pack_companion` warns on an
  older 0.12.x. Full check list: `:h pack-companion-health`.
- `git` on `PATH`.
- No third-party Lua dependencies.

## Installation

```lua
vim.pack.add({ "https://github.com/kapral18/pack-companion.nvim" })

require("pack_companion").setup({
  spec = { "owner/repo" },
})
```

There is no `plugin/` directory: call `setup()` once, from `init.lua`. At least one of `spec` / `modules` is
required. See `:h pack-companion-installation` for the full startup-load model, including deferred-trigger edge
cases.

## Spec example

Each entry in `spec` is a string (`"owner/repo"`) or a table, same shape as a lazy.nvim spec:

```lua
require("pack_companion").setup({
  spec = {
    "nvim-mini/mini.icons",

    {
      "mason-org/mason.nvim",
      cmd = { "Mason" },
      keys = { { "<leader>lm", "<cmd>Mason<cr>" } },
      version = "*", -- latest semver tag
      build = ":MasonUpdate",
    },
  },
})
```

Specs with the same `name` merge field by field; see `:h pack-companion-spec`.

### Supported spec fields

| Field                        | Meaning                                                                             |
| ----------------------------- | ------------------------------------------------------------------------------------ |
| `src` / `[1]`                 | Git source: `owner/repo`, a `scheme://` URL, `git@...`, or `gh:...`.                 |
| `name`                        | Explicit plugin name; else derived from `src`'s or `dir`'s basename.                 |
| `dir`                         | Local directory to load instead of an installed `vim.pack` clone.                    |
| `dev`                         | Load from `dev.path/<name>` when that directory exists.                              |
| `version`                     | `false` = branch tip; `"*"` = latest tag; a range = matching tag; literal = pin; omitted = version policy decides. |
| `commit` / `tag` / `branch`   | Explicit pin; takes priority over `version`.                                         |
| `enabled` / `cond`            | Boolean or function; any false among merged specs disables the entry.                |
| `optional`                    | Entry stays disabled unless at least one merged spec isn't `optional`.               |
| `dependencies`                | List of `owner/repo` strings or spec tables, loaded before the entry.                |
| `init`                        | `init(spec)`, run at setup time, before install.                                     |
| `build`                       | Function, `":Ex command"` string, or shell command; runs on `PackChanged` install/update. |
| `opts`                        | A table (deep-merged) or `fn(spec, opts)`; feeds `config`/auto-setup.                |
| `config`                      | `fn(spec, opts)`; else `setup(opts)` auto-calls when a spec supplied `opts` or `config = true`. |
| `keys`                        | Table or `fn`; every key with a known `rhs` becomes a real mapping once loaded.       |
| `cmd`                         | Command name(s) that defer loading until first use.                                  |
| `event`                       | Event(s) that defer loading until fired.                                             |
| `ft`                          | Filetype(s) that defer loading.                                                      |
| `lazy`                        | `false` forces startup load; `true` keeps it deferred with no trigger at all.         |
| `priority`                    | Startup load order among non-deferred entries (default 50, higher first; below 50 is clamped to 50). |

Unsupported (lazy.nvim-only) fields: `:h pack-companion-spec-unsupported`.

## Configuration

`opts.dashboard`, `opts.version_policy`, and `opts.dev` each accept `false` to disable that subsystem, or a table
deep-merged over these defaults:

```lua
require("pack_companion").setup({
  spec = { --[[ ... ]] },

  dashboard = {
    width_ratio = 0.68,
    height_ratio = 0.68,
    min_width = 84,
    min_height = 18,
    margin = 6,
    refresh_on_open = true,
    ascii = false, -- true = no Nerd Font glyphs
    fast_scroll = true,
    fetch_concurrency = 8,
    skip_risk_confirm = false,
    skip_clean_confirm = false,
  },

  version_policy = {
    min_tags = 3,
    commit_lag_multiplier = 1.5,
    max_commits_since_tag = 150,
    sparse_tag_threshold = 30,
    max_tag_age_days = 180,
    ttl_days = 3,
    avg_window = 6,
    startup_delay_ms = 200,
  },

  default_host = "https://github.com/",
  hosts = {
    ["github.com"] = { compare = "compare/%s...%s", commit = "commit/%s" },
    ["codeberg.org"] = { compare = "compare/%s...%s", commit = "commit/%s" },
  },

  dev = {
    path = "~/projects",
    patterns = {},
    fallback = true,
  },
})
```

`hosts` is merged over the two built-in entries; add a host to get diff/commit links for it in the dashboard.

## Commands

| Command                       | Purpose                                                                        |
| ------------------------------ | ------------------------------------------------------------------------------- |
| `:PackDashboard[!]`            | Open the dashboard; `!` force-closes and reopens with a fresh scan.             |
| `:PackSync`                    | Raw online `vim.pack.update()` report; fetches every remote first.              |
| `:PackStatus`                  | Raw offline report; local refs only, no network.                                |
| `:PackDashboardStats`          | Print the last raw update/same/error counters and check timestamps.             |
| `:PackTrace [plugin]`          | Show load status, load reason, load count, and trigger metadata.                |
| `:PackLoad <plugin>`           | Force-load one deferred plugin immediately.                                     |
| `:PackLockInfo`                | Show the `vim.pack` lockfile path, plugin count, and mtime.                     |
| `:PackLockExport <path>`       | Copy the live `vim.pack` lockfile to a path.                                    |
| `:PackLockImport <path>`       | Overwrite the live `vim.pack` lockfile from a path.                             |
| `:PackPolicyRebuild [plugin]`  | Clear and recompute the cached tag/branch heuristic.                            |

`opts.dashboard = false` disables every dashboard command except `:PackTrace`/`:PackLoad`, which belong to the
loader. Dashboard keys: `:h pack-companion-dashboard-keys`. Highlight groups: `:h pack-companion-highlights`.

## Version policy

When a spec has no `version`/`commit`/`tag`/`branch`, the version policy decides whether that plugin tracks release
tags or the default branch tip, caching the decision per plugin (`:h pack-companion-state`) and re-evaluating it
once per `ttl_days` (default 3). A plugin with no semver-shaped tags always resolves to `branch`; otherwise four
gates — release-history, commit-ratio (a recency-weighted average over the last `avg_window`, min 3, tags),
tag-age, and an absolute commit cap — can fall back from tags to branch. A `tags` decision resolves to a
caret/tilde range built from the latest tag, so `vim.pack` always resolves it to the greatest matching tag on
every install/update. Defaults for every threshold are in the options block above; see
`:h pack-companion-version-policy` for each gate.

## Local development (`dev`)

`opts.dev` lets a plugin load from a local checkout instead of its `vim.pack` clone. An entry becomes a dev entry
when its spec sets `dev = true`, or its name matches one of `dev.patterns`, **and** `dev.path/<name>` is an
existing directory at setup time. Missing directory: `fallback = true` (default) loads normally from `src`;
`fallback = false` disables the entry with a warning. `opts.dev = false` disables dev resolution entirely.

## Limitations

- `vim.pack` is experimental; its API can change between Neovim releases.
- The dashboard parses `vim.pack.update()`'s plain-text report; a future Neovim release that changes that format
  can silently break dashboard parsing until this plugin catches up.
- Differences from lazy.nvim: no `main`/`module` require-triggered loading, no `import`/`specs`/`pin`/`submodules`/
  `url` fields, no `VeryLazy`/`User` synthetic startup events.

## Development

```sh
make test
make lint
```

## License

[MIT](LICENSE)
