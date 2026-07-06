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
EXAKIT_MANAGED_PYTHON_VERSION="${EXAKIT_MANAGED_PYTHON_VERSION:-3.12}"
EXAKIT_MCP_READONLY_USER="${EXAKIT_MCP_READONLY_USER:-mcp_readonly}"
EXAKIT_MCP_READONLY_SCHEMAS="${EXAKIT_MCP_READONLY_SCHEMAS:-STARTER_KIT}"

# ---------------------------------------------------------------------------
# Pinned component versions (override via environment)
# ---------------------------------------------------------------------------
EXAKIT_PERSONAL_VERSION="${EXAKIT_PERSONAL_VERSION:-2.0.0-rc4}"
EXAKIT_NANO_TAG="${EXAKIT_NANO_TAG:-latest}"
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
    _tty="$(_exakit_prompt_tty)"
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

_exakit_prompt_tty() {
    if [ -t 0 ]; then
        printf 'stdin\n'
    elif (: < /dev/tty) 2>/dev/null; then
        printf '/dev/tty\n'
    fi
}

prompt_text() {
    _question="$1"
    _default="${2:-}"
    _tty="$(_exakit_prompt_tty)"
    if [ -z "$_tty" ]; then
        printf '%s\n' "$_default"
        return 0
    fi
    if [ -n "$_default" ]; then
        printf '\033[1;36m  ?\033[0m %s [%s] ' "$_question" "$_default" >&2
    else
        printf '\033[1;36m  ?\033[0m %s ' "$_question" >&2
    fi
    if [ "$_tty" = "/dev/tty" ]; then read -r _answer < /dev/tty; else read -r _answer; fi
    printf '%s\n' "${_answer:-$_default}"
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
require_python3() {
    _exakit_has_system_python3 && return 0
    exakit_ensure_uv || die "A Python runtime is required, and the automatic uv bootstrap failed."
}

_exakit_has_system_python3() {
    [ "${EXAKIT_DISABLE_SYSTEM_PYTHON:-0}" != "1" ] && command -v python3 >/dev/null 2>&1
}

exakit_ensure_uv() {
    if [ -n "${EXAKIT_UV_BIN:-}" ] && [ -x "$EXAKIT_UV_BIN" ]; then
        return 0
    fi
    if command -v uv >/dev/null 2>&1; then
        EXAKIT_UV_BIN="$(command -v uv)"
        return 0
    fi
    if [ -x "$EXAKIT_BIN_DIR/uv" ]; then
        EXAKIT_UV_BIN="$EXAKIT_BIN_DIR/uv"
        return 0
    fi
    info "Installing the managed Python bootstrapper (uv)"
    mkdir -p "$EXAKIT_BIN_DIR"
    if command -v curl >/dev/null 2>&1; then
        env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh -c \
            'curl -LsSf https://astral.sh/uv/install.sh | sh' >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || return 1
    elif command -v wget >/dev/null 2>&1; then
        env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh -c \
            'wget -qO- https://astral.sh/uv/install.sh | sh' >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || return 1
    else
        warn "Neither curl nor wget is available to install uv."
        return 1
    fi
    if [ -x "$EXAKIT_BIN_DIR/uv" ]; then
        EXAKIT_UV_BIN="$EXAKIT_BIN_DIR/uv"
        ok "uv installed at $EXAKIT_UV_BIN"
        return 0
    fi
    warn "uv installation finished but the binary was not found in $EXAKIT_BIN_DIR."
    return 1
}

run_python() {
    if _exakit_has_system_python3; then
        python3 "$@"
        return $?
    fi
    exakit_ensure_uv || return 1
    "$EXAKIT_UV_BIN" run --python "$EXAKIT_MANAGED_PYTHON_VERSION" --no-project python "$@"
}

manifest_init() {
    mkdir -p "$EXAKIT_HOME"
    if [ -f "$EXAKIT_MANIFEST" ]; then
        # Self-heal after an interrupted run: a manifest that no longer
        # parses is quarantined and rebuilt. Each install step re-verifies
        # what actually exists on disk, so nothing is reinstalled blindly.
        if run_python -c 'import json,sys; json.load(open(sys.argv[1]))' "$EXAKIT_MANIFEST" 2>/dev/null; then
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
    run_python - "$EXAKIT_MANIFEST" "$1" "$2" <<'PY' || die "Failed to update manifest ($1)"
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
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY'
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
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY'
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
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY' || die "Failed to record step $1"
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

exakit_repo_root() {
    if [ -d "$EXAKIT_HOME/kit/mcp" ]; then
        printf '%s\n' "$EXAKIT_HOME/kit"
        return 0
    fi
    _common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _repo_root="$(cd "$_common_dir/../.." && pwd)"
    if [ -d "$_repo_root/mcp" ]; then
        printf '%s\n' "$_repo_root"
        return 0
    fi
    return 1
}

exakit_generate_mcp_configs() {
    require_python3
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not find the MCP package source to generate client configs."
        return 1
    }
    exakit_configure_mcp_readonly_access || return 1
    info "Generating ready-made MCP client configs"
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
            run_python -m mcp export-runtime-configs --runtime-root "$EXAKIT_HOME"
    ) >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        warn "MCP config generation failed (see log)."
        return 1
    fi
    mark_step mcp_configs
    ok "MCP client configs are ready in $EXAKIT_MCP_DIR"
    return 0
}

