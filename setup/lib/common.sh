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
#   - component version resolution (latest by default, overridable via env)
#   - download + SHA-256 verification helpers

# ---------------------------------------------------------------------------
# Shared visual layer (banner, boxes, spinner, colour palette)
# ---------------------------------------------------------------------------
# ui.sh owns how the installer LOOKS. Source it first so info/ok/begin_step/
# connection_panel below can use its glyphs and palette. If it is somehow
# absent, install no-op stubs so nothing here breaks under `set -u`.
_exakit_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _exakit_common_dir=''
[ -n "$_exakit_common_dir" ] && [ -f "$_exakit_common_dir/ui.sh" ] && . "$_exakit_common_dir/ui.sh"
if ! command -v ui_spin_begin >/dev/null 2>&1; then
    UI_FANCY=0; UI_RESET=''; UI_BOLD=''; UI_DIM=''; UI_ACCENT=''
    UI_INFO=''; UI_OK=''; UI_WARN=''; UI_ERR=''; UI_ASK=''
    UI_TICK='[ok]'; UI_CROSS='[x]'; UI_ARROW='>'; UI_BULLET='-'
    ui_spin_begin() { :; }; ui_spin_end() { :; }; ui_restore_cursor() { :; }
    ui_banner()     { printf '\n  %s\n' "${1:-Exasol Personal Local Starter Kit}"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; printf '\n'; }
    ui_panel_begin() { printf '\n  -- %s --\n' "${1:-}"; }
    ui_panel_line()  { printf '   %s\n' "$1"; }
    ui_panel_end()   { printf '\n'; }
fi

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
# Component version policy
# ---------------------------------------------------------------------------
EXAKIT_VERSION_POLICY="${EXAKIT_VERSION_POLICY:-latest}"
EXAKIT_PERSONAL_VERSION="${EXAKIT_PERSONAL_VERSION:-}"
EXAKIT_NANO_TAG="${EXAKIT_NANO_TAG:-}"
EXAKIT_EXAPUMP_VERSION="${EXAKIT_EXAPUMP_VERSION:-}"
EXAKIT_MCP_PACKAGE="${EXAKIT_MCP_PACKAGE:-exasol-mcp-server}"
EXAKIT_MCP_VERSION="${EXAKIT_MCP_VERSION:-}"
EXAKIT_PYEXASOL_VERSION="${EXAKIT_PYEXASOL_VERSION:-}"

# Last-known-good fallbacks are used only when a latest-version lookup is not
# possible (offline install, API rate limit, private mirror). Successful latest
# resolutions are recorded in the manifest so later updates compare against the
# version that was actually installed.
EXAKIT_PERSONAL_VERSION_FALLBACK="${EXAKIT_PERSONAL_VERSION_FALLBACK:-2.0.0-rc4}"
EXAKIT_NANO_TAG_FALLBACK="${EXAKIT_NANO_TAG_FALLBACK:-2026.2.0-nano.2}"
EXAKIT_EXAPUMP_VERSION_FALLBACK="${EXAKIT_EXAPUMP_VERSION_FALLBACK:-0.11.2}"
EXAKIT_MCP_VERSION_FALLBACK="${EXAKIT_MCP_VERSION_FALLBACK:-1.10.1}"
EXAKIT_PYEXASOL_VERSION_FALLBACK="${EXAKIT_PYEXASOL_VERSION_FALLBACK:-2.2.2}"

EXAKIT_PERSONAL_REPO="exasol/exasol-personal"
EXAKIT_EXAPUMP_REPO="exasol-labs/exapump"
EXAKIT_NANO_IMAGE="exasol/nano"
EXAKIT_KIT_REPO="${EXAKIT_KIT_REPO:-${EXAKIT_REPO:-ranjanm-chn/exasol-personal-local-starter-kit}}"
EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT="${EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT:-5}"
EXAKIT_VERSION_LOOKUP_MAX_TIME="${EXAKIT_VERSION_LOOKUP_MAX_TIME:-12}"

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
    # Best-effort: the log directory may already be gone (e.g. during
    # `uninstall`, which deletes the kit home). A failed redirection-open is
    # reported to the *group's* stderr before a trailing `2>/dev/null` on the
    # printf would apply, so redirect at the group level and also skip early if
    # the directory is missing. Never let logging fail a command.
    [ -d "$(dirname "$EXAKIT_LOG_FILE")" ] || return 0
    { printf '%s %s\n' "$(_exakit_ts)" "$*" >> "$EXAKIT_LOG_FILE"; } 2>/dev/null || return 0
}

# Glyphs/colours come from the shared palette (ui.sh): bold + Unicode on an
# interactive UTF-8 terminal, plain ASCII with no escapes when piped/CI/log.
info() { printf '%s==>%s %s\n'   "${UI_INFO:-}" "${UI_RESET:-}" "$*";            _exakit_log_file "INFO  $*"; }
ok()   { printf '  %s%s%s %s\n'  "${UI_OK:-}"   "${UI_TICK:-[ok]}"  "${UI_RESET:-}" "$*"; _exakit_log_file "OK    $*"; }
warn() { printf '  %s!%s %s\n'   "${UI_WARN:-}" "${UI_RESET:-}" "$*" >&2;        _exakit_log_file "WARN  $*"; }
error(){ printf '  %s%s%s %s\n'  "${UI_ERR:-}"  "${UI_CROSS:-[x]}" "${UI_RESET:-}" "$*" >&2; _exakit_log_file "ERROR $*"; }

