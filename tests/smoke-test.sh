#!/usr/bin/env bash
# smoke-test.sh — end-to-end proof of the one-command install.
#
#   bash tests/smoke-test.sh            # dry-run only (fetch + plan, no install)
#   EXAKIT_SMOKE_FULL=1 bash tests/smoke-test.sh
#                                       # full install, re-run (idempotency),
#                                       # sample data load + verify + reload,
#                                       # then interactive teardown
#
# The full run installs a real local database and is expected to finish the
# kit setup itself (excluding the database's own first-deploy time) in well
# under 10 minutes.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

say() { printf '\n\033[1;36m[smoke]\033[0m %s\n' "$*"; }

say "1/4 dry run through the pipe entry point"
start=$(date +%s)
if ! EXAKIT_DRY_RUN=1 sh "$ROOT/install.sh"; then
    echo "[smoke] FAIL: dry run exited non-zero" >&2
    exit 1
fi
say "dry run finished in $(( $(date +%s) - start ))s"

if [ "${EXAKIT_SMOKE_FULL:-0}" != "1" ]; then
    say "EXAKIT_SMOKE_FULL=1 not set — stopping after the dry run. PASS"
    exit 0
fi

say "2/4 full install"
start=$(date +%s)
if ! sh "$ROOT/install.sh"; then
    echo "[smoke] FAIL: full install exited non-zero" >&2
    exit 1
fi
full_time=$(( $(date +%s) - start ))
say "full install finished in ${full_time}s"

say "3/4 re-run (idempotency: everything should skip)"
start=$(date +%s)
if ! sh "$ROOT/install.sh"; then
    echo "[smoke] FAIL: re-run exited non-zero" >&2
    exit 1
fi
rerun_time=$(( $(date +%s) - start ))
say "re-run finished in ${rerun_time}s"

if [ "$rerun_time" -gt 120 ]; then
    echo "[smoke] WARN: re-run took ${rerun_time}s — idempotent skips should be much faster" >&2
fi

say "4/4 sample data: load, idempotent skip, forced reload"
start=$(date +%s)
if ! bash "$ROOT/setup/load-data.sh"; then
    echo "[smoke] FAIL: initial data load exited non-zero" >&2
    exit 1
fi
load_time=$(( $(date +%s) - start ))
say "data load finished in ${load_time}s"

start=$(date +%s)
if ! bash "$ROOT/setup/load-data.sh" | tee /dev/stderr | grep -q "already loaded"; then
    echo "[smoke] FAIL: second load-data.sh run did not report 'already loaded' — idempotency guard is broken" >&2
    exit 1
fi
say "idempotent re-run skipped correctly in $(( $(date +%s) - start ))s"

start=$(date +%s)
if ! bash "$ROOT/setup/load-data.sh" --force; then
    echo "[smoke] FAIL: --force reload exited non-zero (schema recreate + reload + verify should all be repeatable)" >&2
    exit 1
fi
say "forced reload finished in $(( $(date +%s) - start ))s"

"$HOME/.local/bin/exakit" status || true

say "PASS (full: ${full_time}s, re-run: ${rerun_time}s, data load: ${load_time}s)"
say "Teardown when you are done testing: exakit teardown --data"
