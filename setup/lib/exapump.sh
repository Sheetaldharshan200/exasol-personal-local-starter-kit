#!/usr/bin/env bash
# exapump.sh — exapump installation and connection module.
#
# Sourced by setup scripts after common.sh, detect.sh, and a runtime module.
# Installs the resolved exapump release binary (checksum-verified against the
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

# Digests of the bundled fallback release (published by the release API). When the
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
    _json="$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/${EXAKIT_EXAPUMP_REPO}/releases/tags/v${EXAKIT_EXAPUMP_VERSION}" \
        2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c '
import json, sys
name = sys.argv[1]
doc = json.load(sys.stdin)
for asset in doc.get("assets", []):
    if asset["name"] == name and asset.get("digest", "").startswith("sha256:"):
        print(asset["digest"].split(":", 1)[1])
        break
' "$1"
        return $?
    fi
    # Best-effort shell fallback for GitHub's asset object. If this misses, the
    # caller already warns and continues rather than pretending verification ran.
    printf '%s' "$_json" | tr '{' '\n' | awk -v name="$1" '
        index($0, "\"name\":\"" name "\"") || index($0, "\"name\": \"" name "\"") {
            if (match($0, /"digest"[[:space:]]*:[[:space:]]*"sha256:[^"]+"/)) {
                digest = substr($0, RSTART, RLENGTH)
                sub(/^.*sha256:/, "", digest)
                sub(/"$/, "", digest)
                print digest
                exit
            }
        }'
}

exapump_cli() {
    if [ -x "$EXAKIT_EXAPUMP_BIN" ]; then
        echo "$EXAKIT_EXAPUMP_BIN"
    elif command -v exapump >/dev/null 2>&1; then
        command -v exapump
    else
        echo "$EXAKIT_EXAPUMP_BIN"
    fi
}

exapump_install() {
    [ "$(detect_arch)" != "unsupported" ] || \
        die "Unsupported CPU architecture: $(uname -m). exapump binaries exist for x86_64 and arm64 only."

    if [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && { command -v exapump >/dev/null 2>&1 || [ -x "$EXAKIT_EXAPUMP_BIN" ]; }; then
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

    # If the runtime password wasn't already on file (e.g. we adopted a running
    # deployment whose secrets we couldn't read, so the password came from the
    # prompt above), remember it so exapump_validate_connection can persist it
    # AFTER confirming it works. The MCP step reads runtime.password_file to
    # provision the read-only user, so it must be recorded — but only once the
    # password is validated, otherwise a mistyped password would be saved and
    # the next run would reuse it instead of re-prompting.
    if [ -z "$_pwfile" ] || [ ! -f "$_pwfile" ]; then
        _EXAKIT_PENDING_RUNTIME_PASSWORD="$_password"
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
            # Now that the password is proven to work, persist it as the runtime
            # password if the runtime step could not (adopted deployment with
            # unreadable secrets) — the MCP step needs runtime.password_file.
            if [ -n "${_EXAKIT_PENDING_RUNTIME_PASSWORD:-}" ]; then
                store_credential runtime_sys_password "$_EXAKIT_PENDING_RUNTIME_PASSWORD"
                manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/runtime_sys_password"
                unset _EXAKIT_PENDING_RUNTIME_PASSWORD
            fi
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

# exapump_count <schema.table> — row count (prints the number, empty on failure).
# Wrap the count in a unique delimited token (EXAKIT_RC[<n>]) and recover it with
# a regex instead of scraping the last line for digits. The old "tail -1 |
# tr -dc 0-9" collapsed exapump's "[1/1] ... 1 rows" status line to "111" for
# every table in non-TTY installs (where exapump prints no separate value line).
# The echoed query literal never forms "EXAKIT_RC[<digits>]", so only the real
# result matches.
exapump_count() {
    _sql="SELECT 'EXAKIT_RC[' || CAST(COUNT(*) AS VARCHAR(40)) || ']' AS EXAKIT_RC FROM $1"
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "$_sql" 2>/dev/null | \
        grep -oE 'EXAKIT_RC\[[0-9]+\]' | head -1 | tr -dc '0-9'
}

exapump_record_manifest() {
    manifest_set components.exapump.version "$EXAKIT_EXAPUMP_VERSION"
    manifest_set components.exapump.path "$(exapump_cli)"
}

exapump_update() {
    _latest="$(exakit_component_latest exapump)"
    [ -n "$_latest" ] || die "Could not resolve the latest exapump release."
    _current="$(manifest_get components.exapump.version 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "exapump is already current ($_current)"
        return 0
    fi
    info "Updating exapump ${_current:-unknown} -> $_latest"
    EXAKIT_EXAPUMP_VERSION="$_latest"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_EXAPUMP_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    exapump_install
    exapump_create_profile
    manifest_set desired.exapump "$EXAKIT_EXAPUMP_VERSION"
    ok "exapump updated without changing database data"
}

exakit_table_name_from_path() {
    _base="$(basename "$1")"
    _base="${_base%%\?*}"
    _base="${_base%.*}"
    _table="$(printf '%s' "$_base" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')"
    _table="$(printf '%s' "$_table" | sed 's/^_*//; s/_*$//; s/__*/_/g')"
    printf '%s\n' "${_table:-MY_TABLE}"
}

exakit_normalize_path() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

exakit_validate_table_target() {
    case "$1" in
        *.*) ;;
        *) return 1 ;;
    esac
    _schema="${1%%.*}"
    _table="${1#*.}"
    case "$_schema" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
    case "$_table" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
    return 0
}

