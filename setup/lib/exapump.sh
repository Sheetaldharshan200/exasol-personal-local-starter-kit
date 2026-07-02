#!/usr/bin/env bash
# exapump.sh — exapump installation and connection module.
#
# Sourced by setup scripts after common.sh, detect.sh, and a runtime module.
# Installs the pinned exapump release binary (checksum-verified against the
# digests published by the release API), writes a dedicated connection
# profile, and validates the connection with SELECT 1.
#
# exapump facts:
#   - release assets: exapump-<ver>-{macos,linux}-{aarch64,x86_64}[, .exe]
#   - profiles: ~/.exapump/config.toml (TOML, one section per profile)
#   - SQL from a file: exapump sql -p <profile> < file.sql
#   - CSV/Parquet load: exapump upload <file> --table <schema.table>

EXAKIT_EXAPUMP_PROFILE="${EXAKIT_EXAPUMP_PROFILE:-starter-kit}"
EXAKIT_EXAPUMP_BIN="$EXAKIT_BIN_DIR/exapump"
EXAPUMP_CONFIG="$HOME/.exapump/config.toml"

exapump_asset_name() {
    _ver="$EXAKIT_EXAPUMP_VERSION"
    case "$(detect_os)" in
        macos) _osname="macos" ;;
        *)     _osname="linux" ;;
    esac
    case "$(detect_arch)" in
        arm64)  _archname="aarch64" ;;
        x86_64) _archname="x86_64" ;;
    esac
    echo "exapump-${_ver}-${_osname}-${_archname}"
}

# Digests of the pinned release (published by the release API). When the
# version is overridden the digest is fetched from the API instead.
exapump_pinned_sha256() {
    case "$1" in
        exapump-0.11.2-linux-aarch64)  echo "106c3c5ea168a1381549807b82639137c8b3f94bd64c1b6d02fa380a025d5085" ;;
        exapump-0.11.2-linux-x86_64)   echo "669af4d488e5b1ae2e9c9e030c1be4b1cdb7442dedf3175a361928613f4b3e80" ;;
        exapump-0.11.2-macos-aarch64)  echo "e1438c69f26cdcca69ad1b7211aa9495524c53ff1badebee91d5a631c503616b" ;;
        exapump-0.11.2-macos-x86_64)   echo "1dd68d2dbc2d556e1613975eeffb25813f1ec60e06e93d514d5dd86df8144648" ;;
        *) echo "" ;;
    esac
}

exapump_release_digest_from_api() {
    require_python3
    curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/${EXAKIT_EXAPUMP_REPO}/releases/tags/v${EXAKIT_EXAPUMP_VERSION}" \
        2>/dev/null | run_python -c '
import json, sys
name = sys.argv[1]
doc = json.load(sys.stdin)
for asset in doc.get("assets", []):
    if asset["name"] == name and asset.get("digest", "").startswith("sha256:"):
        print(asset["digest"].split(":", 1)[1])
        break
' "$1"
}

exapump_cli() {
    if command -v exapump >/dev/null 2>&1; then
        command -v exapump
    else
        echo "$EXAKIT_EXAPUMP_BIN"
    fi
}

exapump_install() {
    [ "$(detect_arch)" != "unsupported" ] || \
        die "Unsupported CPU architecture: $(uname -m). exapump binaries exist for x86_64 and arm64 only."

    if command -v exapump >/dev/null 2>&1 || [ -x "$EXAKIT_EXAPUMP_BIN" ]; then
        # Trust the existing binary only if it actually runs — an interrupted
        # earlier download can leave a broken file at the same path.
        if "$(exapump_cli)" --version >/dev/null 2>&1; then
            ok "exapump already installed: $(exapump_cli)"
            exapump_record_manifest
            return 0
        fi
        warn "Existing exapump binary does not run (interrupted download?) — reinstalling"
        rm -f "$EXAKIT_EXAPUMP_BIN"
    fi

    _asset="$(exapump_asset_name)"
    _url="https://github.com/${EXAKIT_EXAPUMP_REPO}/releases/download/v${EXAKIT_EXAPUMP_VERSION}/${_asset}"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-exapump.XXXXXX")"

    info "Downloading exapump v${EXAKIT_EXAPUMP_VERSION} ($_asset)"
    fetch "$_url" "$_tmp"

    _expected="$(exapump_pinned_sha256 "$_asset")"
    if [ -z "$_expected" ]; then
        _expected="$(exapump_release_digest_from_api "$_asset")"
    fi
    if [ -n "$_expected" ]; then
        verify_sha256 "$_tmp" "$_expected"
    else
        warn "No digest available for $_asset — continuing without checksum verification"
    fi

    mkdir -p "$EXAKIT_BIN_DIR"
    install -m 755 "$_tmp" "$EXAKIT_EXAPUMP_BIN"
    push_rollback "rm -f $EXAKIT_EXAPUMP_BIN"
    rm -f "$_tmp"
    ensure_path_hint "$EXAKIT_BIN_DIR"
    ok "exapump installed: $EXAKIT_EXAPUMP_BIN"
    exapump_record_manifest
}

