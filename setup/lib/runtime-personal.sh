#!/usr/bin/env bash
# runtime-personal.sh — Exasol Personal local runtime module (macOS).
#
# Sourced by setup scripts after common.sh and detect.sh. Installs the Exasol
# launcher from the pinned GitHub release (checksum-verified) and deploys a
# local database with `exasol install local`.
#
# Launcher facts:
#   - release assets: exasol-personal_macOS_{arm64,x86_64}.tar.gz + checksums
#   - local deployment needs macOS with at least 8 GB RAM
#   - deployment state: ~/.exasol/personal/deployments/default
#   - `exasol info` prints connection details for the current deployment
#   - rerunning `exasol install local` with the same preset is safe

EXAKIT_PERSONAL_PORT=8563
EXAKIT_PERSONAL_MIN_RAM_GB="${EXAKIT_PERSONAL_MIN_RAM_GB:-8}"
EXAKIT_PERSONAL_MIN_DISK_GB="${EXAKIT_PERSONAL_MIN_DISK_GB:-20}"
EXAKIT_PERSONAL_BIN="$EXAKIT_BIN_DIR/exasol"
EXAKIT_PERSONAL_DEPLOY_DIR="${EXAKIT_PERSONAL_DEPLOY_DIR:-$HOME/.exasol/personal/deployments/default}"

personal_check_requirements() {
    [ "$(detect_os)" = "macos" ] || die "Exasol Personal local deployment is macOS-only in this kit. Linux/Windows use Exasol Nano."

    _arch="$(detect_arch)"
    [ "$_arch" != "unsupported" ] || die "Unsupported CPU architecture: $(uname -m)"

    _ram="$(detect_ram_gb)"
    if [ "$_ram" -lt "$EXAKIT_PERSONAL_MIN_RAM_GB" ]; then
        error "Exasol Personal needs at least ${EXAKIT_PERSONAL_MIN_RAM_GB} GB RAM; this machine has ${_ram} GB."
        die "This machine does not meet the requirements for a local Exasol Personal deployment."
    fi

    _disk="$(detect_free_disk_gb "$HOME")"
    if [ "$_disk" -lt "$EXAKIT_PERSONAL_MIN_DISK_GB" ] && [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        die "Less than ${EXAKIT_PERSONAL_MIN_DISK_GB} GB free disk space (detected: ${_disk} GB). Free up space or set EXAKIT_FORCE=1."
    fi

    ok "Requirements met (macOS, ${_ram} GB RAM, ${_disk} GB free)"
}

personal_asset_name() {
    case "$(detect_arch)" in
        arm64)  echo "exasol-personal_macOS_arm64.tar.gz" ;;
        x86_64) echo "exasol-personal_macOS_x86_64.tar.gz" ;;
    esac
}

personal_release_url() {
    echo "https://github.com/${EXAKIT_PERSONAL_REPO}/releases/download/v${EXAKIT_PERSONAL_VERSION}"
}

# personal_install_launcher — download, verify, and install the `exasol` CLI.
# An already-installed launcher is only accepted if it supports the 'local'
# preset (older releases do not); otherwise the pinned version is installed
# alongside it and preferred.
personal_install_launcher() {
    if command -v exasol >/dev/null 2>&1; then
        _existing="$(command -v exasol)"
        if "$_existing" install --help 2>/dev/null | grep -qw "local"; then
            ok "Exasol launcher already installed: $_existing"
            return 0
        fi
        warn "The installed Exasol launcher ($_existing) does not support the 'local' preset (too old)."
        info "Installing launcher v${EXAKIT_PERSONAL_VERSION} to $EXAKIT_PERSONAL_BIN — your existing launcher is left untouched"
    fi

    _asset="$(personal_asset_name)"
    _base="$(personal_release_url)"
    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-personal.XXXXXX")"

    info "Downloading Exasol launcher v${EXAKIT_PERSONAL_VERSION} ($_asset)"
    fetch "$_base/$_asset" "$_tmp/$_asset"
    fetch "$_base/exasol-personal_${EXAKIT_PERSONAL_VERSION}_checksums.txt" "$_tmp/checksums.txt"
    verify_sha256_from_file "$_tmp/$_asset" "$_tmp/checksums.txt"

    info "Installing launcher to $EXAKIT_PERSONAL_BIN"
    mkdir -p "$EXAKIT_BIN_DIR"
    run_logged tar -xzf "$_tmp/$_asset" -C "$_tmp" || die "Could not extract $_asset"
    _binary="$(find "$_tmp" -name exasol -type f | head -1)"
    [ -n "$_binary" ] || die "The release archive did not contain an 'exasol' binary"
    install -m 755 "$_binary" "$EXAKIT_PERSONAL_BIN"
    push_rollback "rm -f $EXAKIT_PERSONAL_BIN"
    rm -rf "$_tmp"

    ensure_path_hint "$EXAKIT_BIN_DIR"
    ok "Launcher installed: $EXAKIT_PERSONAL_BIN"
}