# Sensitive temp files (they hold plaintext credentials) are tracked here so
# they are ALWAYS removed — including on die/exit/interrupt, not only on the
# happy path. Callers register the file right after creating it; die() and the
# EXIT handler both sweep, so no failure path can leave credentials on disk.
EXAKIT_SENSITIVE_TMP=""
exakit_track_sensitive_tmp() { EXAKIT_SENSITIVE_TMP="$EXAKIT_SENSITIVE_TMP $1"; }
exakit_sweep_sensitive_tmp() {
    [ -n "${EXAKIT_SENSITIVE_TMP:-}" ] || return 0
    rm -f $EXAKIT_SENSITIVE_TMP 2>/dev/null
    EXAKIT_SENSITIVE_TMP=""
}

die() {
    exakit_sweep_sensitive_tmp
    error "$*"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        printf 'Full log: %s\n' "$EXAKIT_LOG_FILE" >&2
    fi
    exit 1
}

# Run a command, sending its output to the log file only. While it runs (and
# only on an interactive terminal), show a spinner labelled with the current
# step — this is the single hook that animates every silent, long-running
# operation. run_logged never reads stdin, so the spinner is always safe;
# interactive prompts use a separate /dev/tty path and are untouched.
run_logged() {
    _exakit_log_file "CMD   $*"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-working}"
        "$@" >> "$EXAKIT_LOG_FILE" 2>&1
        _run_logged_rc=$?
        ui_spin_end
        return $_run_logged_rc
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
    printf '  %s?%s %s %s%s%s ' "${UI_ASK:-}" "${UI_RESET:-}" "$_question" "${UI_DIM:-}" "$_hint" "${UI_RESET:-}"
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
        printf '  %s?%s %s %s[%s]%s ' "${UI_ASK:-}" "${UI_RESET:-}" "$_question" "${UI_DIM:-}" "$_default" "${UI_RESET:-}" >&2
    else
        printf '  %s?%s %s ' "${UI_ASK:-}" "${UI_RESET:-}" "$_question" >&2
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

# Optional Python for best-effort flows (latest-version checks, digest lookup).
# Unlike require_python3, this never exits: callers can fall back to shell
# parsing or report "unknown" instead of failing a status/update-check command.
exakit_can_run_python() {
    _exakit_has_system_python3 && return 0
    exakit_ensure_uv >/dev/null 2>&1
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

# ---------------------------------------------------------------------------
# Version resolution and update planning
# ---------------------------------------------------------------------------
exakit_installation_runtime_type() {
    manifest_get runtime.type 2>/dev/null
}

exakit_installation_runtime_version() {
    case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
        nano)
            _image="$(manifest_get runtime.image 2>/dev/null || true)"
            printf '%s\n' "${_image##*:}"
            ;;
        personal) manifest_get runtime.version 2>/dev/null ;;
        *) return 1 ;;
    esac
}

exakit_record_desired_versions() {
    manifest_set version_policy "$EXAKIT_VERSION_POLICY"
    manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
    manifest_set desired.runtime.nano "$EXAKIT_NANO_TAG"
    manifest_set desired.exapump "$EXAKIT_EXAPUMP_VERSION"
    manifest_set desired.mcp "$EXAKIT_MCP_VERSION"
    manifest_set desired.pyexasol "$EXAKIT_PYEXASOL_VERSION"
}

exakit_update_actual_target() {
    case "$1" in
        runtime|database|db)
            _rtype="$(exakit_installation_runtime_type 2>/dev/null || true)"
            [ -n "$_rtype" ] || return 1
            printf '%s\n' "$_rtype"
            ;;
        *) printf '%s\n' "$1" ;;
    esac
}

exakit_latest_github_release_version() {
    _repo="$1"
    _json="$(curl -fsSL --retry 1 --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        "https://api.github.com/repos/${_repo}/releases/latest" 2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c 'import json,sys; print(json.load(sys.stdin).get("tag_name","").lstrip("v"))' 2>/dev/null
        return $?
    fi
    printf '%s' "$_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1
}

exakit_latest_pypi_version() {
    _package="$1"
    _json="$(curl -fsSL --retry 1 --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        "https://pypi.org/pypi/${_package}/json" 2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("version",""))' 2>/dev/null
        return $?
    fi
    printf '%s' "$_json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Normalise the host CPU to a docker image arch token: amd64 | arm64 | "".
_exakit_docker_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo arm64 ;;
        x86_64|amd64)  echo amd64 ;;
        *) echo "" ;;
    esac
}