exakit_exapump_bin() {
    _manifest_path="$(manifest_get components.exapump.path 2>/dev/null || true)"
    if [ -n "$_manifest_path" ] && [ -x "$_manifest_path" ]; then
        printf '%s\n' "$_manifest_path"
        return 0
    fi
    if command -v exapump >/dev/null 2>&1; then
        command -v exapump
        return 0
    fi
    if [ -x "$EXAKIT_BIN_DIR/exapump" ]; then
        printf '%s\n' "$EXAKIT_BIN_DIR/exapump"
        return 0
    fi
    return 1
}

_exakit_sql_literal() {
    printf "%s" "$1" | sed "s/'/''/g"
}

_exakit_manifest_runtime_value() {
    manifest_get "$1" 2>/dev/null || true
}

_exakit_parse_runtime_host() {
    _dsn="$(_exakit_manifest_runtime_value runtime.dsn)"
    printf '%s\n' "${_dsn%%:*}"
}

_exakit_parse_runtime_port() {
    _dsn="$(_exakit_manifest_runtime_value runtime.dsn)"
    printf '%s\n' "${_dsn##*:}"
}

_exakit_first_schema() {
    _schemas="$1"
    _old_ifs="$IFS"
    IFS=', '
    set -- $_schemas
    IFS="$_old_ifs"
    printf '%s\n' "${1:-STARTER_KIT}"
}

_exakit_write_exapump_config() {
    _config_path="$1"
    _host="$2"
    _port="$3"
    _admin_user="$4"
    _admin_password="$5"
    _readonly_user="$6"
    _readonly_password="$7"
    _schema="$8"
    run_python - "$_config_path" "$_host" "$_port" "$_admin_user" "$_admin_password" "$_readonly_user" "$_readonly_password" "$_schema" <<'PY'
import sys

config_path, host, port, admin_user, admin_password, readonly_user, readonly_password, schema = sys.argv[1:]

def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

doc = [
    "[admin]\n",
    f"host = {toml_string(host)}\n",
    f"port = {port}\n",
    f"user = {toml_string(admin_user)}\n",
    f"password = {toml_string(admin_password)}\n",
    "tls = true\n",
    "validate_certificate = false\n",
    "\n",
    "[mcp_readonly]\n",
    f"host = {toml_string(host)}\n",
    f"port = {port}\n",
    f"user = {toml_string(readonly_user)}\n",
    f"password = {toml_string(readonly_password)}\n",
    f"schema = {toml_string(schema)}\n",
    "tls = true\n",
    "validate_certificate = false\n",
]
with open(config_path, "w", encoding="utf-8") as handle:
    handle.writelines(doc)
PY
    chmod 600 "$_config_path"
}

_exakit_run_exapump_sql() {
    _config_path="$1"
    _profile="$2"
    _sql="$3"
    _bin="$(exakit_exapump_bin)" || die "exapump is required for MCP read-only setup but was not found."
    EXAPUMP_CONFIG="$_config_path" "$_bin" sql -p "$_profile" "$_sql"
}

_exakit_exapump_sql_has_token() {
    _config_path="$1"
    _profile="$2"
    _sql="$3"
    _token="$4"
    _output="$(_exakit_run_exapump_sql "$_config_path" "$_profile" "$_sql" 2>> "${EXAKIT_LOG_FILE:-/dev/null}")" || return 1
    printf '%s\n' "$_output" | grep -Fq "$_token"
}

# _exakit_assert_mcp_readonly_posture <config> <user> <comma-or-space-separated schemas>
# Verifies CREATE SESSION only, SELECT on every configured schema, and no
# object privileges outside those schemas — across the *whole* schema list,
# not just the first one, so posture checks cannot miss drift on additional
# schemas (or false-positive on their legitimate SELECT grants).
_exakit_assert_mcp_readonly_posture() {
    _config_path="$1"
    _readonly_user="$2"
    _schemas="$3"
    _identifier_user="$(printf '%s' "$_readonly_user" | tr '[:lower:]' '[:upper:]')"

    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$(_exakit_sql_literal "$_identifier_user")' AND PRIVILEGE = 'CREATE SESSION') THEN 'EXAKIT_CREATE_SESSION_OK' ELSE 'EXAKIT_CREATE_SESSION_MISSING' END AS STATUS" \
        "EXAKIT_CREATE_SESSION_OK" || die "The MCP read-only user is missing CREATE SESSION."

    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_SYS_PRIV_SCOPE_OK' ELSE 'EXAKIT_SYS_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$(_exakit_sql_literal "$_identifier_user")' AND PRIVILEGE <> 'CREATE SESSION'" \
        "EXAKIT_SYS_PRIV_SCOPE_OK" || die "The MCP read-only user has system privileges beyond CREATE SESSION."

    _old_ifs="$IFS"
    IFS=', '
    set -- $_schemas
    IFS="$_old_ifs"
    _schema_or_clause=""
    _schema_scope_clause=""
    for _schema in "$@"; do
        [ -n "$_schema" ] || continue
        _schema_uc="$(printf '%s' "$_schema" | tr '[:lower:]' '[:upper:]')"
        _schema_lit="$(_exakit_sql_literal "$_schema_uc")"

        _exakit_exapump_sql_has_token \
            "$_config_path" "admin" \
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE = '$(_exakit_sql_literal "$_identifier_user")' AND PRIVILEGE = 'SELECT' AND ((OBJECT_SCHEMA = '$_schema_lit') OR (OBJECT_TYPE = 'SCHEMA' AND OBJECT_NAME = '$_schema_lit'))) THEN 'EXAKIT_SCHEMA_SELECT_OK' ELSE 'EXAKIT_SCHEMA_SELECT_MISSING' END AS STATUS" \
            "EXAKIT_SCHEMA_SELECT_OK" || die "The MCP read-only user is missing SELECT on schema $_schema_uc."

        _clause="(OBJECT_SCHEMA = '$_schema_lit') OR (OBJECT_TYPE = 'SCHEMA' AND OBJECT_NAME = '$_schema_lit')"
        if [ -z "$_schema_scope_clause" ]; then
            _schema_scope_clause="$_clause"
        else
            _schema_scope_clause="$_schema_scope_clause OR $_clause"
        fi
    done
    [ -n "$_schema_scope_clause" ] || die "No MCP read-only schemas were configured to assert posture against."

    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_SCHEMA_PRIV_SCOPE_OK' ELSE 'EXAKIT_SCHEMA_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE = '$(_exakit_sql_literal "$_identifier_user")' AND NOT (PRIVILEGE = 'SELECT' AND ($_schema_scope_clause))" \
        "EXAKIT_SCHEMA_PRIV_SCOPE_OK" || die "The MCP read-only user has object privileges beyond SELECT on the configured schemas ($_schemas)."

    for _schema in "$@"; do
        [ -n "$_schema" ] || continue
        _schema_uc="$(printf '%s' "$_schema" | tr '[:lower:]' '[:upper:]')"
        if _exakit_run_exapump_sql \
            "$_config_path" "mcp_readonly" \
            "CREATE TABLE ${_schema_uc}.EXAKIT_MCP_PERMISSION_PROBE (ID DECIMAL)" \
            >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
            _exakit_run_exapump_sql \
                "$_config_path" "admin" \
                "DROP TABLE ${_schema_uc}.EXAKIT_MCP_PERMISSION_PROBE" \
                >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || true
            die "The MCP read-only user unexpectedly succeeded in a write operation on schema $_schema_uc."
        fi
    done
}