personal_cli() {
    # Prefer the kit-installed pinned launcher; fall back to one on PATH.
    if [ -x "$EXAKIT_PERSONAL_BIN" ]; then
        echo "$EXAKIT_PERSONAL_BIN"
    elif command -v exasol >/dev/null 2>&1; then
        command -v exasol
    else
        echo "$EXAKIT_PERSONAL_BIN"
    fi
}

personal_deployment_exists() {
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && "$(personal_cli)" info >/dev/null 2>&1
}

# personal_deployment_running — is a local Exasol deployment actually up and
# reachable right now? `exasol info` is the launcher's own source of truth, so
# this trusts it directly (no deploy-dir guard). Used to adopt an
# already-running database instead of failing on a busy port.
personal_deployment_running() {
    "$(personal_cli)" info >/dev/null 2>&1
}

# personal_deploy_local — run the local deployment. This is the long step
# (10-20 minutes on first install); output stays visible and is logged.
personal_deploy_local() {
    # A reachable Exasol is already up (this run, a previous run, or the user
    # started it by hand). `exasol info` is the launcher's own health signal.
    # Checked BEFORE the port test below so a healthy database that legitimately
    # owns port 8563 is offered for reuse rather than reported as a conflict.
    # Ask before adopting it — a piped/non-interactive install defaults to yes
    # (reuse), which is the safe, idempotent choice for automation.
    if personal_deployment_running; then
        info "An Exasol database is already running and reachable on port $EXAKIT_PERSONAL_PORT."
        if confirm "Use the running database instead of deploying a new one?" y; then
            ok "Reusing the existing Exasol deployment"
            personal_record_manifest
            return 0
        fi
        die "Declined to reuse the running database. Stop it first ('exakit stop', or 'exasol stop'), then re-run to deploy a fresh one — port $EXAKIT_PERSONAL_PORT stays in use while it is running."
    fi

    # Port busy but the launcher sees no reachable deployment on it: it is a
    # foreign process (another database, a stale container) that we must not
    # clobber. EXAKIT_DB_PORT does not apply to the macOS path, so name the
    # real port and say so honestly.
    if port_in_use "$EXAKIT_PERSONAL_PORT"; then
        die "Port $EXAKIT_PERSONAL_PORT is in use by a process that is not a reachable Exasol Personal deployment. Stop that application and re-run (EXAKIT_DB_PORT does not apply to the macOS deployment)."
    fi

    info "Deploying Exasol Personal locally — this takes 10-20 minutes on first install"
    info "Deployment output follows (also logged):"
    push_rollback "$(personal_cli) destroy --remove || true"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        "$(personal_cli)" install local 2>&1 | tee -a "$EXAKIT_LOG_FILE" || \
            die "Local deployment failed. Rerunning the installer retries it safely."
    else
        "$(personal_cli)" install local || die "Local deployment failed."
    fi

    personal_wait_ready
    personal_record_manifest
}

personal_wait_ready() {
    info "Checking deployment health"
    _tries=0
    while [ "$_tries" -lt 30 ]; do
        if "$(personal_cli)" info >/dev/null 2>&1; then
            ok "Deployment is reachable"
            return 0
        fi
        sleep 5
        _tries=$((_tries + 1))
    done
    die "Deployment does not answer to 'exasol info'. Check: $(personal_cli) info"
}

