#!/usr/bin/env bash
# mcp.sh — Exasol MCP server module (the AI agent bridge).
#
# Sourced by setup scripts after common.sh, detect.sh, a runtime module, and
# exapump.sh. Installs uv if needed, prepares MCP client configurations, and
# validates that the server starts and answers over stdio.
#
# Server facts:
#   - PyPI package exasol-mcp-server; run: uvx exasol-mcp-server@<version>
#   - config env: EXA_DSN, EXA_USER, EXA_PASSWORD
#   - HTTP mode: exasol-mcp-server-http --host <h> --port <p>
#   - the server's tools are read-only (metadata + data reading queries);
#     a least-privilege database user adds defense in depth
#
# Guardrail layering:
#   1. server is read-only by design
#   2. dedicated read-only database user (sql/mcp_readonly_user.sql, applied
#      automatically once it is delivered)
#   3. client configs point at that user, never the admin user, when present

EXAKIT_MCP_USER="${EXAKIT_MCP_USER:-MCP_READONLY}"
EXAKIT_MCP_HTTP_PORT="${EXAKIT_MCP_HTTP_PORT:-8123}"

mcp_uv_install() {
    if command -v uv >/dev/null 2>&1; then
        ok "uv already installed: $(command -v uv)"
        return 0
    fi
    info "Installing uv (Python tool runner used by the MCP server)"
    if command -v brew >/dev/null 2>&1; then
        run_logged brew install uv || die "brew install uv failed (see log)"
    else
        curl -LsSf --retry 3 https://astral.sh/uv/install.sh | run_logged sh || \
            die "uv installation failed (see log)"
        # The uv installer defaults to ~/.local/bin
        case ":$PATH:" in
            *":$HOME/.local/bin:"*) ;;
            *) PATH="$HOME/.local/bin:$PATH" ;;
        esac
    fi
    command -v uv >/dev/null 2>&1 || \
        die "uv installed but is not on PATH. Add ~/.local/bin to your PATH (or restart your shell), then re-run."
    push_rollback "uv cache clean >/dev/null 2>&1 || true"
    ok "uv installed"
}

mcp_install() {
    mcp_uv_install
    info "Priming ${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION} (downloads on first use)"
    run_logged uvx "${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION}" --help || \
        warn "Could not prime the MCP server package (it will download on first client start)"
    manifest_set components.mcp_server.package "$EXAKIT_MCP_PACKAGE"
    manifest_set components.mcp_server.version "$EXAKIT_MCP_VERSION"
    ok "MCP server ready to run via uvx"
}

# mcp_provision_readonly_user — apply the team's read-only user SQL once it
# is delivered. Supports a {{MCP_PASSWORD}} placeholder for the generated
# password; files without the placeholder run unchanged.
mcp_provision_readonly_user() {
    _sql="$1"
    if [ ! -s "$_sql" ]; then
        info "Pending: sql/mcp_readonly_user.sql not delivered yet — MCP will use the admin user for now"
        return 1
    fi
    command -v exapump_run_sql_file >/dev/null 2>&1 || {
        warn "exapump module not loaded — cannot apply $_sql"
        return 1
    }

    _password="$(read_credential mcp_readonly_password)"
    if [ -z "$_password" ]; then
        _password="$(generate_password)"
        store_credential mcp_readonly_password "$_password"
    fi

    if grep -q '{{MCP_PASSWORD}}' "$_sql"; then
        _tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-user.XXXXXX")"
        sed "s/{{MCP_PASSWORD}}/$_password/g" "$_sql" > "$_tmp"
        exapump_run_sql_file "$_tmp" "read-only MCP user (mcp_readonly_user.sql)"
        rm -f "$_tmp"
    else
        exapump_run_sql_file "$_sql" "read-only MCP user (mcp_readonly_user.sql)"
    fi
    manifest_set components.mcp_server.user "$EXAKIT_MCP_USER"
    return 0
}

# mcp_credentials — prints "user<TAB>password_file" for the client configs.
# Prefers the read-only user; falls back to the runtime admin user.
mcp_credentials() {
    if [ -n "$(manifest_get components.mcp_server.user 2>/dev/null)" ]; then
        printf '%s\t%s\n' "$EXAKIT_MCP_USER" "$EXAKIT_CREDS_DIR/mcp_readonly_password"
    else
        printf '%s\t%s\n' "$(manifest_get runtime.user 2>/dev/null)" \
            "$(manifest_get runtime.password_file 2>/dev/null)"
    fi
}

