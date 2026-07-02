#!/usr/bin/env bash
# common.sh — shared helpers for the Exasol Personal Local Starter Kit.
#
# Sourced by setup-*.sh, exakit, and upgrade scripts. Not meant to be executed
# directly. Compatible with bash 3.2 (macOS default).
#
# Provides:
#   - structured logging (console + log file under ~/.exasol-starter-kit/logs)
#   - install manifest read/write (~/.exasol-starter-kit/manifest.json)
#   - step tracking for idempotent re-runs
#   - rollback registration and failure handling
#   - pinned component versions (overridable via EXAKIT_* env vars)
#   - download + SHA-256 verification helpers

# ---------------------------------------------------------------------------
# State locations
# ---------------------------------------------------------------------------
EXAKIT_HOME="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
EXAKIT_LOG_DIR="$EXAKIT_HOME/logs"
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"
EXAKIT_MCP_DIR="$EXAKIT_HOME/mcp"
EXAKIT_CREDS_DIR="$EXAKIT_HOME/credentials"
EXAKIT_BIN_DIR="${EXAKIT_BIN_DIR:-$HOME/.local/bin}"

# ---------------------------------------------------------------------------
# Pinned component versions (override via environment)
# ---------------------------------------------------------------------------
EXAKIT_PERSONAL_VERSION="${EXAKIT_PERSONAL_VERSION:-2.0.0-rc4}"
EXAKIT_NANO_TAG="${EXAKIT_NANO_TAG:-2026.2.0-nano.2}"
EXAKIT_EXAPUMP_VERSION="${EXAKIT_EXAPUMP_VERSION:-0.11.2}"
EXAKIT_MCP_PACKAGE="${EXAKIT_MCP_PACKAGE:-exasol-mcp-server}"
EXAKIT_MCP_VERSION="${EXAKIT_MCP_VERSION:-1.10.1}"

EXAKIT_PERSONAL_REPO="exasol/exasol-personal"
EXAKIT_EXAPUMP_REPO="exasol-labs/exapump"
EXAKIT_NANO_IMAGE="exasol/nano"

EXAKIT_DB_PORT="${EXAKIT_DB_PORT:-8563}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
exakit_init_logging() {
    mkdir -p "$EXAKIT_LOG_DIR"
    if [ -z "${EXAKIT_LOG_FILE:-}" ]; then
        EXAKIT_LOG_FILE="$EXAKIT_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
        : > "$EXAKIT_LOG_FILE"
        chmod 600 "$EXAKIT_LOG_FILE"
    fi
    export EXAKIT_LOG_FILE
}

_exakit_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_exakit_log_file() {
    [ -n "${EXAKIT_LOG_FILE:-}" ] || return 0
    printf '%s %s\n' "$(_exakit_ts)" "$*" >> "$EXAKIT_LOG_FILE"
}

info() { printf '\033[1;34m==>\033[0m %s\n' "$*";      _exakit_log_file "INFO  $*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*";      _exakit_log_file "OK    $*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2;  _exakit_log_file "WARN  $*"; }
error(){ printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2;  _exakit_log_file "ERROR $*"; }

die() {
    error "$*"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        printf 'Full log: %s\n' "$EXAKIT_LOG_FILE" >&2
    fi
    exit 1
}

# Run a command, sending its output to the log file only.
run_logged() {
    _exakit_log_file "CMD   $*"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        "$@" >> "$EXAKIT_LOG_FILE" 2>&1
    else
        "$@"
    fi
}

# Ask a yes/no question. Reads from /dev/tty so it works when the script
# itself is piped (curl | bash). Non-interactive runs take the default.
# usage: confirm "Question?" [y|n]
confirm() {
    _question="$1"
    _default="${2:-y}"
    # A usable tty is one we can actually open, not one that merely exists.
    _tty=""
    if [ -t 0 ]; then
        _tty="stdin"
    elif (: < /dev/tty) 2>/dev/null; then
        _tty="/dev/tty"
    fi
    if [ -z "$_tty" ]; then
        [ "$_default" = "y" ]
        return
    fi
    if [ "$_default" = "y" ]; then _hint="[Y/n]"; else _hint="[y/N]"; fi
    printf '\033[1;36m  ?\033[0m %s %s ' "$_question" "$_hint"
    if [ "$_tty" = "/dev/tty" ]; then read -r _answer < /dev/tty; else read -r _answer; fi
    _answer="${_answer:-$_default}"
    case "$_answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
require_python3() {
    command -v python3 >/dev/null 2>&1 && return 0
    case "$(uname -s)" in
        Darwin) _hint="Install the Apple Command Line Tools: xcode-select --install" ;;
        *)      _hint="Install it with your package manager, e.g. 'sudo apt install python3' or 'sudo dnf install python3'" ;;
    esac
    die "python3 is required (it maintains the install manifest). $_hint — then re-run."
}