exakit_latest_docker_tag() {
    _image="$1"
    # Pick the newest tag that fits THIS machine's architecture. Exasol Nano
    # publishes arch-suffixed tags (…-arm64, …-amd64) next to the plain
    # multi-arch tag; without filtering, the version sort lands on -arm64 (it
    # sorts after -amd64), so an x86_64 host would pull an arm64 image and run
    # it under slow emulation. Keep the plain (multi-arch) tags plus this
    # host's own arch, and drop the other architecture's tags.
    _dt_arch="$(_exakit_docker_arch)"
    _json="$(curl -fsSL --retry 1 --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        "https://hub.docker.com/v2/repositories/${_image}/tags?page_size=100&ordering=last_updated" 2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c '
import json, re, sys
doc = json.load(sys.stdin)
arch = sys.argv[1] if len(sys.argv) > 1 else ""
tags = [r.get("name","") for r in doc.get("results", [])]
pattern = re.compile(r"^\d+(?:\.\d+)+(?:[-._A-Za-z0-9]+)?$")
amd = {"amd64", "x86_64", "x86-64"}
arm = {"arm64", "aarch64"}
wrong = arm if arch in amd else (amd if arch in arm else set())
def ok_arch(tag):
    return not any(seg in wrong for seg in re.split(r"[-._]", tag.lower()))
candidates = [t for t in tags if pattern.match(t) and "latest" not in t.lower() and ok_arch(t)]
def key(tag):
    parts = re.split(r"([0-9]+)", tag)
    return [int(p) if p.isdigit() else p for p in parts]
print(sorted(candidates, key=key)[-1] if candidates else "")
' "$_dt_arch" 2>/dev/null
        return $?
    fi
    # Shell fallback (no Python/uv): Docker Hub returns newest-first with
    # ordering=last_updated. Drop the other architecture's suffixed tags, then
    # take the newest of what remains.
    _dt_reject=""
    case "$_dt_arch" in
        amd64) _dt_reject='[-._](arm64|aarch64)$' ;;
        arm64) _dt_reject='[-._](amd64|x86_64|x86-64)$' ;;
    esac
    _dt_names="$(printf '%s' "$_json" | tr ',' '\n' | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
        grep -E '^[0-9]+(\.[0-9]+)+[-._A-Za-z0-9]*$' | grep -vi latest)"
    [ -n "$_dt_reject" ] && _dt_names="$(printf '%s\n' "$_dt_names" | grep -viE "$_dt_reject")"
    printf '%s\n' "$_dt_names" | head -1
}

exakit_version_newer() {
    _latest="$1"
    _current="$2"
    [ -n "$_latest" ] && [ -n "$_current" ] || return 1
    [ "$_latest" != "$_current" ] || return 1
    if exakit_can_run_python; then
        run_python - "$_latest" "$_current" <<'PY'
import re, sys
def key(v):
    v = v.strip().lstrip("v")
    return [int(p) if p.isdigit() else p for p in re.split(r"([0-9]+)", v)]
sys.exit(0 if key(sys.argv[1]) > key(sys.argv[2]) else 1)
PY
        return $?
    fi
    _latest_major="$(exakit_major_version "$_latest")"
    _current_major="$(exakit_major_version "$_current")"
    case "$_latest_major$_current_major" in *[!0-9]*) return 1 ;; esac
    if [ "$_latest_major" -gt "$_current_major" ]; then return 0; fi
    if [ "$_latest_major" -lt "$_current_major" ]; then return 1; fi
    # Same major and no Python/uv: treat different tags as worth inspecting,
    # but avoid claiming a downgrade is newer when the major clearly regressed.
    [ "$_latest" != "$_current" ]
}

exakit_major_version() {
    printf '%s\n' "$1" | sed -E 's/^v//; s/^([0-9]+).*/\1/'
}

exakit_resolve_install_versions() {
    [ "${EXAKIT_VERSION_POLICY:-latest}" = "latest" ] || {
        EXAKIT_PERSONAL_VERSION="${EXAKIT_PERSONAL_VERSION:-$EXAKIT_PERSONAL_VERSION_FALLBACK}"
        EXAKIT_NANO_TAG="${EXAKIT_NANO_TAG:-$EXAKIT_NANO_TAG_FALLBACK}"
        EXAKIT_EXAPUMP_VERSION="${EXAKIT_EXAPUMP_VERSION:-$EXAKIT_EXAPUMP_VERSION_FALLBACK}"
        EXAKIT_MCP_VERSION="${EXAKIT_MCP_VERSION:-$EXAKIT_MCP_VERSION_FALLBACK}"
        EXAKIT_PYEXASOL_VERSION="${EXAKIT_PYEXASOL_VERSION:-$EXAKIT_PYEXASOL_VERSION_FALLBACK}"
        export EXAKIT_PERSONAL_VERSION EXAKIT_NANO_TAG EXAKIT_EXAPUMP_VERSION EXAKIT_MCP_VERSION EXAKIT_PYEXASOL_VERSION
        return 0
    }

    _resolved=0
    if [ -z "$EXAKIT_PERSONAL_VERSION" ]; then
        EXAKIT_PERSONAL_VERSION="$(exakit_latest_github_release_version "$EXAKIT_PERSONAL_REPO" || true)"
        [ -n "$EXAKIT_PERSONAL_VERSION" ] || EXAKIT_PERSONAL_VERSION="$EXAKIT_PERSONAL_VERSION_FALLBACK"
        _resolved=1
    fi
    if [ -z "$EXAKIT_NANO_TAG" ]; then
        EXAKIT_NANO_TAG="$(exakit_latest_docker_tag "$EXAKIT_NANO_IMAGE" || true)"
        [ -n "$EXAKIT_NANO_TAG" ] || EXAKIT_NANO_TAG="$EXAKIT_NANO_TAG_FALLBACK"
        _resolved=1
    fi
    if [ -z "$EXAKIT_EXAPUMP_VERSION" ]; then
        EXAKIT_EXAPUMP_VERSION="$(exakit_latest_github_release_version "$EXAKIT_EXAPUMP_REPO" || true)"
        [ -n "$EXAKIT_EXAPUMP_VERSION" ] || EXAKIT_EXAPUMP_VERSION="$EXAKIT_EXAPUMP_VERSION_FALLBACK"
        _resolved=1
    fi
    if [ -z "$EXAKIT_MCP_VERSION" ]; then
        EXAKIT_MCP_VERSION="$(exakit_latest_pypi_version "$EXAKIT_MCP_PACKAGE" || true)"
        [ -n "$EXAKIT_MCP_VERSION" ] || EXAKIT_MCP_VERSION="$EXAKIT_MCP_VERSION_FALLBACK"
        _resolved=1
    fi
    if [ -z "$EXAKIT_PYEXASOL_VERSION" ]; then
        EXAKIT_PYEXASOL_VERSION="$(exakit_latest_pypi_version pyexasol || true)"
        [ -n "$EXAKIT_PYEXASOL_VERSION" ] || EXAKIT_PYEXASOL_VERSION="$EXAKIT_PYEXASOL_VERSION_FALLBACK"
        _resolved=1
    fi
    export EXAKIT_PERSONAL_VERSION EXAKIT_NANO_TAG EXAKIT_EXAPUMP_VERSION EXAKIT_MCP_VERSION EXAKIT_PYEXASOL_VERSION
    if [ "$_resolved" -eq 1 ] && [ -f "$EXAKIT_MANIFEST" ]; then
        exakit_record_desired_versions
    fi
}