# _exakit_reassert_mcp_readonly_posture — re-run the grant-posture check
# against the database using the credentials already on file, without
# re-provisioning anything. Used by `exakit mcp-doctor`/`mcp-validate` so
# privilege drift after install (e.g. someone widening a grant by hand) is
# actually caught, not just checked once at setup time.
# Runs the (die()-on-failure) assertion in a subshell so a posture failure
# is reported back to the caller instead of aborting the whole CLI.
_exakit_reassert_mcp_readonly_posture() {
    # Ensure exapump is on PATH (both current session and permanently)
    _exapump_bin="$(exakit_exapump_bin 2>/dev/null)" || true
    if [ -n "$_exapump_bin" ]; then
        _exapump_dir="$(dirname "$_exapump_bin")"
        case ":$PATH:" in
            *":$_exapump_dir:"*) ;;
            *)
                PATH="$_exapump_dir:$PATH"
                _exakit_add_bin_to_shell_rc "$_exapump_dir"
                ;;
        esac
    fi
    
    _runtime_user="$(_exakit_manifest_runtime_value runtime.user)"
    _runtime_password_file="$(_exakit_manifest_runtime_value runtime.password_file)"
    _readonly_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _readonly_password_file="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"
    _schemas_json="$(manifest_get components.mcp_server.connection.schemas 2>/dev/null || true)"

    if [ -z "$_runtime_user" ] || [ -z "$_runtime_password_file" ] || \
       [ -z "$_readonly_user" ] || [ -z "$_readonly_password_file" ] || [ -z "$_schemas_json" ]; then
        return 0
    fi
    [ -f "$_runtime_password_file" ] || { warn "Runtime password file missing; skipping MCP grant-posture re-check."; return 1; }
    [ -f "$_readonly_password_file" ] || { warn "MCP read-only password file missing; skipping MCP grant-posture re-check."; return 1; }

    _schemas_csv="$(run_python - "$_schemas_json" <<'PY'
import json, sys
print(",".join(json.loads(sys.argv[1])))
PY
)"
    [ -n "$_schemas_csv" ] || return 0

    _admin_password="$(cat "$_runtime_password_file")"
    _readonly_password="$(cat "$_readonly_password_file")"
    _host="$(_exakit_parse_runtime_host)"
    _port="$(_exakit_parse_runtime_port)"
    _default_schema="$(_exakit_first_schema "$_schemas_csv")"

    _temp_config="$(mktemp "${TMPDIR:-/tmp}/exakit-exapump.XXXXXX")"
    _exakit_write_exapump_config \
        "$_temp_config" "$_host" "$_port" "$_runtime_user" "$_admin_password" \
        "$_readonly_user" "$_readonly_password" "$_default_schema"

    info "Re-checking MCP read-only grant posture against the database"
    if ( _exakit_assert_mcp_readonly_posture "$_temp_config" "$_readonly_user" "$_schemas_csv" ) \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        rm -f "$_temp_config"
        ok "MCP read-only grant posture is still correct"
        return 0
    fi
    rm -f "$_temp_config"
    warn "MCP read-only grant posture has drifted from least-privilege (see log). Run 'exakit mcp-repair' or review grants manually."
    return 1
}

_exakit_validate_identifier() {
    case "$1" in
        ""|*[!A-Za-z0-9_]*)
            return 1
            ;;
    esac
    return 0
}

_exakit_validate_sql_password_token() {
    case "$1" in
        ""|[!A-Z]*|*[!A-Z0-9]*)
            return 1
            ;;
    esac
    return 0
}