exakit_target_schema() {
    printf '%s\n' "${1%%.*}" | tr '[:lower:]' '[:upper:]'
}

exakit_upper_table_target() {
    _schema="${1%%.*}"
    _table="${1#*.}"
    printf '%s.%s\n' \
        "$(printf '%s' "$_schema" | tr '[:lower:]' '[:upper:]')" \
        "$(printf '%s' "$_table" | tr '[:lower:]' '[:upper:]')"
}

exakit_ensure_schema() {
    _schema="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    [ -n "$_schema" ] || return 1
    if "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$_schema') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS" \
        2>> "${EXAKIT_LOG_FILE:-/dev/null}" | grep -q "EXAKIT_SCHEMA_PRESENT"; then
        return 0
    fi
    info "Creating schema $_schema"
    run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "CREATE SCHEMA $_schema" || \
        die "Could not create schema $_schema"
}

exakit_verify_loaded_table() {
    _target="$1"
    _rows="$(exapump_count "$_target")"
    [ -n "$_rows" ] || die "Could not verify row count for $_target."
    if [ "$_rows" = "0" ]; then
        warn "Verified $_target, but it currently has 0 rows."
    else
        ok "Verified $_target ($_rows rows)"
    fi
    manifest_set data.last_load.verified_table "$_target"
    manifest_set data.last_load.verified_rows "$_rows"
}

exakit_prompt_optional_verification() {
    _default="${1:-}"
    _target="$(prompt_text "Verify table after script/import (SCHEMA.TABLE, blank to skip)" "$_default")"
    [ -n "$_target" ] || {
        info "Skipping table verification for this script/import."
        return 0
    }
    exakit_validate_table_target "$_target" || die "Verification table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    exakit_verify_loaded_table "$(exakit_upper_table_target "$_target")"
}

exakit_load_local_file() {
    _raw_path="$(prompt_text "Local CSV/text file path")"
    _path="$(exakit_normalize_path "$_raw_path")"
    [ -s "$_path" ] || die "File not found or empty: $_path"
    _default_table="${EXAKIT_SCHEMA:-STARTER_KIT}.$(exakit_table_name_from_path "$_path")"
    _target="$(prompt_text "Target table (SCHEMA.TABLE)" "$_default_table")"
    exakit_validate_table_target "$_target" || die "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    _target="$(exakit_upper_table_target "$_target")"
    exakit_ensure_schema "$(exakit_target_schema "$_target")"
    exapump_upload "$_path" "$_target"
    manifest_set data.last_load.type "local_file"
    manifest_set data.last_load.target "$_target"
    manifest_set data.last_load.source "$_path"
    exakit_verify_loaded_table "$_target"
    ok "Loaded $_path into $_target"
}