exakit_component_latest() {
    case "$1" in
        exakit)   exakit_latest_github_release_version "$EXAKIT_KIT_REPO" ;;
        exapump)  exakit_latest_github_release_version "$EXAKIT_EXAPUMP_REPO" ;;
        mcp)      exakit_latest_pypi_version "$EXAKIT_MCP_PACKAGE" ;;
        nano)     exakit_latest_docker_tag "$EXAKIT_NANO_IMAGE" ;;
        personal) exakit_latest_github_release_version "$EXAKIT_PERSONAL_REPO" ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                nano) exakit_component_latest nano ;;
                personal) exakit_component_latest personal ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

exakit_component_current() {
    case "$1" in
        exakit)
            _src="$(manifest_get kit.source 2>/dev/null || true)"
            case "$_src" in *@*) printf '%s\n' "${_src##*@}" ;; *) printf '%s\n' "unknown" ;; esac
            ;;
        exapump)  manifest_get components.exapump.version 2>/dev/null ;;
        mcp)      manifest_get components.mcp_server.version 2>/dev/null ;;
        nano)
            _image="$(manifest_get runtime.image 2>/dev/null || true)"
            printf '%s\n' "${_image##*:}"
            ;;
        personal) manifest_get runtime.version 2>/dev/null ;;
        runtime)
            exakit_installation_runtime_version
            ;;
        *) return 1 ;;
    esac
}

exakit_update_targets() {
    case "${1:-all}" in
        all) printf '%s\n' exakit runtime exapump mcp ;;
        runtime|database|db) printf '%s\n' runtime ;;
        nano|personal|exakit|exapump|mcp) printf '%s\n' "$1" ;;
        *) return 1 ;;
    esac
}

exakit_print_update_check() {
    _target="${1:-all}"
    _targets="$(exakit_update_targets "$_target")" || die "Unknown update target: $_target"
    printf '\n  Component update check\n'
    printf '  ----------------------\n'
    printf '%-12s %-18s %-18s %s\n' "Component" "Installed" "Latest" "Action"
    _updates=0
    for _component in $_targets; do
        _actual="$(exakit_update_actual_target "$_component" 2>/dev/null || printf '%s\n' "$_component")"
        _current="$(exakit_component_current "$_actual" 2>/dev/null || true)"
        _latest="$(exakit_component_latest "$_actual" 2>/dev/null || true)"
        [ -n "$_current" ] || _current="not installed"
        [ -n "$_latest" ] || _latest="unknown"
        _action="current"
        if [ "$_latest" = "unknown" ] || [ "$_current" = "unknown" ] || [ "$_current" = "not installed" ]; then
            _action="inspect"
        elif exakit_version_newer "$_latest" "$_current"; then
            if [ "$_actual" = "personal" ] && [ "$(exakit_major_version "$_latest")" != "$(exakit_major_version "$_current")" ]; then
                _action="exakit update $_component --plan"
            else
                _action="exakit update $_component"
            fi
            _updates=$((_updates + 1))
        fi
        printf '%-12s %-18s %-18s %s\n' "$_actual" "$_current" "$_latest" "$_action"
    done
    printf '\n'
    if [ "$_updates" -gt 1 ]; then
        info "Update everything with: exakit update all"
    fi
}