_exakit_generate_sql_password_token() {
    # Generate alphanumeric password (A-Z, 0-9 only, no underscores) for maximum SQL compatibility
    # Format: A followed by 23 random uppercase/digits
    printf 'A%s\n' "$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 23)"
}

# _exakit_add_bin_to_shell_rc <bin-directory>
# Adds the bin directory to shell startup files for persistent PATH updates
# across future shell sessions. Works for bash, zsh, and sh.
_exakit_add_bin_to_shell_rc() {
    _bin_dir="$1"
    _export_line="export PATH=\"$_bin_dir:\$PATH\""
    
    # Prefer ~/.bashrc (most common for interactive bash shells)
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -Fq "$_bin_dir" "$HOME/.bashrc" 2>/dev/null; then
            printf '\n%s\n' "$_export_line" >> "$HOME/.bashrc"
            ok "Added $_bin_dir to PATH in $HOME/.bashrc"
        fi
        return 0
    fi
    
    # Fall back to ~/.profile (POSIX shell / login shells)
    if [ -f "$HOME/.profile" ]; then
        if ! grep -Fq "$_bin_dir" "$HOME/.profile" 2>/dev/null; then
            printf '\n%s\n' "$_export_line" >> "$HOME/.profile"
            ok "Added $_bin_dir to PATH in $HOME/.profile"
        fi
        return 0
    fi
    
    # For macOS or when ~/.bashrc doesn't exist, try ~/.zshrc
    if [ -f "$HOME/.zshrc" ]; then
        if ! grep -Fq "$_bin_dir" "$HOME/.zshrc" 2>/dev/null; then
            printf '\n%s\n' "$_export_line" >> "$HOME/.zshrc"
            ok "Added $_bin_dir to PATH in $HOME/.zshrc"
        fi
        return 0
    fi
    
    # If no startup file exists yet, create ~/.profile
    if ! grep -Fq "$_bin_dir" "$HOME/.profile" 2>/dev/null; then
        printf '%s\n' "$_export_line" >> "$HOME/.profile"
        ok "Added $_bin_dir to PATH in new $HOME/.profile"
    fi
}

_exakit_redact_mcp_secret_output() {
    _text="$1"
    _secret="$2"
    if [ -n "$_secret" ]; then
        _text="${_text//$_secret/<redacted>}"
    fi
    printf '%s\n' "$_text" | sed -E "s/(IDENTIFIED BY )('[^']*'|[A-Z][A-Z0-9]*(\.\.\.)?)/\1<redacted>/g"
}

