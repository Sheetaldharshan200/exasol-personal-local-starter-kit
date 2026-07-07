#!/usr/bin/env bash
# setup-macos.sh — Exasol Personal Local Starter Kit, macOS path.
#
# Installs and connects: Exasol Personal (local deployment), exapump, the
# Exasol MCP server, and pyexasol. Prints connection details when done.
#
# Usually launched by install.sh, but runs standalone from a checkout too:
#   bash setup/setup-macos.sh
#
# Safe to re-run: completed steps are skipped, failed steps are retried.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
. "$LIB_DIR/runtime-personal.sh"
[ -f "$LIB_DIR/exapump.sh" ]  && . "$LIB_DIR/exapump.sh"
[ -f "$LIB_DIR/mcp.sh" ]      && . "$LIB_DIR/mcp.sh"
[ -f "$LIB_DIR/pyexasol.sh" ] && . "$LIB_DIR/pyexasol.sh"

exakit_init_logging
manifest_init
exakit_enable_failure_handling

ui_banner "Personal Local Starter Kit" "Local database + exapump + MCP server + pyexasol"
detect_summary
printf '\n'

manifest_set os "$(detect_os)"
manifest_set arch "$(detect_arch)"
manifest_set kit.source "${EXAKIT_KIT_SOURCE:-checkout:$KIT_ROOT}"
exakit_resolve_install_versions

# --- step 1: requirements ---------------------------------------------------
EXAKIT_CURRENT_STEP="requirements"
personal_check_requirements

# --- step 2: launcher -------------------------------------------------------
if begin_step launcher "Step 1/6  Exasol launcher"; then
    personal_install_launcher
    mark_step launcher
fi

# --- step 3: local deployment ----------------------------------------------
if begin_step runtime "Step 2/6  Local database deployment"; then
    personal_deploy_local
    mark_step runtime
else
    personal_deployment_exists || {
        info "Deployment marked done but not reachable — redeploying"
        personal_deploy_local
    }
fi

# --- steps 3-6: exapump, MCP server, pyexasol, exakit helper (shared) -------
kit_shared_steps 3 6 "$SCRIPT_DIR" "$KIT_ROOT"

exakit_finish
ok "Setup complete"
connection_panel
info "Next: exakit status | exakit info | exakit help"
