# dash-paq.nvim

Neovim >= 0.12 ships [`vim.pack`](https://neovim.io/doc/user/pack.html#vim.pack) for install, update, and a
lockfile. dash-paq.nvim adds a lazy.nvim-shaped spec layer, a tag-vs-branch version policy, and an
interactive update dashboard. Installs, updates, deletes, and the lockfile stay `vim.pack`'s own.

## Features

- Lazy-loading spec layer over `vim.pack`: `cmd`/`event`/`ft`/`keys` triggers, dependencies, `init`/`config`/`opts`,
  build hooks, and priority-ordered startup loading.
- Local development overrides (`dev`) that load a plugin from a local directory instead of its `vim.pack` clone.
- A tag-vs-branch version policy, cached under `stdpath("state")`.
- An interactive update dashboard (`:DashPaq`) with drift/orphan/risky-pin detection and breaking-change
  signals from commit messages.
- `:DashPaq trace`/`:DashPaq load` for inspecting and forcing deferred loads, plus lockfile export/import.
- `:checkhealth dash_paq`.

## Requirements

- Neovim >= 0.12.4 (tested; `vim.pack` itself needs only Neovim 0.12). `:checkhealth dash_paq` warns on an
  older 0.12.x. Full check list: `:h dash-paq-health`.
- `git` on `PATH`.
- No third-party Lua dependencies.

## Installation

```lua
vim.pack.add({ "https://github.com/kapral18/dash-paq.nvim" })

require("dash_paq").setup({
  spec = { "owner/repo" },
})
```

There is no `plugin/` directory: call `setup()` once, from `init.lua`. At least one of `spec` / `modules` is
required. See `:h dash-paq-installation` for the full startup-load model, including deferred-trigger edge
cases.

## Spec example

Each entry in `spec` is a string (`"owner/repo"`) or a table, same shape as a lazy.nvim spec:

```lua
require("dash_paq").setup({
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

Specs with the same `name` merge field by field; see `:h dash-paq-spec`.

### Supported spec fields

`src`/`[1]`, `name`, `dir`, `dev`, `version`, `commit`/`tag`/`branch`, `enabled`/`cond`, `optional`,
`dependencies`, `init`, `build`, `opts`, `config`, `keys`, `cmd`, `event`, `ft`, `lazy`, `priority`. A deferred
entry also loads the first time `require()` misses on a module name it provides, even before its own `cmd`/
`event`/`ft`/`keys` trigger fires. See `:h dash-paq-spec` for each field's exact meaning and merge rules, and
`:h dash-paq-spec-unsupported` for lazy.nvim-only fields dash-paq.nvim does not read.

## Configuration

`opts.dashboard`, `opts.version_policy`, and `opts.dev` each accept `false` to disable that subsystem, or a table
deep-merged over built-in defaults, e.g.:

```lua
require("dash_paq").setup({
  spec = { --[[ ... ]] },
  dashboard = { ascii = false }, -- true = no Nerd Font glyphs
  version_policy = { ttl_days = 3 },
  dev = { path = "~/projects" },
})
```

`hosts` is merged over the two built-in entries (`github.com`, `codeberg.org`); add a host to get diff/commit
links for it in the dashboard. Every field and its default: `:h dash-paq-config`.

## Commands

Everything is a subcommand of `:DashPaq`; subcommands and their arguments complete with `<Tab>`.

| Command                                 | Purpose                                                             |
| --------------------------------------- | ------------------------------------------------------------------- |
| `:DashPaq[!]`                           | Open the dashboard; `!` force-closes and reopens with a fresh scan. |
| `:DashPaq sync`                         | Raw online `vim.pack.update()` report; fetches every remote first.  |
| `:DashPaq status`                       | Raw offline report; local refs only, no network.                    |
| `:DashPaq stats`                        | Print the last raw update/same/error counters and check timestamps. |
| `:DashPaq trace [plugin]`               | Show load status, load reason, load count, and trigger metadata.    |
| `:DashPaq load <plugin>`                | Force-load one deferred plugin immediately.                         |
| `:DashPaq lock info`                    | Show the `vim.pack` lockfile path, plugin count, and mtime.         |
| `:DashPaq lock export\|import <path>`   | Copy the live `vim.pack` lockfile to, or overwrite it from, a path. |
| `:DashPaq policy-rebuild [plugin]`      | Clear and recompute the cached tag/branch heuristic.                |
| `:DashPaq toggle-dev <plugin>`          | Flip a dev-capable plugin between its upstream clone and dev checkout. |

`opts.dashboard = false` leaves only `trace`, `load` and `toggle-dev`, which belong to the loader. Buffer filetypes (for
session-save exclusions): `dashpaq`, `dashpaq-details`, `dashpaq-trace`. Dashboard keys:
`:h dash-paq-dashboard-keys`. Highlight groups (`DashPaq*`): `:h dash-paq-highlights`.

## Version policy

When a spec has no `version`/`commit`/`tag`/`branch`, the version policy decides whether that plugin tracks release
tags or the default branch tip, caching the decision per plugin (`:h dash-paq-state`) and re-evaluating it
once per `ttl_days` (default 3). A plugin with no semver-shaped tags always resolves to `branch`; otherwise four
gates — release-history, commit-ratio (a recency-weighted average over the last `avg_window`, min 3, tags),
tag-age, and an absolute commit cap — can fall back from tags to branch. A `tags` decision resolves to a
caret/tilde range built from the latest tag, so `vim.pack` always resolves it to the greatest matching tag on
every install/update. Defaults for every threshold, and what each gate checks: `:h dash-paq-version-policy`.

## Local development (`dev`)

`opts.dev` lets a plugin load from a local checkout instead of its `vim.pack` clone, for iterating on your own
plugin. An entry becomes a dev entry when its spec sets `dev = true`/a non-empty string, or its name matches
`dev.patterns`; the base dir defaults to `dev.path/<name>`. A missing base, or an existing directory with no
plugin content, falls back to `src` (`fallback = true`, the default) or disables the entry (`fallback = false`);
an entry with no `src` is disabled either way.
`opts.dev = false` disables dev resolution entirely.

In the dashboard, `L` on a dev-capable row offers every checkout for that plugin (upstream, plus every
worktree of the base), saves the choice to `dev.json` (`:h dash-paq-state`), and offers a restart to
apply it — there is no live reload. `:DashPaq toggle-dev <plugin>` does the same flip from the command line.
See `:h dash-paq-dev` for the full base/worktree resolution order and `:h dash-paq-dashboard-keys` for `L`.

## Limitations

- `vim.pack` is experimental; its API can change between Neovim releases.
- The dashboard parses `vim.pack.update()`'s plain-text report; a future Neovim release that changes that format
  can silently break dashboard parsing until this plugin catches up.
- Differences from lazy.nvim: require-triggered loading is automatic (no `main`/`module` field to opt in), no
  `import`/`specs`/`pin`/`submodules`/`url` fields, no `VeryLazy`/`User` synthetic startup events.

## Development

```sh
make test
make lint
```

## License

[MIT](LICENSE)