exakit_configure_mcp_readonly_access() {
    require_python3
    # Ensure exapump is on PATH (both current session and permanently)
    _exapump_bin="$(exakit_exapump_bin)" || die "exapump is required for MCP read-only setup but was not found."
    _exapump_dir="$(dirname "$_exapump_bin")"
    case ":$PATH:" in
        *":$_exapump_dir:"*) ;;
        *)
            PATH="$_exapump_dir:$PATH"
            _exakit_add_bin_to_shell_rc "$_exapump_dir"
            ;;
    esac
    
    _runtime_user="$(_exakit_manifest_runtime_value runtime.user)"
    _runtime_password_file="$(_exakit_manifest_runtime_value runtime.password_file)"
    [ -n "$_runtime_user" ] || die "runtime.user is missing; cannot prepare the MCP read-only database user."
    [ -n "$_runtime_password_file" ] || die "runtime.password_file is missing; cannot prepare the MCP read-only database user."
    [ -f "$_runtime_password_file" ] || die "The runtime password file does not exist: $_runtime_password_file"
    _admin_password="$(cat "$_runtime_password_file")"
    _host="$(_exakit_parse_runtime_host)"
    _port="$(_exakit_parse_runtime_port)"
    [ -n "$_host" ] || die "runtime.dsn is missing a host; cannot prepare the MCP read-only database user."
    [ -n "$_port" ] || die "runtime.dsn is missing a port; cannot prepare the MCP read-only database user."

    _readonly_user="$EXAKIT_MCP_READONLY_USER"
    _readonly_schemas="$EXAKIT_MCP_READONLY_SCHEMAS"
    _default_schema="$(_exakit_first_schema "$_readonly_schemas")"
    _readonly_password="$(read_credential mcp_readonly_password)"
    if ! _exakit_validate_sql_password_token "$_readonly_password"; then
        _readonly_password="$(_exakit_generate_sql_password_token)"
        store_credential mcp_readonly_password "$_readonly_password"
    fi

    _identifier_user="$(printf '%s' "$_readonly_user" | tr '[:lower:]' '[:upper:]')"
    _default_schema_uc="$(printf '%s' "$_default_schema" | tr '[:lower:]' '[:upper:]')"
    _exakit_validate_identifier "$_identifier_user" || die "Invalid EXAKIT_MCP_READONLY_USER: $_readonly_user"
    _temp_config="$(mktemp "${TMPDIR:-/tmp}/exakit-exapump.XXXXXX")"
    _exakit_write_exapump_config \
        "$_temp_config" "$_host" "$_port" "$_runtime_user" "$_admin_password" \
        "$_readonly_user" "$_readonly_password" "$_default_schema_uc"

    if ! _exakit_exapump_sql_has_token \
        "$_temp_config" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = '$(_exakit_sql_literal "$_identifier_user")') THEN 'EXAKIT_MCP_USER_PRESENT' ELSE 'EXAKIT_MCP_USER_MISSING' END AS STATUS" \
        "EXAKIT_MCP_USER_PRESENT"; then
        info "Creating the dedicated MCP read-only database user ($_readonly_user)"
        _create_user_output="$(_exakit_run_exapump_sql \
            "$_temp_config" "admin" \
            "CREATE USER ${_identifier_user} IDENTIFIED BY ${_readonly_password}" 2>&1)"
        if [ $? -ne 0 ]; then
            _create_user_redacted="$(_exakit_redact_mcp_secret_output "$_create_user_output" "$_readonly_password")"
            _exakit_log_file "ERROR_DETAIL $_create_user_redacted"
            error "CREATE USER details: $_create_user_redacted"
            die "Could not create the MCP read-only database user."
        fi
        _create_user_redacted="$(_exakit_redact_mcp_secret_output "$_create_user_output" "$_readonly_password")"
        [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_create_user_redacted" >> "$EXAKIT_LOG_FILE"
    fi

    _alter_user_output="$(_exakit_run_exapump_sql \
        "$_temp_config" "admin" \
        "ALTER USER ${_identifier_user} IDENTIFIED BY ${_readonly_password}" 2>&1)"
    if [ $? -ne 0 ]; then
        _alter_user_redacted="$(_exakit_redact_mcp_secret_output "$_alter_user_output" "$_readonly_password")"
        _exakit_log_file "ERROR_DETAIL $_alter_user_redacted"
        error "ALTER USER details: $_alter_user_redacted"
        die "Could not refresh the MCP read-only database password."
    fi
    _alter_user_redacted="$(_exakit_redact_mcp_secret_output "$_alter_user_output" "$_readonly_password")"
    [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_alter_user_redacted" >> "$EXAKIT_LOG_FILE"
    _exakit_run_exapump_sql \
        "$_temp_config" "admin" \
        "GRANT CREATE SESSION TO ${_identifier_user}" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not grant CREATE SESSION to the MCP read-only database user."

    _old_ifs="$IFS"
    IFS=', '
    set -- $_readonly_schemas
    IFS="$_old_ifs"
    for _schema in "$@"; do
        [ -n "$_schema" ] || continue
        _schema_uc="$(printf '%s' "$_schema" | tr '[:lower:]' '[:upper:]')"
        _exakit_validate_identifier "$_schema_uc" || die "Invalid MCP schema name: $_schema"
        if ! _exakit_exapump_sql_has_token \
            "$_temp_config" "admin" \
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$(_exakit_sql_literal "$_schema_uc")') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS" \
            "EXAKIT_SCHEMA_PRESENT"; then
            info "Creating starter schema $_schema_uc for MCP-safe querying"
            _exakit_run_exapump_sql "$_temp_config" "admin" "CREATE SCHEMA ${_schema_uc}" \
                >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not create schema $_schema_uc for MCP access."
        fi
        _exakit_run_exapump_sql "$_temp_config" "admin" "GRANT SELECT ON SCHEMA ${_schema_uc} TO ${_identifier_user}" \
            >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not grant read-only access on schema $_schema_uc."
    done

    info "Validating dedicated MCP read-only login"
    _exakit_exapump_sql_has_token \
        "$_temp_config" "mcp_readonly" \
        "SELECT CURRENT_USER AS EXAKIT_CURRENT_USER" \
        "$_identifier_user" || die "The MCP read-only user could not log in with the generated credentials."
    _exakit_exapump_sql_has_token \
        "$_temp_config" "mcp_readonly" \
        "SELECT 'EXAKIT_MCP_READONLY_OK' AS STATUS" \
        "EXAKIT_MCP_READONLY_OK" || die "The MCP read-only user did not pass the validation query."
    _exakit_assert_mcp_readonly_posture "$_temp_config" "$_readonly_user" "$_readonly_schemas"

    manifest_set components.mcp_server.connection.user "$_readonly_user"
    manifest_set components.mcp_server.connection.password_file "$EXAKIT_CREDS_DIR/mcp_readonly_password"
    manifest_set components.mcp_server.connection.schemas "[\"$(printf '%s' "$_readonly_schemas" | tr ',' '\n' | sed '/^$/d' | paste -sd '","' -)\"]"
    manifest_set components.mcp_server.connection.validated "true"
    rm -f "$_temp_config"
    ok "Dedicated MCP read-only access is configured and validated"
    return 0
}

exakit_run_mcp_setup_cli() {
    _mode="$1"
    _clients_csv="$2"
    _output_file="$3"
    require_python3
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not find the MCP package source to configure MCP clients."
        return 1
    }
    exakit_configure_mcp_readonly_access || return 1
    _old_ifs="$IFS"
    IFS=','
    set -- $_clients_csv
    IFS="$_old_ifs"
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
            run_python -m mcp setup-runtime-clients \
                --runtime-root "$EXAKIT_HOME" \
                --mode "$_mode" \
                --clients "$@"
    ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        warn "MCP client setup failed (see log)."
        return 1
    fi
    return 0
}