exakit_update_self() {
    _latest="$(exakit_component_latest exakit)"
    [ -n "$_latest" ] || die "Could not resolve the latest starter kit release."
    _current="$(exakit_component_current exakit 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "exakit is already current ($_current)"
        return 0
    fi
    _repo="$EXAKIT_KIT_REPO"
    _kit_dir="$EXAKIT_HOME/kit"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-kit.XXXXXX")"
    _stage="$(mktemp -d "${TMPDIR:-/tmp}/exakit-kit-stage.XXXXXX")"
    _backup="${_kit_dir}.backup-$(date +%Y%m%d-%H%M%S)"
    info "Updating starter kit ${_current:-unknown} -> $_latest"
    if ! curl -fL --proto '=https' --retry 3 --connect-timeout 15 -sS \
            -o "$_tmp" "https://github.com/${_repo}/archive/refs/tags/v${_latest}.tar.gz"; then
        curl -fL --proto '=https' --retry 3 --connect-timeout 15 -sS \
            -o "$_tmp" "https://github.com/${_repo}/archive/refs/tags/${_latest}.tar.gz" || \
            die "Could not download the starter kit release $_latest from $_repo."
    fi
    tar -xzf "$_tmp" -C "$_stage" --strip-components 1 || {
        rm -rf "$_stage"
        rm -f "$_tmp"
        die "Could not unpack the starter kit update; existing kit copy was left untouched."
    }
    rm -f "$_tmp"
    for _required in setup/exakit setup/lib/common.sh setup/lib/runtime-nano.sh setup/lib/runtime-personal.sh setup/lib/exapump.sh setup/lib/mcp.sh setup/exakit.ps1 setup/lib/exakit-common.ps1; do
        [ -f "$_stage/$_required" ] || {
            rm -rf "$_stage"
            die "Downloaded starter kit is incomplete (missing $_required); existing kit copy was left untouched."
        }
    done
    if [ -d "$_kit_dir" ]; then
        mv "$_kit_dir" "$_backup" || {
            rm -rf "$_stage"
            die "Could not back up existing kit copy; update was not applied."
        }
        info "Previous kit copy kept at $_backup"
    fi
    mkdir -p "$(dirname "$_kit_dir")"
    if ! mv "$_stage" "$_kit_dir"; then
        [ -d "$_backup" ] && mv "$_backup" "$_kit_dir"
        rm -rf "$_stage"
        die "Could not install the staged starter kit update; previous kit copy was restored."
    fi
    if [ -f "$_kit_dir/setup/exakit" ]; then
        mkdir -p "$EXAKIT_BIN_DIR"
        install -m 755 "$_kit_dir/setup/exakit" "$EXAKIT_BIN_DIR/exakit"
    else
        [ -d "$_backup" ] && { rm -rf "$_kit_dir"; mv "$_backup" "$_kit_dir"; }
        die "Updated kit did not contain setup/exakit after staging; previous kit copy was restored."
    fi
    manifest_set kit.source "${_repo}@${_latest}"
    ok "exakit updated. Database data, credentials, and MCP state were not changed."
}

exakit_update_component() {
    _component="$1"
    shift || true
    case "$_component" in
        exakit) exakit_update_self ;;
        exapump)
            command -v exapump_update >/dev/null 2>&1 || die "exapump module is not available in this version."
            exapump_update
            ;;
        mcp)
            command -v mcp_update >/dev/null 2>&1 || die "MCP module is not available in this version."
            mcp_update
            ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                nano)
                    [ "$#" -eq 0 ] || die "Personal upgrade options are not valid for the Nano runtime."
                    nano_update
                    ;;
                personal) personal_update "$@" ;;
                *) die "No runtime is recorded in the manifest." ;;
            esac
            ;;
        nano)
            [ "$#" -eq 0 ] || die "Personal upgrade options are not valid for Nano."
            nano_update
            ;;
        personal) personal_update "$@" ;;
        *) die "Unknown update target: $_component" ;;
    esac
}

exakit_update() {
    _target="${1:-all}"
    if [ "$#" -gt 0 ]; then shift; fi
    if [ "$#" -gt 0 ]; then
        case "$_target" in
            personal|runtime|database|db) ;;
            *) die "Update options are only supported for Personal runtime updates." ;;
        esac
    fi
    _targets="$(exakit_update_targets "$_target")" || die "Unknown update target: $_target"
    exakit_init_logging
    info "Checking updates before applying changes"
    exakit_print_update_check "$_target"
    for _component in $_targets; do
        exakit_update_component "$_component" "$@"
    done
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
# source of truth for uninstall.
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
    EXAKIT_ACTIVE_LABEL="$2"     # spinner label for run_logged inside this step
    if step_done "$1"; then
        ok "$2 — already done, skipping"
        return 1
    fi
    # Styled step header: accent arrow + bold title, set off by a blank line.
    printf '\n  %s%s%s %s%s%s\n' \
        "${UI_ACCENT:-}" "${UI_ARROW:->}" "${UI_RESET:-}" \
        "${UI_BOLD:-}" "$2" "${UI_RESET:-}"
    _exakit_log_file "STEP  $2"
    return 0
}

exakit_on_failure() {
    _status=$?
    # Runs on EXIT (any status). Stop any live spinner and un-hide the cursor
    # first, so a failure mid-animation never leaves a stuck/invisible cursor.
    ui_spin_end 2>/dev/null || true
    ui_restore_cursor
    exakit_sweep_sensitive_tmp     # never leave credential temp files behind
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

# exakit_install_skills — copy the kit's AI skills into the per-user discovery
# folders so CLI agents auto-load them. Idempotent: each run replaces the
# managed copy of every skill, so edits and deletions propagate cleanly.
#   ~/.claude/skills/<name>/   — Claude Code
#   ~/.agents/skills/<name>/   — Codex, Cursor, other open-standard agents
exakit_install_skills() {
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not locate the kit to find its skills/ directory."
        return 1
    }
    _skills_src="$_repo_root/skills"
    if [ ! -d "$_skills_src" ]; then
        warn "No skills/ directory in this kit build yet — nothing to install."
        return 1
    fi

    _installed=0
    for _skill_dir in "$_skills_src"/*/; do
        [ -f "$_skill_dir/SKILL.md" ] || continue
        _name="$(basename "$_skill_dir")"
        for _dest_root in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
            rm -rf "$_dest_root/$_name"
            mkdir -p "$_dest_root/$_name"
            cp -R "$_skill_dir". "$_dest_root/$_name/"
        done
        ok "Installed skill: $_name"
        _installed=$((_installed + 1))
    done

    if [ "$_installed" -eq 0 ]; then
        warn "No SKILL.md files found under $_skills_src — nothing to install."
        return 1
    fi
    info "Skills installed for Claude Code (~/.claude/skills) and open-standard agents (~/.agents/skills)."
    info "Restart or reload your AI client to pick them up."
    return 0
}

# exakit_maybe_offer_skills_install — after setup, place the skills where CLI
# agents can find them. Always installs — no prompt — so the skills are
# present without requiring interactive confirmation. Non-fatal and
# idempotent.
exakit_maybe_offer_skills_install() {
    _repo_root="$(exakit_repo_root)" || return 0
    ls "$_repo_root"/skills/*/SKILL.md >/dev/null 2>&1 || return 0
    exakit_install_skills || \
        warn "Skills install did not finish cleanly. Retry any time with: exakit skills-install"
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
            die "Security check failed: the MCP read-only user was able to write to schema $_schema_uc, but it must be read-only. Setup stopped to protect your database."
        fi
    done
}

