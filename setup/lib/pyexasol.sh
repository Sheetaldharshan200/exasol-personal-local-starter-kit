# pyexasol.sh — pyexasol (Exasol Python driver): managed install + validation.
#
# Installs the official Exasol Python driver (github.com/exasol/pyexasol)
# into a dedicated uv-managed virtual environment under $EXAKIT_HOME, so
# users can script against the local database from Python immediately —
# without touching the system interpreter or any of their own projects.
#
#   - PyPI package: pyexasol
#   - venv:         $EXAKIT_HOME/pyexasol-venv
#   - use it:       ~/.exasol-starter-kit/pyexasol-venv/bin/python
#                       >>> import pyexasol
#
# Requires common.sh sourced first. Safe to re-run: an existing venv with
# the desired version installed is kept as-is.

EXAKIT_PYEXASOL_PACKAGE="${EXAKIT_PYEXASOL_PACKAGE:-pyexasol}"
EXAKIT_PYEXASOL_VENV="${EXAKIT_PYEXASOL_VENV:-$EXAKIT_HOME/pyexasol-venv}"

pyexasol_venv_python() {
    printf '%s\n' "$EXAKIT_PYEXASOL_VENV/bin/python"
}

pyexasol_installed_version() {
    _pyx_python="$(pyexasol_venv_python)"
    [ -x "$_pyx_python" ] || return 1
    "$_pyx_python" -c 'import pyexasol; print(pyexasol.__version__)' 2>/dev/null
}

pyexasol_install() {
    # uv is normally present already (the MCP step installs it and it is a
    # hard dependency of the kit); bootstrap it here only if this step runs
    # in a build without the MCP module.
    if ! command -v uv >/dev/null 2>&1; then
        if command -v mcp_uv_install >/dev/null 2>&1; then
            mcp_uv_install
        else
            die "uv is required to install pyexasol but is not available. Install uv (https://docs.astral.sh/uv/) and re-run."
        fi
    fi

    _pyx_current="$(pyexasol_installed_version || true)"
    if [ -n "$_pyx_current" ] && [ "$_pyx_current" = "$EXAKIT_PYEXASOL_VERSION" ]; then
        ok "pyexasol $_pyx_current already installed: $EXAKIT_PYEXASOL_VENV"
    else
        info "Installing pyexasol $EXAKIT_PYEXASOL_VERSION (Exasol Python driver)"
        if [ ! -x "$(pyexasol_venv_python)" ]; then
            run_logged uv venv --python "$EXAKIT_MANAGED_PYTHON_VERSION" "$EXAKIT_PYEXASOL_VENV" || \
                die "Could not create the pyexasol virtual environment at $EXAKIT_PYEXASOL_VENV (see log)."
            push_rollback "rm -rf '$EXAKIT_PYEXASOL_VENV'"
        fi
        run_logged uv pip install --python "$(pyexasol_venv_python)" \
            "${EXAKIT_PYEXASOL_PACKAGE}==${EXAKIT_PYEXASOL_VERSION}" || \
            die "pyexasol installation failed (see log)."
        ok "pyexasol installed: $EXAKIT_PYEXASOL_VENV"
    fi

    manifest_set components.pyexasol.version "$EXAKIT_PYEXASOL_VERSION"
    manifest_set components.pyexasol.venv "$EXAKIT_PYEXASOL_VENV"
    manifest_set components.pyexasol.python "$(pyexasol_venv_python)"
}

# pyexasol_validate — prove the driver imports, then run SELECT 1 against the
# local database with the runtime credentials. A failed live check records
# validated=false and warns rather than aborting the install: the database
# and every other component are unaffected, and a re-run retries this step.
pyexasol_validate() {
    _pyx_python="$(pyexasol_venv_python)"
    "$_pyx_python" -c 'import pyexasol' >/dev/null 2>&1 || \
        die "pyexasol is installed but cannot be imported from $EXAKIT_PYEXASOL_VENV (see log). Remove the venv and re-run."

    _pyx_host="$(_exakit_parse_runtime_host)"
    _pyx_port="$(_exakit_parse_runtime_port)"
    _pyx_user="$(_exakit_manifest_runtime_value runtime.user)"
    _pyx_pwfile="$(_exakit_manifest_runtime_value runtime.password_file)"
    if [ -z "$_pyx_host" ] || [ -z "$_pyx_port" ] || [ -z "$_pyx_user" ] || \
       [ -z "$_pyx_pwfile" ] || [ ! -f "$_pyx_pwfile" ]; then
        warn "Runtime connection details are incomplete; skipping the pyexasol live check. Re-run setup to retry."
        manifest_set components.pyexasol.validated false
        return 0
    fi

    info "Validating pyexasol against the database (SELECT 1)"
    # The password travels via a file read inside python, never on a command
    # line. TLS mirrors the exapump profile posture (tls on, local cert not
    # validated); a plain connection is the fallback for non-TLS runtimes.
    if EXAKIT_PYX_DSN="${_pyx_host}:${_pyx_port}" \
       EXAKIT_PYX_USER="$_pyx_user" \
       EXAKIT_PYX_PWFILE="$_pyx_pwfile" \
       "$_pyx_python" - >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 <<'PY'
import os, ssl, pyexasol
pw = open(os.environ["EXAKIT_PYX_PWFILE"]).read().strip()
kw = dict(dsn=os.environ["EXAKIT_PYX_DSN"], user=os.environ["EXAKIT_PYX_USER"], password=pw)
try:
    conn = pyexasol.connect(encryption=True, websocket_sslopt={"cert_reqs": ssl.CERT_NONE}, **kw)
except Exception:
    conn = pyexasol.connect(encryption=False, **kw)
try:
    value = conn.execute("SELECT 1").fetchval()
    raise SystemExit(0 if value == 1 else 1)
finally:
    conn.close()
PY
    then
        ok "pyexasol works: SELECT 1 returned 1"
        manifest_set components.pyexasol.validated true
        info "Use it from Python:  $_pyx_python  (import pyexasol)"
    else
        warn "pyexasol could not complete SELECT 1 against the database (see log). Recorded validated=false; re-run setup to retry."
        manifest_set components.pyexasol.validated false
    fi
    return 0
}