exakit_load_remote_file() {
    _url="$(prompt_text "Remote CSV/text URL")"
    [ -n "$_url" ] || die "Remote URL is required."
    _name="$(basename "${_url%%\?*}")"
    [ -n "$_name" ] || _name="remote-data.csv"
    _tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/exakit-remote-data.XXXXXX")" || die "Could not create a temporary download directory."
    _tmp_file="$_tmp_dir/$_name"
    info "Downloading remote data file"
    fetch "$_url" "$_tmp_file"
    _default_table="${EXAKIT_SCHEMA:-STARTER_KIT}.$(exakit_table_name_from_path "$_name")"
    _target="$(prompt_text "Target table (SCHEMA.TABLE)" "$_default_table")"
    exakit_validate_table_target "$_target" || die "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    _target="$(exakit_upper_table_target "$_target")"
    exakit_ensure_schema "$(exakit_target_schema "$_target")"
    exapump_upload "$_tmp_file" "$_target"
    rm -rf "$_tmp_dir"
    manifest_set data.last_load.type "remote_file"
    manifest_set data.last_load.target "$_target"
    manifest_set data.last_load.source "$_url"
    exakit_verify_loaded_table "$_target"
    ok "Loaded $_url into $_target"
}

exakit_run_sql_script() {
    _raw_path="$(prompt_text "SQL script path")"
    _path="$(exakit_normalize_path "$_raw_path")"
    [ -s "$_path" ] || die "SQL script not found or empty: $_path"
    exapump_run_sql_file "$_path" "SQL script ($(basename "$_path"))"
    manifest_set data.last_load.type "sql_script"
    manifest_set data.last_load.source "$_path"
    exakit_prompt_optional_verification ""
    ok "SQL script completed"
}

exakit_show_database_import_guidance() {
    _kind="$1"
    printf '\n'
    printf '  %s\n' "$_kind"
    printf '  Use this option when your source is another database and you already\n'
    printf '  have an Exasol IMPORT statement or a script that creates the needed\n'
    printf '  connection object. The kit will run that SQL through the starter-kit\n'
    printf '  exapump profile and log the result.\n'
    printf '\n'
    printf '  Typical flow:\n'
    printf '  1. Put your IMPORT statements in a .sql file.\n'
    printf '  2. Run this option and provide that file path.\n'
    printf '  3. Verify the target table with exapump sql -p starter-kit.\n'
    printf '\n'
    printf '  Self-signed certificate: if the source is an Exasol with a\n'
    printf '  self-signed cert (the kit deploys one), the CONNECTION must pin\n'
    printf '  its TLS fingerprint in the host string:\n'
    printf "        TO 'HOST/FINGERPRINT:PORT'\n"
    printf '  To get the fingerprint, run the IMPORT once without it: the\n'
    printf '  "ETL-4211 ... self-signed certificate" error prints the exact\n'
    printf '  HOST/FINGERPRINT:PORT to paste back. Never disable cert validation.\n'
    printf '\n'
    printf '  Security: once CREATE CONNECTION runs, Exasol stores the password\n'
    printf '  encrypted inside the database - do not leave a plaintext password\n'
    printf '  in the .sql file; delete or scrub it after the connection exists.\n'
    printf '\n'
    if confirm "Run an import SQL script now?" y; then
        exakit_run_sql_script
    else
        info "Skipping import execution. Run it any time with: exakit data-load"
    fi
}

exakit_show_exapump_guidance() {
    printf '\n'
    printf '  Exapump is installed and connected.\n'
    printf '  Profile: starter-kit\n'
    printf '  Binary:  %s\n' "$(exapump_cli)"
    printf '\n'
    printf '  Useful commands:\n'
    printf '    exapump sql -p starter-kit '\''SELECT CURRENT_TIMESTAMP'\''\n'
    printf '    exapump upload ./data.csv --table STARTER_KIT.MY_TABLE -p starter-kit\n'
    printf '    exapump sql -p starter-kit < ./script.sql\n'
    printf '\n'
}

exakit_data_load_menu() {
    [ -n "$(manifest_get components.exapump.profile 2>/dev/null)" ] || \
        die "No exapump connection profile is recorded — re-run the installer, then retry."

    info "Choose a data loading option"
    printf '    1. Default: load bundled data/ folder (TPC-H sample)\n'
    printf '    2. Local CSV/Text File\n'
    printf '    3. Remote CSV/Text File\n'
    printf '    4. Import from Another Database\n'
    printf '    5. Import from Another Exasol\n'
    printf '    6. Exapump\n'
    printf '    7. SQL Script\n'
    printf '    8. Skip for now\n'
    _default_choice="1"
    _choice="$(prompt_text "Choose data option" "$_default_choice")"
    case "$_choice" in
        1)
            _kit_root="$(exakit_repo_root)" || die "Could not find the kit's sql/ and data/ files to load."
            exakit_load_sample_data "$_kit_root"
            ;;
        2) exakit_load_local_file ;;
        3) exakit_load_remote_file ;;
        4) exakit_show_database_import_guidance "Import from Another Database" ;;
        5) exakit_show_database_import_guidance "Import from Another Exasol" ;;
        6) exakit_show_exapump_guidance ;;
        7) exakit_run_sql_script ;;
        8|"") info "Skipping data load. Run it any time with: exakit data-load" ;;
        *) die "Unknown data loading option: $_choice" ;;
    esac
}