manifest_init() {
    mkdir -p "$EXAKIT_HOME"
    if [ -f "$EXAKIT_MANIFEST" ]; then
        # Self-heal after an interrupted run: a manifest that no longer
        # parses is quarantined and rebuilt. Each install step re-verifies
        # what actually exists on disk, so nothing is reinstalled blindly.
        if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$EXAKIT_MANIFEST" 2>/dev/null; then
            return 0
        fi
        warn "The install manifest is corrupted (interrupted run?) — rebuilding it; existing components will be re-detected"
        mv "$EXAKIT_MANIFEST" "$EXAKIT_MANIFEST.corrupt-$(date +%s)"
    fi
    cat > "$EXAKIT_MANIFEST" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "os": "",
  "arch": "",
  "runtime": {},
  "components": {},
  "data": {
    "loaded": false
  },
  "steps_completed": [],
  "log_dir": "$EXAKIT_LOG_DIR"
}
EOF
    chmod 600 "$EXAKIT_MANIFEST"
    _exakit_log_file "INFO  Initialized manifest at $EXAKIT_MANIFEST"
}

# manifest_set <dot.path> <value>
# Value is stored as JSON if it parses as JSON, otherwise as a string.
manifest_set() {
    require_python3
    python3 - "$EXAKIT_MANIFEST" "$1" "$2" <<'PY' || die "Failed to update manifest ($1)"
import json, os, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    doc = json.load(f)
node = doc
parts = key.split(".")
for part in parts[:-1]:
    node = node.setdefault(part, {})
try:
    node[parts[-1]] = json.loads(value)
except json.JSONDecodeError:
    node[parts[-1]] = value
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# manifest_get <dot.path> — prints the value; exits non-zero if missing.
manifest_get() {
    require_python3
    python3 - "$EXAKIT_MANIFEST" "$1" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        doc = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(1)
node = doc
for part in key.split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(1)
print(node if isinstance(node, str) else json.dumps(node))
PY
}

# step_done <name> — succeeds if the step is recorded in steps_completed.
step_done() {
    [ -f "$EXAKIT_MANIFEST" ] || return 1
    require_python3
    python3 - "$EXAKIT_MANIFEST" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
sys.exit(0 if sys.argv[2] in doc.get("steps_completed", []) else 1)
PY
}

# mark_step <name> — records a completed step (idempotent). Completing a
# step also discards the undo entries registered during it: rollback only
# ever covers the step that actually failed, never a finished one (a late
# transient failure must not undo an earlier successful deployment).
mark_step() {
    require_python3
    python3 - "$EXAKIT_MANIFEST" "$1" <<'PY' || die "Failed to record step $1"
import json, os, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
steps = doc.setdefault("steps_completed", [])
if sys.argv[2] not in steps:
    steps.append(sys.argv[2])
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.replace(tmp, sys.argv[1])
PY
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && : > "$EXAKIT_ROLLBACK_FILE"
    _exakit_log_file "STEP  completed: $1"
}

# ---------------------------------------------------------------------------
# Rollback handling
#
# Steps register undo commands as they make changes. On failure the handler
# reports what failed and (interactively) offers to undo this run's changes.
# Completed runs discard their rollback stack — the manifest is then the
# source of truth for teardown.
# ---------------------------------------------------------------------------
EXAKIT_ROLLBACK_FILE=""
EXAKIT_CURRENT_STEP=""

rollback_init() {
    EXAKIT_ROLLBACK_FILE="$(mktemp "${TMPDIR:-/tmp}/exakit-rollback.XXXXXX")"
}

# push_rollback <command...> — register an undo command for the current run.
push_rollback() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] || return 0
    printf '%s\n' "$*" >> "$EXAKIT_ROLLBACK_FILE"
}

run_rollback() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && [ -s "$EXAKIT_ROLLBACK_FILE" ] || return 0
    info "Rolling back this run's changes..."
    # Execute registered undo commands in reverse order.
    awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }' \
        "$EXAKIT_ROLLBACK_FILE" | while IFS= read -r cmd; do
        _exakit_log_file "UNDO  $cmd"
        sh -c "$cmd" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || \
            warn "Rollback command failed (see log): $cmd"
    done
    : > "$EXAKIT_ROLLBACK_FILE"
    ok "Rollback finished"
}

rollback_discard() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && rm -f "$EXAKIT_ROLLBACK_FILE"
    EXAKIT_ROLLBACK_FILE=""
}