# mcp_generate_configs — write ready-to-use client configs (0600, because
# they embed the database password).
mcp_generate_configs() {
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    [ -n "$_dsn" ] || die "No runtime DSN in the manifest — install the database first."

    _kit_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    mcp_provision_readonly_user "$_kit_root/sql/mcp_readonly_user.sql" || true

    _creds="$(mcp_credentials)"
    _user="$(printf '%s' "$_creds" | cut -f1)"
    _pwfile="$(printf '%s' "$_creds" | cut -f2)"
    _password=""
    [ -n "$_pwfile" ] && [ -f "$_pwfile" ] && _password="$(cat "$_pwfile")"
    if [ -z "$_password" ]; then
        warn "No stored password for user '$_user' — edit the generated configs and fill EXA_PASSWORD manually"
        _password="FILL_ME_IN"
    fi
    if [ "$_user" != "$EXAKIT_MCP_USER" ]; then
        warn "MCP configs use the admin user until the read-only user SQL lands (the server itself is read-only)"
    fi

    mkdir -p "$EXAKIT_MCP_DIR"
    chmod 700 "$EXAKIT_MCP_DIR"

    require_python3
    python3 - "$EXAKIT_MCP_DIR" "$EXAKIT_MCP_PACKAGE" "$EXAKIT_MCP_VERSION" "$_dsn" "$_user" "$_password" <<'PY' || die "Could not write MCP configs"
import json, os, sys
out_dir, pkg, ver, dsn, user, password = sys.argv[1:7]
server = {
    "command": "uvx",
    "args": [f"{pkg}@{ver}"],
    "env": {"EXA_DSN": dsn, "EXA_USER": user, "EXA_PASSWORD": password},
}
configs = {
    # Claude Desktop: settings -> Developer -> Edit Config
    "claude-config.json": {"mcpServers": {"exasol": server}},
    # Cursor: .cursor/mcp.json or global MCP settings
    "cursor-config.json": {"mcpServers": {"exasol": server}},
    # Any other MCP client: the bare server definition
    "generic-config.json": {"exasol": server},
}
for name, doc in configs.items():
    path = os.path.join(out_dir, name)
    with open(path, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    os.chmod(path, 0o600)
PY
    manifest_set components.mcp_server.configs "[\"$EXAKIT_MCP_DIR/claude-config.json\", \"$EXAKIT_MCP_DIR/cursor-config.json\", \"$EXAKIT_MCP_DIR/generic-config.json\"]"
    ok "Client configs written to $EXAKIT_MCP_DIR (Claude Desktop, Cursor, generic)"
}

# mcp_validate — start the server over stdio and check it answers an MCP
# initialize handshake. Uses the same env the client configs use.
mcp_validate() {
    info "Validating the MCP server (stdio handshake)"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _creds="$(mcp_credentials)"
    _user="$(printf '%s' "$_creds" | cut -f1)"
    _pwfile="$(printf '%s' "$_creds" | cut -f2)"
    _password=""
    [ -n "$_pwfile" ] && [ -f "$_pwfile" ] && _password="$(cat "$_pwfile")"

    require_python3
    _handshake_ok=0
    for _attempt in 1 2; do
        if EXA_DSN="$_dsn" EXA_USER="$_user" EXA_PASSWORD="$_password" \
            python3 - "$EXAKIT_MCP_PACKAGE" "$EXAKIT_MCP_VERSION" <<'PY' >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
import json, subprocess, sys

pkg, ver = sys.argv[1], sys.argv[2]
proc = subprocess.Popen(
    ["uvx", f"{pkg}@{ver}"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True,
)
request = json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "starter-kit-validator", "version": "1.0"},
    },
}) + "\n"
try:
    out, err = proc.communicate(request, timeout=120)
except subprocess.TimeoutExpired:
    proc.kill()
    print("handshake timed out")
    sys.exit(1)
print(err)
for line in out.splitlines():
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    if msg.get("id") == 1 and "result" in msg:
        info = msg["result"].get("serverInfo", {})
        print(f"handshake ok: {info.get('name')} {info.get('version')}")
        sys.exit(0)
print("no initialize result in server output")
sys.exit(1)
PY
        then
            _handshake_ok=1
            break
        fi
        [ "$_attempt" -lt 2 ] && { warn "Handshake attempt $_attempt failed — retrying"; sleep 5; }
    done
    if [ "$_handshake_ok" -eq 1 ]; then
        ok "MCP server answers over stdio"
        manifest_set components.mcp_server.mode "stdio"
        manifest_set components.mcp_server.validated true
    else
        warn "MCP stdio validation failed (see log). The configs are still in place; clients may show more detail."
        manifest_set components.mcp_server.validated false
    fi

    if [ "${EXAKIT_MCP_HTTP_TEST:-0}" = "1" ]; then
        mcp_validate_http
    fi
}

# mcp_validate_http — optional: start the HTTP variant briefly and probe it.
mcp_validate_http() {
    info "Validating the MCP server (HTTP mode on port $EXAKIT_MCP_HTTP_PORT)"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _creds="$(mcp_credentials)"
    _user="$(printf '%s' "$_creds" | cut -f1)"
    _pwfile="$(printf '%s' "$_creds" | cut -f2)"
    _password=""
    [ -n "$_pwfile" ] && [ -f "$_pwfile" ] && _password="$(cat "$_pwfile")"

    # The HTTP server refuses to start without authentication unless
    # --no-auth is passed. For this brief localhost-only validation that is
    # acceptable; a real remote deployment must configure proper auth.
    EXA_DSN="$_dsn" EXA_USER="$_user" EXA_PASSWORD="$_password" \
        uvx --from "${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION}" \
        exasol-mcp-server-http --host 127.0.0.1 --port "$EXAKIT_MCP_HTTP_PORT" --no-auth \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 &
    _http_pid=$!
    # Poll instead of a fixed sleep: first uvx run may need to download.
    _http_ok=0
    _waited=0
    while [ "$_waited" -lt 60 ]; do
        if curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:$EXAKIT_MCP_HTTP_PORT/mcp" 2>/dev/null | grep -qE '^(200|3..|4..)'; then
            _http_ok=1
            break
        fi
        kill -0 "$_http_pid" 2>/dev/null || break
        sleep 2
        _waited=$((_waited + 2))
    done
    if [ "$_http_ok" -eq 1 ]; then
        ok "HTTP mode answers on port $EXAKIT_MCP_HTTP_PORT"
        manifest_set components.mcp_server.http_validated true
    else
        warn "HTTP mode did not answer on port $EXAKIT_MCP_HTTP_PORT (see log)"
        manifest_set components.mcp_server.http_validated false
    fi
    # uvx spawns the actual server as a child process — kill both, bounded.
    pkill -P "$_http_pid" 2>/dev/null
    kill "$_http_pid" 2>/dev/null
    sleep 1
    pkill -9 -P "$_http_pid" 2>/dev/null
    kill -9 "$_http_pid" 2>/dev/null
    wait "$_http_pid" 2>/dev/null || true
}
