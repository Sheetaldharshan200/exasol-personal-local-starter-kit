#!/usr/bin/env bash
# setup-macos.sh — Exasol Personal Local Starter Kit, macOS path.
#
# Installs and connects: Exasol Personal (local deployment), exapump, and the
# Exasol MCP server. Prints connection details when done.
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
[ -f "$LIB_DIR/exapump.sh" ] && . "$LIB_DIR/exapump.sh"
[ -f "$LIB_DIR/mcp.sh" ]     && . "$LIB_DIR/mcp.sh"

exakit_init_logging
manifest_init
exakit_enable_failure_handling

printf '\n  Exasol Personal Local Starter Kit — macOS setup\n\n'
detect_summary
printf '\n'

manifest_set os "$(detect_os)"
manifest_set arch "$(detect_arch)"

# --- step 1: requirements ---------------------------------------------------
EXAKIT_CURRENT_STEP="requirements"
personal_check_requirements

# --- step 2: launcher -------------------------------------------------------
if begin_step launcher "Step 1/5  Exasol launcher"; then
    personal_install_launcher
    mark_step launcher
fi

# --- step 3: local deployment ----------------------------------------------
if begin_step runtime "Step 2/5  Local database deployment"; then
    personal_deploy_local
    mark_step runtime
else
    personal_deployment_exists || {
        info "Deployment marked done but not reachable — redeploying"
        personal_deploy_local
    }
fi

# --- step 4: exapump --------------------------------------------------------
if command -v exapump_install >/dev/null 2>&1; then
    if begin_step exapump "Step 3/5  exapump (data loading CLI)"; then
        exapump_install
        exapump_create_profile
        exapump_validate_connection
        mark_step exapump
    fi
else
    info "Step 3/5  exapump — module not included in this kit build yet, skipping"
fi

# --- step 5: MCP server -----------------------------------------------------
if command -v mcp_install >/dev/null 2>&1; then
    if begin_step mcp "Step 4/5  MCP server (AI agent bridge)"; then
        mcp_install
        mcp_generate_configs
        mcp_validate
        mark_step mcp
    fi
else
    info "Step 4/5  MCP server — module not included in this kit build yet, skipping"
fi

# --- step 6: lifecycle helper ------------------------------------------------
if begin_step exakit_helper "Step 5/5  exakit helper command"; then
    mkdir -p "$EXAKIT_BIN_DIR"
    install -m 755 "$SCRIPT_DIR/exakit" "$EXAKIT_BIN_DIR/exakit"
    # Keep a copy of the kit next to the state so exakit finds its library
    # even when this checkout moves or disappears.
    mkdir -p "$EXAKIT_HOME/kit/setup"
    cp -R "$SCRIPT_DIR/lib" "$EXAKIT_HOME/kit/setup/"
    ensure_path_hint "$EXAKIT_BIN_DIR"
    mark_step exakit_helper
    ok "exakit installed ($EXAKIT_BIN_DIR/exakit)"
fi

# --- team assets (delivered separately) --------------------------------------
for _pending in sql/01_create_schema.sql data/data-dictionary.md; do
    if [ ! -s "$KIT_ROOT/$_pending" ]; then
        info "Pending: $_pending is not in this kit build yet (sample schema/data step will activate once it lands)"
    fi
done

exakit_finish
ok "Setup complete"
connection_panel
info "Next: exakit status | exakit info | exakit help"