exakit_run_mcp_operation_cli() {
    _operation="$1"
    _clients_csv="$2"
    _output_file="$3"
    _snapshot_id="${4:-}"
    require_python3
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not find the MCP package source to manage MCP clients."
        return 1
    }
    case "$_operation" in
        validate|repair|doctor)
            exakit_configure_mcp_readonly_access || return 1
            ;;
    esac
    _old_ifs="$IFS"
    IFS=','
    set -- $_clients_csv
    IFS="$_old_ifs"
    if [ -n "$_snapshot_id" ]; then
        if ! (
            cd "$_repo_root" &&
            PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
                run_python -m mcp run-runtime-operation \
                    "$_operation" \
                    --runtime-root "$EXAKIT_HOME" \
                    --snapshot-id "$_snapshot_id" \
                    --clients "$@"
        ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
            warn "MCP $_operation failed (see log)."
            return 1
        fi
        return 0
    fi
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
            run_python -m mcp run-runtime-operation \
                "$_operation" \
                --runtime-root "$EXAKIT_HOME" \
                --clients "$@"
    ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        warn "MCP $_operation failed (see log)."
        return 1
    fi
    return 0
}

exakit_print_mcp_setup_summary() {
    _result_file="$1"
    require_python3
    run_python - "$_result_file" <<'PY'
import json, sys

LABELS = {
    "claude_desktop": "Claude Desktop",
    "cursor": "Cursor",
    "codex": "Codex",
}

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)

clients = ", ".join(LABELS.get(item, item) for item in doc.get("selected_clients", []))
print("")
print("  MCP setup summary")
print(f"  Mode:     {doc.get('mode', 'unknown')}")
if doc.get("mode") == "temporary":
    print("  Meaning:  Generated config files only; no AI client config was changed.")
elif doc.get("mode") == "permanent":
    print("  Meaning:  Wrote managed MCP entries into the selected client config files.")
print(f"  Clients:  {clients or 'none'}")
print(f"  Status:   {doc.get('status', 'unknown')}")
if doc.get("mode") == "temporary":
    print(f"  Bundle:   {doc.get('bundle_dir', 'unknown')}")
for artifact in doc.get("artifacts", []):
    client = LABELS.get(artifact.get("client"), artifact.get("client", "unknown"))
    print(f"  File:     {client} -> {artifact.get('path', 'unknown')}")

findings = doc.get("findings", [])
if findings:
    print("")
    print("  Notes:")
    for finding in findings:
        print(f"  - {finding.get('message', 'Unknown issue')}")

actions = doc.get("next_actions", [])
if actions:
    print("")
    print("  Next:")
    for action in actions:
        print(f"  - {action.get('message', '')}")
PY
}

exakit_print_mcp_ready_panel() {
    _mode="${1:-}"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null || true)"
    _mcp_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _mcp_package="$(manifest_get components.mcp_server.package 2>/dev/null || printf '%s' "$EXAKIT_MCP_PACKAGE")"
    _mcp_version="$(manifest_get components.mcp_server.version 2>/dev/null || printf '%s' "$EXAKIT_MCP_VERSION")"
    _mcp_command="$(manifest_get components.mcp_server.command 2>/dev/null || true)"
    _tls="$(manifest_get runtime.tls 2>/dev/null || true)"
    [ -n "$_mcp_command" ] || _mcp_command="uvx"

    printf '\n'
    printf '  MCP is ready\n'
    printf '  Server name:   exasol\n'
    printf '  How it runs:   your AI client starts it on demand over stdio\n'
    printf '  Command:       %s %s@%s\n' "$_mcp_command" "$_mcp_package" "$_mcp_version"
    printf '  Database:      %s\n' "${_dsn:-unknown}"
    printf '  DB user:       %s (read-only)\n' "${_mcp_user:-mcp_readonly}"
    if [ "$_tls" = "self-signed" ]; then
        printf '  TLS:           local self-signed certificate accepted for 127.0.0.1\n'
    fi
    printf '  Config bundle: %s\n' "$EXAKIT_MCP_DIR"
    printf '\n'
    if [ "$_mode" = "temporary" ]; then
        printf '  Temporary mode did not change your AI client config.\n'
        printf '  Next steps:\n'
        printf '  1. Open the generated config file for your client from the bundle above.\n'
        printf '  2. Copy or merge it into that AI client MCP config.\n'
        printf '  3. Restart the client.\n'
    else
        printf '  Permanent mode updated the selected client config files.\n'
        printf '  Next step: restart the selected client now.\n'
    fi
    printf '  After setup/restart, look for an MCP server named: exasol\n'
    printf '\n'
    printf '  First prompt to try in your AI client:\n'
    printf '  "Use the exasol MCP server connected to my local Exasol database. List\n'
    printf '  the available schemas and tables first. Then answer my questions with\n'
    printf '  read-only SQL only, show me the SQL before you run it, and do not create,\n'
    printf '  update, or delete anything."\n'
}

exakit_print_mcp_operation_summary() {
    _result_file="$1"
    require_python3
    run_python - "$_result_file" <<'PY'
import json, sys

LABELS = {
    "claude_desktop": "Claude Desktop",
    "cursor": "Cursor",
    "codex": "Codex",
}

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)

clients = ", ".join(LABELS.get(item, item) for item in doc.get("selected_clients", []))
print("")
print("  MCP operation summary")
print(f"  Operation: {doc.get('operation', 'unknown')}")
print(f"  Clients:   {clients or 'all managed clients'}")
print(f"  Status:    {doc.get('status', 'unknown')}")
print(f"  Summary:   {doc.get('summary', 'No summary returned')}")
if doc.get("backup_reference"):
    print(f"  Snapshot:  {doc.get('backup_reference')}")

changes = doc.get("changes", [])
if changes:
    print("")
    print("  Changes:")
    for change in changes:
        print(f"  - {change.get('kind', 'change')} {change.get('path', '')}")

findings = doc.get("findings", [])
if findings:
    print("")
    print("  Notes:")
    for finding in findings:
        print(f"  - {finding.get('message', 'Unknown issue')}")