personal_record_manifest() {
    manifest_set runtime.type "personal"
    manifest_set runtime.version "$EXAKIT_PERSONAL_VERSION"
    manifest_set runtime.launcher "$(personal_cli)"
    manifest_set runtime.deployment_dir "$EXAKIT_PERSONAL_DEPLOY_DIR"

    # The deployment directory has everything a client needs:
    #   deployment.json -> host, dbPort, username, cert-validation flag
    #   secrets.json    -> dbPassword
    _dep="$EXAKIT_PERSONAL_DEPLOY_DIR/deployment.json"
    _sec="$EXAKIT_PERSONAL_DEPLOY_DIR/secrets.json"
    if [ -f "$_dep" ]; then
        require_python3
        _conn="$(run_python -c '
import json, sys
doc = json.load(open(sys.argv[1]))
c = doc.get("connection", {})
print("%s:%s\t%s" % (c.get("host", "127.0.0.1"), c.get("dbPort", 8563), c.get("username", "sys")))
' "$_dep" 2>/dev/null)"
        _dsn="$(printf '%s' "$_conn" | cut -f1)"
        _user="$(printf '%s' "$_conn" | cut -f2)"
        # A corrupt/unreadable deployment.json must not record an empty DSN.
        manifest_set runtime.dsn "${_dsn:-127.0.0.1:${EXAKIT_PERSONAL_PORT}}"
        manifest_set runtime.user "${_user:-sys}"
    else
        manifest_set runtime.dsn "127.0.0.1:${EXAKIT_PERSONAL_PORT}"
        manifest_set runtime.user "sys"
    fi
    _password=""
    if [ -f "$_sec" ]; then
        _password="$(run_python -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dbPassword",""))' "$_sec" 2>/dev/null)"
    fi
    if [ -n "$_password" ]; then
        store_credential personal_sys_password "$_password"
        manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/personal_sys_password"
    else
        warn "Could not read the database password from the deployment secrets — the exapump profile and MCP configs will ask for it or need manual completion."
    fi
    manifest_set runtime.tls "self-signed"
    manifest_set runtime.status "healthy"
}

# --- lifecycle (used by exakit) ---------------------------------------------
personal_launcher_supports() {
    "$(personal_cli)" --help 2>&1 | grep -qw "$1"
}

personal_status() {
    if ! command -v exasol >/dev/null 2>&1 && [ ! -x "$EXAKIT_PERSONAL_BIN" ]; then
        echo "not installed"
    elif personal_deployment_exists; then
        # `exasol info` answers even when the cluster is stopped — the SQL
        # port tells the truth about whether the database is actually up.
        if port_in_use "$EXAKIT_PERSONAL_PORT"; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "not deployed"
    fi
}

personal_start() {
    if personal_launcher_supports start; then
        run_logged "$(personal_cli)" start || die "Failed to start the deployment"
        ok "Deployment started"
    else
        info "This launcher version has no explicit start command."
        info "Check the deployment with: $(personal_cli) info"
    fi
}

personal_stop() {
    if personal_launcher_supports stop; then
        run_logged "$(personal_cli)" stop || die "Failed to stop the deployment"
        manifest_set runtime.status "stopped"
        ok "Deployment stopped"
    else
        info "This launcher version has no explicit stop command."
        info "To remove the deployment entirely use: exakit teardown"
    fi
}

# personal_teardown [--data] — destroy the local deployment. An Exasol
# Personal deployment keeps runtime and data together, so removing it always
# deletes the database content; without --data we refuse instead of silently
# destroying data the documented contract says would be kept.
personal_teardown() {
    if [ "${1:-}" != "--data" ]; then
        warn "Exasol Personal keeps the runtime and the database content in one deployment — removing it deletes all data."
        info "Use 'exakit stop' to stop it without deleting, or 'exakit teardown --data' to remove everything."
        return 1
    fi
    if personal_deployment_exists; then
        info "Destroying the local Exasol Personal deployment"
        run_logged "$(personal_cli)" destroy --remove || warn "Destroy reported errors (see log)"
    else
        info "No active deployment found"
    fi
    manifest_set runtime.status "removed"
}