# _exakit_reassert_mcp_readonly_posture — re-run the grant-posture check
# against the database using the credentials already on file, without
# re-provisioning anything. Used by `exakit mcp-doctor` so
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
    exakit_track_sensitive_tmp "$_temp_config"   # holds plaintext DB passwords; swept on any exit
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

# _exakit_read_exapump_profile_password <profile> — print the password stored
# in the given exapump profile (EXAPUMP_CONFIG / ~/.exapump/config.toml), or
# nothing (non-zero) if it can't be read. Symmetric with how the profile is
# written in exapump.sh (an unescaped `password = "..."` line).
_exakit_read_exapump_profile_password() {
    _cfg="${EXAPUMP_CONFIG:-$HOME/.exapump/config.toml}"
    [ -f "$_cfg" ] || return 1
    require_python3
    run_python - "$_cfg" "$1" <<'PY'
import re, sys
path, profile = sys.argv[1], sys.argv[2]
try:
    content = open(path).read()
except OSError:
    sys.exit(1)
m = re.search(r"\[" + re.escape(profile) + r"\](.*?)(?:\n\[|\Z)", content, re.S)
if not m:
    sys.exit(1)
pw = re.search(r'(?m)^\s*password\s*=\s*"(.*)"\s*$', m.group(1))
if not pw:
    sys.exit(1)
sys.stdout.write(pw.group(1))
PY
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
    [ -n "$_runtime_user" ] || die "runtime.user is missing; cannot prepare the MCP read-only database user."
    _runtime_password_file="$(_exakit_manifest_runtime_value runtime.password_file)"
    _admin_password=""
    if [ -n "$_runtime_password_file" ] && [ -f "$_runtime_password_file" ]; then
        _admin_password="$(cat "$_runtime_password_file")"
    fi
    # Fallback: recover the admin password from the exapump profile that the
    # data step already wrote and validated. Covers installs where the runtime
    # step could not record runtime.password_file (an adopted deployment with
    # unreadable secrets) — including re-runs, where the exapump step is skipped
    # as "already done" and so cannot record it either. Persist it forward so
    # later runs and mcp-doctor find it directly.
    if [ -z "$_admin_password" ]; then
        _admin_password="$(_exakit_read_exapump_profile_password "$EXAKIT_EXAPUMP_PROFILE" 2>/dev/null || true)"
        if [ -n "$_admin_password" ]; then
            store_credential runtime_sys_password "$_admin_password"
            manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/runtime_sys_password"
        fi
    fi
    [ -n "$_admin_password" ] || die "No runtime database password is available (runtime.password_file is missing and the exapump '$EXAKIT_EXAPUMP_PROFILE' profile has none). Set it with 'exapump profile init $EXAKIT_EXAPUMP_PROFILE', then re-run."
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
    exakit_track_sensitive_tmp "$_temp_config"   # holds plaintext DB passwords; swept on any exit
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
    _clients_csv="$1"
    _output_file="$2"
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
    "claude_desktop": "Claude",
    "cursor": "Cursor",
    "codex": "Codex",
}

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)

