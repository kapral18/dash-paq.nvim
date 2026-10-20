#!/usr/bin/env bash
# One Neovim process per spec, with isolated XDG/pack state. Stop on first failure.
# Perl supplies the timeout on both macOS and Linux, without GNU coreutils.
# Keep TMPDIR under /tmp: macOS's /var/folders prefix can exceed the socket path limit.
set -u

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nvim_bin="${DASH_PAQ_NVIM:-nvim}"
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
  if ! perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$timeout_secs" \
    "$nvim_bin" --headless -u "$root_dir/tests/minimal_init.lua" -l "$spec"; then
    echo "run_specs.sh: FAILED (or timed out after ${timeout_secs}s) at $spec ($total file(s) attempted)" >&2
    exit 1
  fi
done

echo "run_specs.sh: $total spec file(s) passed"
