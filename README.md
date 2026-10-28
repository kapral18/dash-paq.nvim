# dash-paq.nvim

<img width="850" height="1036" alt="image" src="https://github.com/user-attachments/assets/9d682217-a535-40c7-9fe8-0493e0ca2786" />

---

Lazy loading and an update dashboard for Neovim's [`vim.pack`](https://neovim.io/doc/user/pack.html#vim.pack).
`vim.pack` handles installation, updates, deletion, and its lockfile. dash-paq adds:

- Plugin specs with command, event, filetype, key, and `require()` triggers; dependencies and build hooks.
- A dashboard for pending updates, undeclared plugins, version drift, and possible breaking changes.
- A cached policy that chooses release tags or the default branch when a spec has no version pin.
- Local development checkouts, including Git worktrees.

## Requirements

- Neovim >= 0.12.4. Run `:checkhealth dash_paq` to check the installation.
- `git` on `PATH`.
- No third-party Lua dependencies.

## Installation

```lua
vim.pack.add({ { src = "https://github.com/kapral18/dash-paq.nvim", version = vim.version.range("*") } })

require("dash_paq").setup({
  spec = { "nvim-mini/mini.icons" },
})
```

Put this in `init.lua`, then restart Neovim and run `:DashPaq`. `version` keeps you on tagged releases; while
dash-paq is 0.x every feature release is a new minor and can break, so pin `vim.version.range("~0.N")` with
the current minor from the releases page to stay on one line.
Call `setup()` once, with `spec`, `modules`, or both. The dashboard fetches updates when opened; use
`dashboard = { refresh_on_open = false }` to disable that fetch. See `:h dash-paq-installation` for startup
ordering.

## Spec example

Each entry is an `"owner/repo"` string or a table. Supported fields resemble lazy.nvim specs; some fields
and events differ (see [Limitations](#limitations)).

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

Use `modules = { "plugins.editor", "plugins.tools" }` to load specs from Lua modules. Each module returns a
spec or a list of specs. Field reference and merge rules: `:h dash-paq-spec`.

## Configuration

`dashboard`, `version_policy`, and `dev` accept `false` to disable them, or a table merged over their defaults:

```lua
require("dash_paq").setup({
  spec = { "nvim-mini/mini.icons" },
  dashboard = { ascii = true }, -- no Nerd Font required
  version_policy = { ttl_days = 3 },
  dev = { path = "~/projects" },
})
```

`hosts` is merged over the two built-in entries (`github.com`, `codeberg.org`); add a host to get compare and
commit pages for it in the dashboard. Every field and its default: `:h dash-paq-config`.

## Commands

Everything is a subcommand of `:DashPaq`; subcommands and their arguments complete with `<Tab>`.

| Command | Action |
| --- | --- |
| `:DashPaq[!]` | Open the dashboard; `!` closes and reopens it. |
| `:DashPaq sync` | Fetch remotes and open `vim.pack`'s update confirmation. |
| `:DashPaq status` | Open the same confirmation using local refs, without fetching. |
| `:DashPaq trace [plugin]` | Show load status, reason, time, and triggers. |
| `:DashPaq load <plugin>` | Load a deferred plugin. |
| `:DashPaq policy-rebuild [plugin]` | Recompute the cached tag/branch policy. |
| `:DashPaq toggle-dev <plugin>` | Save an upstream/dev switch for the next restart. |

In the dashboard, `r` checks local refs, `R` fetches, `u` updates selected plugins (or the cursor row), and
`U` updates all visible pending rows. `K` shows details; `?` lists all keys. Updates check out files and
change the lockfile. Each checkout batch blocks input briefly.

`dashboard = false` leaves `trace`, `load`, and `toggle-dev` available. For session exclusions, the buffer
filetypes are `dashpaq`, `dashpaq-details`, and `dashpaq-trace`. See `:h dash-paq-highlights` for colorscheme overrides.

## Version policy

Without an explicit pin, the policy chooses release tags or the default branch using tag history,
unreleased commit counts, and tag age. It refreshes every `ttl_days` (default 3); a new decision takes
effect on the next startup. Set `version_policy = false` to track the default branch for unpinned specs.
Thresholds and range rules: `:h dash-paq-version-policy`.

## Local development (`dev`)

Set a spec's `dev = true` to load `dev.path/<name>`, or set `dev` to a checkout path. `dev.patterns` can
select plugins by name; an explicit `dev = false` opts out. A missing or empty checkout falls back to
`src` by default. Set `dev.fallback = false` to disable the entry instead.

Use `L` in the dashboard to choose upstream or a local worktree. `:DashPaq toggle-dev <plugin>` switches
between upstream and the default checkout. Choices are saved for the next restart; repeating a switch
before restarting changes the saved choice. Resolution rules: `:h dash-paq-dev`.

## Limitations

- Breaking-change signals come from version numbers and commit messages. An unflagged update can still break your config.
- `vim.pack` is experimental; its API can change between Neovim releases.
- The dashboard parses `vim.pack.update()`'s plain-text report; a future Neovim release that changes that format
  can silently break dashboard parsing until this plugin catches up.
- Differences from lazy.nvim: require-triggered loading is automatic (no `main`/`module` field to opt in), no
  `import`/`specs`/`pin`/`submodules`/`url` fields (list each module in `modules` instead of `import`), and no
  `VeryLazy` or LazyVim `LazyFile` events; specs using them are reported and load as if the event were not set.
  Your own `User` events work.

## Development

Tests need Make, Neovim, Git, Bash, and Perl. Linting needs StyLua.
`DASH_PAQ_NVIM` selects the test executable; it defaults to `nvim`.

```sh
make test
make lint
```

## Releases

After CI passes, each push to `main` with `feat`/`fix`/`perf` or breaking commits publishes a tagged
[GitHub release](https://github.com/kapral18/dash-paq.nvim/releases) with generated notes.

## License

[MIT](LICENSE)