clients = ", ".join(LABELS.get(item, item) for item in doc.get("selected_clients", []))
print("")
print("  MCP setup summary")
print("  Mode:     managed")
print("  Meaning:  Wrote managed MCP entries into the selected client config files.")
print(f"  Clients:  {clients or 'none'}")
print(f"  Status:   {doc.get('status', 'unknown')}")
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
    printf '  Managed state: %s\n' "$EXAKIT_MCP_DIR"
    printf '\n'
    printf '  MCP setup updated the selected client config files.\n'
    printf '  Next step: restart the selected client now.\n'
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
    "claude_desktop": "Claude",
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
    info "MCP setup will edit the selected AI client config files."

    printf '\n'
    info "Choose one or more clients"
    printf '    1. Claude\n'
    printf '    2. Cursor\n'
    printf '    3. Codex\n'
    printf '    Enter numbers separated by commas, or type all.\n'
    while :; do
        _selection="$(prompt_text "Choose client numbers" "all")"
        _clients_csv="$(exakit_parse_mcp_client_selection "$_selection")" && break
        warn "Please choose valid client numbers, for example 1,2,3 or all."
    done

    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-setup.XXXXXX")"
    info "Applying MCP setup"
    _setup_status=0
    if exakit_run_mcp_setup_cli "$_clients_csv" "$_result_file"; then
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
    exakit_print_mcp_ready_panel "permanent"
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
    if ( exakit_data_load_menu install ); then
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
        info "Step ${_step_no}/${_total}  exapump — not part of this installation, skipping"
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
            mcp_validate
            mark_step mcp
        fi
    else
        info "Step ${_step_no}/${_total}  MCP server — not part of this installation, skipping"
    fi
    _step_no=$((_step_no + 1))

    if command -v pyexasol_install >/dev/null 2>&1; then
        if begin_step pyexasol "Step ${_step_no}/${_total}  pyexasol (Exasol Python driver)"; then
            pyexasol_install
            pyexasol_validate
            mark_step pyexasol
        fi
    else
        info "Step ${_step_no}/${_total}  pyexasol — not part of this installation, skipping"
    fi
    _step_no=$((_step_no + 1))

    # The step flag alone is not trusted: if the exakit command was removed
    # (cleanup, testing), a re-run must reinstall it rather than skip.
    _helper_needed=0
    if begin_step exakit_helper "Step ${_step_no}/${_total}  exakit helper command"; then
        _helper_needed=1
    elif [ ! -x "$EXAKIT_BIN_DIR/exakit" ]; then
        info "exakit command is missing — reinstalling it"
        _helper_needed=1
    else
        ensure_path_hint "$EXAKIT_BIN_DIR"
    fi
    if [ "$_helper_needed" -eq 1 ]; then
        mkdir -p "$EXAKIT_BIN_DIR" || die "Could not create $EXAKIT_BIN_DIR for the exakit command."
        # Fail loudly here: without a check, a failed install (e.g. non-writable
        # ~/.local/bin, full disk) would fall through to mark_step + "exakit
        # installed", reporting success while no binary exists.
        install -m 755 "$_script_dir/exakit" "$EXAKIT_BIN_DIR/exakit" \
            || die "Could not install the exakit command to $EXAKIT_BIN_DIR (is it writable? is the disk full?)."
        # Keep a copy of the kit library (and the mcp/ and sql/ packages
        # exakit_repo_root() depends on) next to the state so exakit finds
        # them even when this checkout moves or disappears. Skip when setup is
        # ALREADY running from the kit home (the curl|sh flow, where install.sh
        # placed the kit there): copying a directory onto itself makes cp error
        # out with "are identical", which is not a real failure.
        if [ "$_script_dir" -ef "$EXAKIT_HOME/kit/setup" ] 2>/dev/null; then
            :   # already in place; nothing to copy
        else
            mkdir -p "$EXAKIT_HOME/kit/setup" || die "Could not create $EXAKIT_HOME/kit/setup."
            cp -R "$_script_dir/lib" "$EXAKIT_HOME/kit/setup/" \
                || die "Could not copy the kit library to $EXAKIT_HOME/kit/setup."
            # Copy the assets exakit needs after the checkout is gone: the mcp/
            # and sql/ packages, the data/ CSVs, and load-data.sh.
            [ -d "$_kit_root/mcp" ] && cp -R "$_kit_root/mcp" "$EXAKIT_HOME/kit/"
            [ -d "$_kit_root/sql" ] && cp -R "$_kit_root/sql" "$EXAKIT_HOME/kit/"
            [ -d "$_kit_root/data" ] && cp -R "$_kit_root/data" "$EXAKIT_HOME/kit/"
            [ -f "$_script_dir/load-data.sh" ] && cp "$_script_dir/load-data.sh" "$EXAKIT_HOME/kit/setup/"
        fi
        ensure_path_hint "$EXAKIT_BIN_DIR"
        mark_step exakit_helper
        ok "exakit installed ($EXAKIT_BIN_DIR/exakit)"
    fi

    exakit_maybe_offer_mcp_setup || true
    exakit_maybe_offer_skills_install || true
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
    ui_panel_begin "Connection details"
    ui_panel_line "Runtime:      ${_type:-unknown}"
    ui_panel_line "DSN:          ${_dsn:-unknown}"
    ui_panel_line "Admin user:   ${_user:-sys}"
    [ -n "$_pwfile" ]    && ui_panel_line "Admin pass:   stored in $(ui_tilde "$_pwfile")"
    [ -n "$_mcp_user" ]  && ui_panel_line "MCP user:     $_mcp_user"
    [ -n "$_mcp_pwfile" ] && ui_panel_line "MCP pass:     stored in $(ui_tilde "$_mcp_pwfile")"
    ui_panel_line "TLS:          enabled (self-signed certificate)"
    [ "$_type" = "personal" ] && ui_panel_line "Details:      run 'exasol info' for deployment state"

    _exapump="$(manifest_get components.exapump.path 2>/dev/null)"
    if [ -n "$_exapump" ]; then
        ui_panel_line "exapump:      $(ui_tilde "$_exapump") (profile: $(manifest_get components.exapump.profile 2>/dev/null))"
    fi

    _mcp="$(manifest_get components.mcp_server.configs 2>/dev/null)"
    [ -n "$_mcp" ] && ui_panel_line "MCP configs:  $(ui_tilde "$EXAKIT_MCP_DIR")"

    ui_panel_line "Manifest:     $(ui_tilde "$EXAKIT_MANIFEST")"
    ui_panel_line "Logs:         $(ui_tilde "$EXAKIT_LOG_DIR")"
    ui_panel_end
    printf '\n'
}