actions = doc.get("next_actions", [])
if actions:
    print("")
    print("  Next:")
    for action in actions:
        print(f"  - {action.get('message', '')}")
PY
}

exakit_mcp_clients_from_args() {
    if [ "$#" -eq 0 ]; then
        printf '%s\n' "claude_desktop,cursor,codex"
        return 0
    fi
    exakit_parse_mcp_client_selection "$*"
}

exakit_parse_mcp_client_selection() {
    _raw="$(printf '%s' "$1" | tr ',/' '  ' | tr -s ' ')"
    case "$_raw" in
        "" ) return 1 ;;
        all|ALL|All ) printf '%s\n' "claude_desktop,cursor,codex"; return 0 ;;
    esac
    _result=""
    for _token in $_raw; do
        case "$_token" in
            1|claude|claude_desktop) _client="claude_desktop" ;;
            2|cursor) _client="cursor" ;;
            3|codex) _client="codex" ;;
            *) return 1 ;;
        esac
        case ",$_result," in
            *,"$_client",*) ;;
            *)
                if [ -n "$_result" ]; then
                    _result="$_result,$_client"
                else
                    _result="$_client"
                fi
                ;;
        esac
    done
    [ -n "$_result" ] || return 1
    printf '%s\n' "$_result"
}

exakit_mcp_setup() {
    info "Choose how you want MCP set up in your AI clients"
    printf '    1. Default: Permanent setup (edit selected clients now)\n'
    printf '    2. Temporary setup (copy/paste instructions only)\n'
    printf '\n'
    printf '    Quick guide:\n'
    printf '       Choose 1 if you want the kit to configure the apps for you.\n'
    printf '       Choose 2 if you only want files and copy/paste steps.\n'
    while :; do
        _mode_choice="$(prompt_text "Choose setup mode (1 permanent, 2 temporary)" "1")"
        case "$_mode_choice" in
            1|permanent|Permanent|default|Default) _mode="permanent"; break ;;
            2|temporary|Temporary) _mode="temporary"; break ;;
            *) warn "Please enter 1 for permanent or 2 for temporary." ;;
        esac
    done

    printf '\n'
    info "Choose one or more clients"
    printf '    1. Claude Desktop\n'
    printf '    2. Cursor\n'
    printf '    3. Codex\n'
    printf '    Enter numbers separated by commas, or type all.\n'
    while :; do
        _selection="$(prompt_text "Choose client numbers" "all")"
        _clients_csv="$(exakit_parse_mcp_client_selection "$_selection")" && break
        warn "Please choose valid client numbers, for example 1,2,3 or all."
    done

    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-setup.XXXXXX")"
    info "Applying MCP setup ($_mode mode)"
    _setup_status=0
    if exakit_run_mcp_setup_cli "$_mode" "$_clients_csv" "$_result_file"; then
        :
    else
        _setup_status=$?
    fi
    if [ -s "$_result_file" ]; then
        exakit_print_mcp_setup_summary "$_result_file"
    fi
    rm -f "$_result_file"
    if [ "$_setup_status" -ne 0 ]; then
        return "$_setup_status"
    fi
    exakit_print_mcp_ready_panel "$_mode"
    ok "MCP setup guidance is ready."
    return 0
}

exakit_mcp_operation() {
    _operation="$1"
    shift
    _clients_csv="$(exakit_mcp_clients_from_args "$@")" || {
        warn "Please choose valid MCP clients: claude_desktop, cursor, codex, or all."
        return 1
    }
    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-operation.XXXXXX")"
    _operation_status=0
    info "Running MCP $_operation"
    if exakit_run_mcp_operation_cli "$_operation" "$_clients_csv" "$_result_file"; then
        :
    else
        _operation_status=$?
    fi
    if [ -s "$_result_file" ]; then
        exakit_print_mcp_operation_summary "$_result_file"
    fi
    rm -f "$_result_file"

    case "$_operation" in
        doctor|validate)
            _exakit_reassert_mcp_readonly_posture || _operation_status=1
            ;;
    esac

    return "$_operation_status"
}

exakit_mcp_restore() {
    _snapshot_id="${1:-}"
    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-restore.XXXXXX")"
    _operation_status=0
    info "Running MCP restore"
    if exakit_run_mcp_operation_cli "restore" "claude_desktop,cursor,codex" "$_result_file" "$_snapshot_id"; then
        :
    else
        _operation_status=$?
    fi
    if [ -s "$_result_file" ]; then
        exakit_print_mcp_operation_summary "$_result_file"
    fi
    rm -f "$_result_file"
    return "$_operation_status"
}

exakit_maybe_offer_mcp_setup() {
    _already_done="$(manifest_get components.mcp_server.client_setup.completed 2>/dev/null || true)"
    [ "$_already_done" = "true" ] && return 0
    if [ -z "$(_exakit_prompt_tty)" ]; then
        info "Non-interactive install - setting up MCP in your AI client(s) by default."
        if ! exakit_mcp_setup; then
            warn "Your local runtime is installed, but MCP client setup did not finish cleanly."
            warn "Retry any time with: exakit mcp-setup"
        fi
        return 0
    fi
    info "The Exasol runtime and MCP server are ready."
    if ! confirm "Set up MCP in your AI client(s) now?" y; then
        info "Skipping live MCP client setup for now. You can run: exakit mcp-setup"
        return 0
    fi
    if ! exakit_mcp_setup; then
        warn "Your local runtime is installed, but MCP client setup did not finish cleanly."
        warn "Retry any time with: exakit mcp-setup"
    fi
}

