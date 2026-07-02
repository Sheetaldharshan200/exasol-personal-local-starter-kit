#!/usr/bin/env bash
# setup-wsl.sh — Exasol Personal Local Starter Kit, Linux and WSL path.
#
# Installs and connects: Exasol Nano (container, Docker preferred with Podman
# fallback), exapump, and the Exasol MCP server. Prints connection details
# when done.
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

. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
. "$LIB_DIR/runtime-nano.sh"
[ -f "$LIB_DIR/exapump.sh" ] && . "$LIB_DIR/exapump.sh"
[ -f "$LIB_DIR/mcp.sh" ]     && . "$LIB_DIR/mcp.sh"

exakit_init_logging
manifest_init
exakit_enable_failure_handling

printf '\n  Exasol Personal Local Starter Kit — Linux/WSL setup\n\n'
detect_summary
printf '\n'

manifest_set os "$(detect_os)"
manifest_set arch "$(detect_arch)"

# --- step 1: requirements ---------------------------------------------------
EXAKIT_CURRENT_STEP="requirements"
nano_check_requirements

# --- step 2: Nano container --------------------------------------------------
if begin_step runtime "Step 1/4  Exasol Nano container"; then
    nano_install
    mark_step runtime
else
    if [ "$(nano_status)" != "running" ]; then
        info "Runtime marked done but not running — starting it"
        nano_install
    fi
fi

# --- step 3: exapump ----------------------------------------------------------
if command -v exapump_install >/dev/null 2>&1; then
    if begin_step exapump "Step 2/4  exapump (data loading CLI)"; then
        exapump_install
        exapump_create_profile
        exapump_validate_connection
        mark_step exapump
    fi
else
    info "Step 2/4  exapump — module not included in this kit build yet, skipping"
fi

# --- step 4: MCP server --------------------------------------------------------
if command -v mcp_install >/dev/null 2>&1; then
    if begin_step mcp "Step 3/4  MCP server (AI agent bridge)"; then
        mcp_install
        mcp_generate_configs
        mcp_validate
        mark_step mcp
    fi
else
    info "Step 3/4  MCP server — module not included in this kit build yet, skipping"
fi

# --- step 5: lifecycle helper --------------------------------------------------
if begin_step exakit_helper "Step 4/4  exakit helper command"; then
    mkdir -p "$EXAKIT_BIN_DIR"
    install -m 755 "$SCRIPT_DIR/exakit" "$EXAKIT_BIN_DIR/exakit"
    mkdir -p "$EXAKIT_HOME/kit/setup"
    cp -R "$SCRIPT_DIR/lib" "$EXAKIT_HOME/kit/setup/"
    ensure_path_hint "$EXAKIT_BIN_DIR"
    mark_step exakit_helper
    ok "exakit installed ($EXAKIT_BIN_DIR/exakit)"
fi

# --- team assets (delivered separately) -----------------------------------------
for _pending in sql/01_create_schema.sql data/data-dictionary.md; do
    if [ ! -s "$KIT_ROOT/$_pending" ]; then
        info "Pending: $_pending is not in this kit build yet (sample schema/data step will activate once it lands)"
    fi
done

exakit_finish
ok "Setup complete"
connection_panel
info "Next: exakit status | exakit info | exakit help"
