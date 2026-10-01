# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial release.
- Spec layer: a lazy.nvim-shaped spec table over `vim.pack`, with `cmd`/`event`/`ft`/`keys` triggers, dependencies,
  `init`/`config`/`opts`, `build` hooks, and priority-ordered startup loading.
- Local `dev`-directory overrides that load a plugin from disk instead of its `vim.pack` clone.
- A tag-vs-branch version policy, cached under `stdpath("state")`.
- An interactive update dashboard (`:DashPaq`) with drift, orphan, and risky-pin detection, plus
  breaking-change signals from commit messages.
- One `:DashPaq` command with completed subcommands: `trace`/`load` for deferred-load inspection, `toggle-dev` to flip a plugin between upstream and its dev checkout, `sync`/`status`
  reports, lockfile export/import, and version-policy rebuild; plus `:checkhealth dash_paq`.

Extracted from the author's dotfiles (<https://github.com/kapral18/dotfiles>), where it replaced lazy.nvim in
2026-03.