# generate_password — local random password (not logged anywhere).
generate_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# store_credential <name> <value> — 0600 file under credentials dir.
# Written atomically so an interrupted run can never leave a truncated secret.
store_credential() {
    mkdir -p "$EXAKIT_CREDS_DIR" || die "Could not create the credentials directory $EXAKIT_CREDS_DIR."
    chmod 700 "$EXAKIT_CREDS_DIR"
    # Fail loudly on a write error (full disk / read-only home): a silently
    # dropped secret makes a later step read an empty credential and either
    # regenerate a mismatching password or die with a confusing message far
    # from the real cause.
    if ! printf '%s' "$2" > "$EXAKIT_CREDS_DIR/$1.tmp"; then
        rm -f "$EXAKIT_CREDS_DIR/$1.tmp" 2>/dev/null
        die "Could not save credential '$1' to $EXAKIT_CREDS_DIR (disk full or not writable?)."
    fi
    chmod 600 "$EXAKIT_CREDS_DIR/$1.tmp"
    mv "$EXAKIT_CREDS_DIR/$1.tmp" "$EXAKIT_CREDS_DIR/$1" || die "Could not save credential '$1'."
}

read_credential() {
    _rc_file="$EXAKIT_CREDS_DIR/$1"
    # A file that exists but can't be read would otherwise look "missing" and
    # trigger a regenerated, diverging password — surface it instead.
    if [ -f "$_rc_file" ] && [ ! -r "$_rc_file" ]; then
        warn "Credential file exists but is not readable: $_rc_file (check permissions)."
    fi
    cat "$_rc_file" 2>/dev/null
}

# --- full uninstall --------------------------------------------------------
#
# exakit_uninstall_run <dry_run> — remove every artifact this kit installs, in
# dependency order: the local database and ALL its data, the managed MCP client
# configs, the installed AI skills, the exapump profile, the kit home, and the
# CLI binaries. With <dry_run>="1" it prints the plan and changes nothing, so
# the caller can show exactly what will go before asking for confirmation.
#
# Deliberately NOT removed (reported instead): uv/uvx (a shared third-party
# Python runner the user may rely on elsewhere) and the PATH line added to the
# shell profile (unmarked and shared with other tools — unsafe to edit blindly).
exakit_uninstall_run() {
    _dry="${1:-0}"
    _step() { # _step <message>  — narrate the action (or the plan line)
        if [ "$_dry" = "1" ]; then info "  will remove: $1"; else info "$1"; fi
    }
    _rm() { # _rm <path> — remove a path unless dry-run
        [ "$_dry" = "1" ] || rm -rf "$1"
    }

    # 1) Database + all data. Uses the runtime removal helper (always --data),
    #    which for Personal also reaps any orphaned runner daemon on the DB port.
    _type="$(manifest_get runtime.type 2>/dev/null || true)"
    if [ -n "$_type" ]; then
        _step "local Exasol $_type deployment and ALL its data"
        if [ "$_dry" != "1" ]; then
            case "$_type" in
                nano)     nano_teardown --data     || warn "Database removal reported errors (continuing uninstall)" ;;
                personal) personal_teardown --data || warn "Database removal reported errors (continuing uninstall)" ;;
                *)        warn "Unknown runtime type '$_type'; skipping database removal" ;;
            esac
        fi
    fi

    # 2) Managed MCP configuration in the AI clients (Claude, Cursor,
    #    Codex). Best-effort: a failure here must not block the rest.
    if command -v exakit_mcp_operation >/dev/null 2>&1; then
        _step "managed MCP configuration in Claude, Cursor, and Codex"
        if [ "$_dry" != "1" ]; then
            exakit_mcp_operation uninstall >/dev/null 2>&1 || \
                warn "Removing the managed MCP client config reported issues (continuing uninstall)"
        fi
    fi

    # 3) Installed AI skills. Prefer the live list from the kit's skills/ dir;
    #    fall back to the known names when the checkout is already gone.
    _skill_names=""
    _repo_root="$(exakit_repo_root 2>/dev/null || true)"
    if [ -n "$_repo_root" ] && [ -d "$_repo_root/skills" ]; then
        for _sd in "$_repo_root"/skills/*/; do
            [ -f "$_sd/SKILL.md" ] || continue
            _skill_names="$_skill_names $(basename "$_sd")"
        done
    fi
    [ -n "$_skill_names" ] || _skill_names="local-agent-ready-starter trusted-ai-workflow"
    for _root in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
        for _name in $_skill_names; do
            if [ -e "$_root/$_name" ]; then
                _step "AI skill $_root/$_name"
                _rm "$_root/$_name"
            fi
        done
    done

    # 4) exapump profile store (the kit created it; the binary goes in step 6).
    if [ -e "$HOME/.exapump" ]; then
        _step "exapump profiles at $HOME/.exapump"
        _rm "$HOME/.exapump"
    fi

    # 5) Kit home: credentials, logs, manifest, cached kit copy, MCP snapshots,
    #    and the pyexasol virtual environment (it lives under the kit home).
    if [ -e "$EXAKIT_HOME" ]; then
        _step "kit home $EXAKIT_HOME (credentials, logs, manifest, snapshots, pyexasol venv)"
        _rm "$EXAKIT_HOME"
    fi

    # 6) CLI binaries. Removed last so earlier steps can still call the launcher.
    #    Removing the running exakit binary itself is safe (the inode survives
    #    until the process exits).
    for _bin in exasol exakit exapump; do
        if [ -e "$EXAKIT_BIN_DIR/$_bin" ]; then
            _step "CLI binary $EXAKIT_BIN_DIR/$_bin"
            _rm "$EXAKIT_BIN_DIR/$_bin"
        fi
    done
}