# exapump_create_profile — write the kit's connection profile from the
# manifest. Managed section, safe to re-run; other profiles are untouched.
exapump_create_profile() {
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    [ -n "$_dsn" ] || die "No runtime DSN in the manifest — install the database first."
    _host="${_dsn%%:*}"
    _port="${_dsn##*:}"
    _user="$(manifest_get runtime.user 2>/dev/null)"
    _user="${_user:-sys}"

    _pwfile="$(manifest_get runtime.password_file 2>/dev/null)"
    _password=""
    if [ -n "$_pwfile" ] && [ -f "$_pwfile" ]; then
        _password="$(cat "$_pwfile")"
    fi
    if [ -z "$_password" ] && (: < /dev/tty) 2>/dev/null; then
        printf '\033[1;36m  ?\033[0m Database password for user %s (input hidden): ' "$_user"
        stty -echo < /dev/tty 2>/dev/null
        read -r _password < /dev/tty
        stty echo < /dev/tty 2>/dev/null
        printf '\n'
    fi
    if [ -z "$_password" ]; then
        warn "No database password available — create the profile manually with: exapump profile init $EXAKIT_EXAPUMP_PROFILE"
        return 0
    fi

    require_python3
    mkdir -p "$(dirname "$EXAPUMP_CONFIG")"
    run_python - "$EXAPUMP_CONFIG" "$EXAKIT_EXAPUMP_PROFILE" "$_host" "$_port" "$_user" "$_password" <<'PY' || die "Could not write the exapump profile"
import os, re, sys
path, profile, host, port, user, password = sys.argv[1:7]
try:
    with open(path) as f:
        content = f.read()
except FileNotFoundError:
    content = ""

section = (
    f"[{profile}]\n"
    f'host = "{host}"\n'
    f"port = {port}\n"
    f'user = "{user}"\n'
    f'password = "{password}"\n'
    f"tls = true\n"
    f"validate_certificate = false\n"
)
pattern = re.compile(rf"\[{re.escape(profile)}\][^\[]*", re.S)
if pattern.search(content):
    content = pattern.sub(section + "\n", content).rstrip("\n") + "\n"
else:
    if content and not content.endswith("\n\n"):
        content = content.rstrip("\n") + "\n\n"
    content += section
# Atomic replace: an interrupted run must never truncate a config that may
# hold the user's other profiles.
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(content)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
    chmod 600 "$EXAPUMP_CONFIG"
    manifest_set components.exapump.profile "$EXAKIT_EXAPUMP_PROFILE"
    ok "Connection profile written: [$EXAKIT_EXAPUMP_PROFILE] in $EXAPUMP_CONFIG"
}

# exapump_validate_connection — SELECT 1 through the new profile.
exapump_validate_connection() {
    if [ -z "$(manifest_get components.exapump.profile 2>/dev/null)" ]; then
        die "No connection profile exists (no database password was available to write one). Create it manually with 'exapump profile init $EXAKIT_EXAPUMP_PROFILE', then re-run this script."
    fi
    info "Validating the database connection (SELECT 1)"
    _tries=0
    while [ "$_tries" -lt 6 ]; do
        if run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" 'SELECT 1'; then
            ok "Connection works"
            manifest_set components.exapump.validated true
            return 0
        fi
        _tries=$((_tries + 1))
        sleep 5
    done
    die "SELECT 1 failed through profile '$EXAKIT_EXAPUMP_PROFILE'. Try: exapump sql -p $EXAKIT_EXAPUMP_PROFILE 'SELECT 1'"
}

# exapump_run_sql_file <file> [description] — execute a SQL file, logged.
exapump_run_sql_file() {
    [ -s "$1" ] || { warn "SQL file missing or empty: $1"; return 1; }
    info "Running ${2:-$(basename "$1")}"
    run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" < "$1" || \
        die "SQL file failed: $1 (see log)"
    ok "${2:-$(basename "$1")} done"
}

# exapump_upload <file> <schema.table> — load a CSV/Parquet file, logged.
exapump_upload() {
    [ -s "$1" ] || { warn "Data file missing or empty: $1"; return 1; }
    info "Loading $(basename "$1") into $2"
    run_logged "$(exapump_cli)" upload "$1" --table "$2" -p "$EXAKIT_EXAPUMP_PROFILE" || \
        die "Upload failed: $1 -> $2 (see log)"
    ok "$(basename "$1") loaded"
}

# exapump_count <schema.table> — row count (prints the number).
exapump_count() {
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "SELECT COUNT(*) FROM $1" 2>/dev/null | \
        tail -1 | tr -dc '0-9'
}

exapump_record_manifest() {
    manifest_set components.exapump.version "$EXAKIT_EXAPUMP_VERSION"
    manifest_set components.exapump.path "$(exapump_cli)"
}