# begin_step <name> <description> — announce a step; skips if already done.
# Returns 1 when the step can be skipped (caller should honor it).
begin_step() {
    EXAKIT_CURRENT_STEP="$1"
    if step_done "$1"; then
        ok "$2 — already done, skipping"
        return 1
    fi
    info "$2"
    return 0
}

exakit_on_failure() {
    _status=$?
    [ $_status -eq 0 ] && return 0
    error "Setup failed${EXAKIT_CURRENT_STEP:+ during step: $EXAKIT_CURRENT_STEP}"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        printf '    Full log: %s\n' "$EXAKIT_LOG_FILE" >&2
    fi
    printf '    Re-running the installer is safe: completed steps are skipped.\n' >&2
    if [ "${EXAKIT_AUTO_ROLLBACK:-0}" = "1" ]; then
        run_rollback
    elif confirm "Undo the failed step's changes?" n; then
        run_rollback
    else
        info "Keeping partial progress. Re-run the installer to resume."
    fi
    rollback_discard
    exakit_release_lock
    exit $_status
}

# exakit_acquire_lock — one setup run at a time. A lock left behind by a
# dead process is detected and removed automatically.
EXAKIT_LOCK_FILE=""
exakit_acquire_lock() {
    _lock="$EXAKIT_HOME/.install.lock"
    mkdir -p "$EXAKIT_HOME"
    if [ -f "$_lock" ]; then
        _pid="$(cat "$_lock" 2>/dev/null)"
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            die "Another setup run is already in progress (pid $_pid). Wait for it to finish; if you are sure it is dead, remove $_lock and re-run."
        fi
        warn "Found a lock from an interrupted run — removing it and continuing"
        rm -f "$_lock"
    fi
    printf '%s' "$$" > "$_lock"
    EXAKIT_LOCK_FILE="$_lock"
}

exakit_release_lock() {
    [ -n "$EXAKIT_LOCK_FILE" ] && rm -f "$EXAKIT_LOCK_FILE"
    EXAKIT_LOCK_FILE=""
}

# Call once near the top of each setup script (after init_logging).
exakit_enable_failure_handling() {
    rollback_init
    exakit_acquire_lock
    trap exakit_on_failure EXIT
}

# Call at the very end of a successful run.
exakit_finish() {
    trap - EXIT
    rollback_discard
    exakit_release_lock
    EXAKIT_CURRENT_STEP=""
}

# ---------------------------------------------------------------------------
# Downloads and verification
# ---------------------------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1. $2"
}

# fetch <url> <dest-file>
fetch() {
    _url="$1"
    _dest="$2"
    mkdir -p "$(dirname "$_dest")"
    _exakit_log_file "GET   $_url -> $_dest"
    if ! curl -fL --proto '=https' --retry 3 --connect-timeout 15 \
            --progress-bar -o "$_dest" "$_url"; then
        rm -f "$_dest"
        error "Download failed: $_url"
        printf '    Check your internet connection. Behind a corporate proxy, set\n' >&2
        printf '    HTTPS_PROXY (curl honors it) and re-run. If the URL looks wrong,\n' >&2
        printf '    a version override (EXAKIT_*_VERSION) may point at a missing release.\n' >&2
        die "Could not download $(basename "$_dest")"
    fi
}

# sha256_of <file>
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "Neither shasum nor sha256sum available for checksum verification"
    fi
}

# verify_sha256 <file> <expected-hash>
verify_sha256() {
    _actual="$(sha256_of "$1")"
    if [ "$_actual" != "$2" ]; then
        error "Checksum mismatch for $(basename "$1")"
        error "  expected: $2"
        error "  actual:   $_actual"
        die "Refusing to continue with an unverified artifact"
    fi
    ok "Checksum verified: $(basename "$1")"
}

# verify_sha256_from_file <file> <checksums.txt> — looks the file up by name.
verify_sha256_from_file() {
    _name="$(basename "$1")"
    _expected="$(awk -v f="$_name" '$2 == f || $2 == "*"f {print $1; exit}' "$2")"
    [ -n "$_expected" ] || die "No checksum entry for $_name in $(basename "$2")"
    verify_sha256 "$1" "$_expected"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# ensure_path_hint <dir> — warn if dir is not on PATH (never edits rc files).
ensure_path_hint() {
    case ":$PATH:" in
        *":$1:"*) ;;
        *)
            warn "$1 is not on your PATH."
            printf '    Add this to your shell profile:\n' >&2
            printf '      export PATH="%s:$PATH"\n' "$1" >&2
            ;;
    esac
}