# exakit_load_sample_data <kit_root> [--force] — the full sample-data pipeline:
# create the schema, bulk-load every data/*.csv, run any transform, verify,
# then record the result in the manifest. One implementation, shared by
# setup/load-data.sh, the interactive installer offer, and `exakit load-data`,
# so the three entry points cannot drift apart.
#
# Uses die() for hard failures (missing profile, failed load/verify). Callers
# that must survive a failure (the installer offer) run it in a subshell so
# die()'s exit is contained; manifest writes persist because they are file I/O.
exakit_load_sample_data() {
    _kit_root="$1"
    _force="${2:-}"
    _schema="${EXAKIT_SCHEMA:-STARTER_KIT}"

    [ -n "$(manifest_get components.exapump.profile 2>/dev/null)" ] || \
        die "No exapump connection profile is recorded — the exapump setup step has not completed. Re-run the installer, then retry."

    if [ "$(manifest_get data.loaded 2>/dev/null)" = "true" ] && [ "$_force" != "--force" ]; then
        ok "Sample data already loaded (pass --force to re-run)"
        return 0
    fi

    info "Loading the sample dataset into schema $_schema"

    # 1. schema
    if [ -s "$_kit_root/sql/01_create_schema.sql" ]; then
        exapump_run_sql_file "$_kit_root/sql/01_create_schema.sql" "schema creation (01_create_schema.sql)"
    else
        info "Pending: sql/01_create_schema.sql not present — skipping schema step"
    fi

    # 2. data files
    _loaded_any=0
    for _csv in "$_kit_root"/data/*.csv; do
        [ -s "$_csv" ] || continue
        _table="$(basename "$_csv" .csv | tr '[:lower:]' '[:upper:]')"
        exapump_upload "$_csv" "$_schema.$_table"
        _loaded_any=1
    done
    if [ "$_loaded_any" -eq 0 ]; then
        info "Pending: no data files in data/ — nothing to load"
        return 0
    fi

    # 3. optional post-load transformations
    if [ -s "$_kit_root/sql/02_load_data.sql" ]; then
        exapump_run_sql_file "$_kit_root/sql/02_load_data.sql" "load statements (02_load_data.sql)"
    fi

    # 4. verify — a FAIL row or a query error blocks marking the data ready.
    if [ -s "$_kit_root/sql/03_verify_setup.sql" ]; then
        info "Verification (03_verify_setup.sql):"
        _verify_output="$(mktemp "${TMPDIR:-/tmp}/exakit-verify.XXXXXX")" || \
            die "Could not create a temporary file for verification output."
        # Capture exapump's own exit code directly (not via a pipe) so the
        # check does not depend on the caller having 'set -o pipefail';
        # stderr goes to the log so a connection error is still recorded.
        "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" < "$_kit_root/sql/03_verify_setup.sql" \
            > "$_verify_output" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"
        _verify_status=$?
        tee -a "${EXAKIT_LOG_FILE:-/dev/null}" < "$_verify_output"
        if [ "$_verify_status" -ne 0 ] || grep -qi 'FAIL' "$_verify_output"; then
            rm -f "$_verify_output"
            die "Verification failed (query error or a FAIL row) — see ${EXAKIT_LOG_FILE:-the log}. Data is loaded but not marked ready; fix the underlying issue and re-run with --force."
        fi
        rm -f "$_verify_output"
    fi

    # 5. row-count summary + manifest flags
    info "Row counts:"
    for _csv in "$_kit_root"/data/*.csv; do
        [ -s "$_csv" ] || continue
        _table="$(basename "$_csv" .csv | tr '[:lower:]' '[:upper:]')"
        _rows="$(exapump_count "$_schema.$_table")"
        printf '   %-30s %s rows\n' "$_schema.$_table" "${_rows:-?}" | tee -a "${EXAKIT_LOG_FILE:-/dev/null}"
    done
    manifest_set data.loaded true
    manifest_set data.schema "$_schema"
    manifest_set data.loaded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ok "Sample data loaded and verified"
    return 0
}