# exakit_maybe_offer_data_load <kit_root> — interactively offer the guided data
# loading menu during install. Non-interactive installs print the follow-up
# command and continue. The selected load runs in a subshell so a die() inside
# the loading flow never aborts the surrounding install.
exakit_maybe_offer_data_load() {
    _kit_root="$1"
    : "$_kit_root"
    command -v exakit_data_load_menu >/dev/null 2>&1 || return 0

    if [ -z "$(_exakit_prompt_tty)" ]; then
        info "Non-interactive install - loading the bundled sample data by default."
        if ! ( exakit_load_sample_data "$_kit_root" ); then
            warn "Data loading did not finish cleanly. Retry any time with: exakit data-load"
        fi
        return 0
    fi

    info "The database is ready for data. Loading data now lets MCP validate against real tables."
    if ! confirm "Load or verify data before MCP setup?" y; then
        info "Skipping data loading. Run it any time with: exakit data-load"
        return 0
    fi
    if ( exakit_data_load_menu ); then
        :
    else
        warn "Data loading did not finish cleanly. Retry any time with: exakit data-load"
    fi
}

# kit_shared_steps <first-step-no> <total-steps> <script-dir> <kit-root>
# The steps every platform runs after its runtime is up, in order: exapump,
# the sample-data load offer, the MCP server, the exakit helper, and the MCP
# client setup offer. Data is loaded before MCP so the read-only user is
# provisioned against a populated schema. One implementation so the per-OS
# setup scripts cannot drift apart.
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

    # Load the sample data before any MCP configuration. exapump is now up
    # (its only dependency), and doing this first means the read-only MCP
    # user is provisioned, granted, and posture-checked against a schema
    # that already holds the sample tables — and the AI client has data to
    # query the moment it connects.
    exakit_maybe_offer_data_load "$_kit_root" || true

    if command -v mcp_install >/dev/null 2>&1; then
        if begin_step mcp "Step ${_step_no}/${_total}  MCP server (AI agent bridge)"; then
            mcp_install
            if exakit_generate_mcp_configs; then
                mcp_validate
                mark_step mcp
            else
                warn "MCP client config generation failed — re-run 'exakit mcp-configs' once the issue above is fixed."
            fi
        fi
    else
        info "Step ${_step_no}/${_total}  MCP server — module not included in this kit build yet, skipping"
    fi
    _step_no=$((_step_no + 1))

    if begin_step exakit_helper "Step ${_step_no}/${_total}  exakit helper command"; then
        mkdir -p "$EXAKIT_BIN_DIR"
        install -m 755 "$_script_dir/exakit" "$EXAKIT_BIN_DIR/exakit"
        # Keep a copy of the kit library (and the mcp/ and sql/ packages
        # exakit_repo_root() depends on) next to the state so exakit finds
        # them even when this checkout moves or disappears.
        mkdir -p "$EXAKIT_HOME/kit/setup"
        cp -R "$_script_dir/lib" "$EXAKIT_HOME/kit/setup/"
        # Copy the assets exakit needs after the checkout is gone: the mcp/
        # and sql/ packages, the data/ CSVs, and load-data.sh (so both
        # `exakit load-data` and the documented
        # ~/.exasol-starter-kit/kit/setup/load-data.sh command keep working).
        [ -d "$_kit_root/mcp" ] && cp -R "$_kit_root/mcp" "$EXAKIT_HOME/kit/"
        [ -d "$_kit_root/sql" ] && cp -R "$_kit_root/sql" "$EXAKIT_HOME/kit/"
        [ -d "$_kit_root/data" ] && cp -R "$_kit_root/data" "$EXAKIT_HOME/kit/"
        [ -f "$_script_dir/load-data.sh" ] && cp "$_script_dir/load-data.sh" "$EXAKIT_HOME/kit/setup/"
        ensure_path_hint "$EXAKIT_BIN_DIR"
        mark_step exakit_helper
        ok "exakit installed ($EXAKIT_BIN_DIR/exakit)"
    fi

    exakit_maybe_offer_mcp_setup || true
}

# connection_panel — the payoff screen: everything needed to connect.
# Reads the manifest; sections appear as components get installed.
connection_panel() {
    [ -f "$EXAKIT_MANIFEST" ] || { warn "No installation found ($EXAKIT_MANIFEST missing)"; return 1; }

    _type="$(manifest_get runtime.type 2>/dev/null)"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _user="$(manifest_get runtime.user 2>/dev/null)"
    _pwfile="$(manifest_get runtime.password_file 2>/dev/null)"
    _mcp_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _mcp_pwfile="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"

    printf '\n'
    printf '  ────────────────────────────────────────────────────────\n'
    printf '   Exasol Starter Kit — connection details\n'
    printf '  ────────────────────────────────────────────────────────\n'
    printf '   Runtime:      %s\n' "${_type:-unknown}"
    printf '   DSN:          %s\n' "${_dsn:-unknown}"
    printf '   Admin user:   %s\n' "${_user:-sys}"
    if [ -n "$_pwfile" ]; then
        printf '   Admin pass:   stored in %s\n' "$_pwfile"
    fi
    if [ -n "$_mcp_user" ]; then
        printf '   MCP user:     %s\n' "$_mcp_user"
    fi
    if [ -n "$_mcp_pwfile" ]; then
        printf '   MCP pass:     stored in %s\n' "$_mcp_pwfile"
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