# kit_shared_steps <first-step-no> <total-steps> <script-dir> <kit-root>
# The steps every platform runs after its runtime is up: exapump, MCP,
# the exakit helper, and the pending-assets report. One implementation so
# the per-OS setup scripts cannot drift apart.
kit_shared_steps() {
    _step_no="$1"
    _total="$2"
    _script_dir="$3"
    _kit_root="$4"

    if command -v exapump_install >/dev/null 2>&1; then
        if begin_step exapump "Step ${_step_no}/${_total}  exapump (data loading CLI)"; then
            exapump_install
            exapump_create_profile
            exapump_validate_connection
            mark_step exapump
        fi
    else
        info "Step ${_step_no}/${_total}  exapump — module not included in this kit build yet, skipping"
    fi
    _step_no=$((_step_no + 1))

    if command -v mcp_install >/dev/null 2>&1; then
        if begin_step mcp "Step ${_step_no}/${_total}  MCP server (AI agent bridge)"; then
            mcp_install
            mcp_generate_configs
            mcp_validate
            mark_step mcp
        fi
    else
        info "Step ${_step_no}/${_total}  MCP server — module not included in this kit build yet, skipping"
    fi
    _step_no=$((_step_no + 1))

    if begin_step exakit_helper "Step ${_step_no}/${_total}  exakit helper command"; then
        mkdir -p "$EXAKIT_BIN_DIR"
        install -m 755 "$_script_dir/exakit" "$EXAKIT_BIN_DIR/exakit"
        # Keep a copy of the kit library next to the state so exakit finds
        # it even when this checkout moves or disappears.
        mkdir -p "$EXAKIT_HOME/kit/setup"
        cp -R "$_script_dir/lib" "$EXAKIT_HOME/kit/setup/"
        ensure_path_hint "$EXAKIT_BIN_DIR"
        mark_step exakit_helper
        ok "exakit installed ($EXAKIT_BIN_DIR/exakit)"
    fi

    for _pending in sql/01_create_schema.sql data/data-dictionary.md; do
        if [ ! -s "$_kit_root/$_pending" ]; then
            info "Pending: $_pending is not in this kit build yet (sample schema/data step will activate once it lands)"
        fi
    done
}

# connection_panel — the payoff screen: everything needed to connect.
# Reads the manifest; sections appear as components get installed.
connection_panel() {
    [ -f "$EXAKIT_MANIFEST" ] || { warn "No installation found ($EXAKIT_MANIFEST missing)"; return 1; }

    _type="$(manifest_get runtime.type 2>/dev/null)"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _user="$(manifest_get runtime.user 2>/dev/null)"
    _pwfile="$(manifest_get runtime.password_file 2>/dev/null)"

    printf '\n'
    printf '  ────────────────────────────────────────────────────────\n'
    printf '   Exasol Starter Kit — connection details\n'
    printf '  ────────────────────────────────────────────────────────\n'
    printf '   Runtime:      %s\n' "${_type:-unknown}"
    printf '   DSN:          %s\n' "${_dsn:-unknown}"
    printf '   User:         %s\n' "${_user:-sys}"
    if [ -n "$_pwfile" ]; then
        printf '   Password:     stored in %s\n' "$_pwfile"
    fi
    printf '   TLS:          enabled (self-signed certificate)\n'
    if [ "$_type" = "personal" ]; then
        printf '   Details:      run '\''exasol info'\'' for deployment state\n'
    fi

    _exapump="$(manifest_get components.exapump.path 2>/dev/null)"
    if [ -n "$_exapump" ]; then
        printf '   exapump:      %s (profile: %s)\n' "$_exapump" \
            "$(manifest_get components.exapump.profile 2>/dev/null)"
    fi

    _mcp="$(manifest_get components.mcp_server.configs 2>/dev/null)"
    if [ -n "$_mcp" ]; then
        printf '   MCP configs:  %s\n' "$EXAKIT_MCP_DIR"
    fi

    printf '   Manifest:     %s\n' "$EXAKIT_MANIFEST"
    printf '   Logs:         %s\n' "$EXAKIT_LOG_DIR"
    printf '  ────────────────────────────────────────────────────────\n'
    printf '\n'
}

# generate_password — local random password (not logged anywhere).
generate_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# store_credential <name> <value> — 0600 file under credentials dir.
# Written atomically so an interrupted run can never leave a truncated secret.
store_credential() {
    mkdir -p "$EXAKIT_CREDS_DIR"
    chmod 700 "$EXAKIT_CREDS_DIR"
    printf '%s' "$2" > "$EXAKIT_CREDS_DIR/$1.tmp"
    chmod 600 "$EXAKIT_CREDS_DIR/$1.tmp"
    mv "$EXAKIT_CREDS_DIR/$1.tmp" "$EXAKIT_CREDS_DIR/$1"
}

read_credential() {
    cat "$EXAKIT_CREDS_DIR/$1" 2>/dev/null
}
