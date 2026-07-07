#!/usr/bin/env bash
# setup-wsl.sh — Exasol Personal Local Starter Kit, Linux and WSL path.
#
# Installs and connects: Exasol Nano (container, Docker preferred with Podman
# fallback), exapump, the Exasol MCP server, and pyexasol. Prints connection
# details when done.
#
# Usually launched by install.sh, but runs standalone from a checkout too:
#   bash setup/setup-wsl.sh
#
# Safe to re-run: completed steps are skipped, failed steps are retried.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Core libraries must exist; a truncated/partial download otherwise collapses
# into a wall of "command not found". die() isn't defined until common.sh
# loads, so report with a plain printf.
for _lib in common.sh detect.sh runtime-nano.sh; do
    [ -f "$LIB_DIR/$_lib" ] || {
        printf '\033[1;31m  ✗\033[0m Kit file missing: %s — the download looks incomplete. Re-run the installer.\n' "$LIB_DIR/$_lib" >&2
        exit 1
    }
done
. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
. "$LIB_DIR/runtime-nano.sh"
[ -f "$LIB_DIR/exapump.sh" ]  && . "$LIB_DIR/exapump.sh"
[ -f "$LIB_DIR/mcp.sh" ]      && . "$LIB_DIR/mcp.sh"
[ -f "$LIB_DIR/pyexasol.sh" ] && . "$LIB_DIR/pyexasol.sh"

exakit_init_logging
manifest_init
exakit_enable_failure_handling

[ "${EXAKIT_BANNER_SHOWN:-0}" = 1 ] || ui_banner "Personal Local Starter Kit" "Local database + exapump + MCP server + pyexasol"
detect_summary
printf '\n'

manifest_set os "$(detect_os)"
manifest_set arch "$(detect_arch)"
manifest_set kit.source "${EXAKIT_KIT_SOURCE:-checkout:$KIT_ROOT}"
exakit_resolve_install_versions

# --- step 1: requirements ---------------------------------------------------
EXAKIT_CURRENT_STEP="requirements"
nano_check_requirements

# --- step 2: Nano container --------------------------------------------------
if begin_step runtime "Step 1/5  Exasol Nano container"; then
    nano_install
    mark_step runtime
else
    if [ "$(nano_status)" != "running" ]; then
        info "Runtime marked done but not running — starting it"
        nano_install
    fi
fi

# --- steps 2-5: exapump, MCP server, pyexasol, exakit helper (shared) ---------
kit_shared_steps 2 5 "$SCRIPT_DIR" "$KIT_ROOT"

exakit_finish
ok "Setup complete"
connection_panel
info "Next: exakit status | exakit info | exakit help"
