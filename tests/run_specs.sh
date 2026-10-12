#!/usr/bin/env bash
# Runs each given spec file as its own `nvim -l` process (per-file isolation:
# fresh Lua state, fresh XDG/vim.pack dirs via tests/minimal_init.lua) and
# stops at the first failing file, printing that file's failure output.
#
# Each spec file runs under a per-file timeout (`DASH_PAQ_SPEC_TIMEOUT`
# seconds, default 60): a regression that hangs (e.g. a trigger recursing
# into itself, or a blocking wait with no timeout of its own) fails the file
# instead of blocking the whole run/CI job indefinitely. `perl -e 'alarm
# shift; exec @ARGV' <secs> <cmd...>` is used for this instead of GNU
# coreutils `timeout(1)`, which is not preinstalled on macOS runners; `perl`
# ships with both macOS and Ubuntu.
#
# Every temp dir the specs and their fixtures create lives under one per-run
# `TMPDIR`, removed on exit. It sits under /tmp, not the inherited `TMPDIR`:
# macOS's long `/var/folders/...` prefix would push the nested
# `XDG_RUNTIME_DIR` server socket path past its 104-byte limit.
set -u

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nvim_bin="${NVIM:-nvim}"
timeout_secs="${DASH_PAQ_SPEC_TIMEOUT:-60}"

if [ "$#" -eq 0 ]; then
  echo "run_specs.sh: no spec files given" >&2
  exit 1
fi

tmp_root="$(mktemp -d /tmp/dash-paq.XXXXXX)" || exit 1
trap 'rm -rf "$tmp_root"' EXIT
export TMPDIR="$tmp_root"

total=0
for spec in "$@"; do
  total=$((total + 1))
  echo "==> $spec"
  if ! perl -e 'alarm shift; exec @ARGV' "$timeout_secs" \
    "$nvim_bin" --headless -u "$root_dir/tests/minimal_init.lua" -l "$spec"; then
    echo "run_specs.sh: FAILED (or timed out after ${timeout_secs}s) at $spec ($total file(s) attempted)" >&2
    exit 1
  fi
done

echo "run_specs.sh: $total spec file(s) passed"
