#!/usr/bin/env bash
# load-data.sh — load the sample dataset into the local database.
#
#   bash setup/load-data.sh            # runs schema + load + verify once
#   bash setup/load-data.sh --force    # re-runs even if already loaded
#
# Separate from the installer on purpose: the one-command install brings up
# the components; this script fills the database, and can be re-run any time
# (every run is fully logged — that is the repeatability story).
#
# Consumes files delivered by the team, referenced by path:
#   sql/01_create_schema.sql   sql/02_load_data.sql   sql/03_verify_setup.sql
#   data/*.csv
# Missing files are reported as pending, not errors.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
. "$LIB_DIR/exapump.sh"

EXAKIT_SCHEMA="${EXAKIT_SCHEMA:-STARTER_KIT}"
EXAKIT_LOG_FILE="$EXAKIT_LOG_DIR/load-data-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$EXAKIT_LOG_DIR"
: > "$EXAKIT_LOG_FILE"

[ -f "$EXAKIT_MANIFEST" ] || die "No installation found. Run the installer first."
command -v "$(exapump_cli)" >/dev/null 2>&1 || [ -x "$(exapump_cli)" ] || \
    die "exapump is not installed. Run the installer first."

if [ "$(manifest_get data.loaded 2>/dev/null)" = "true" ] && [ "${1:-}" != "--force" ]; then
    ok "Sample data already loaded (pass --force to re-run)"
    exit 0
fi

info "Loading the sample dataset (log: $EXAKIT_LOG_FILE)"

# --- 1. schema ---------------------------------------------------------------
if [ -s "$KIT_ROOT/sql/01_create_schema.sql" ]; then
    exapump_run_sql_file "$KIT_ROOT/sql/01_create_schema.sql" "schema creation (01_create_schema.sql)"
else
    info "Pending: sql/01_create_schema.sql not delivered yet — skipping schema step"
fi

# --- 2. data files -------------------------------------------------------------
_loaded_any=0
for _csv in "$KIT_ROOT"/data/*.csv; do
    [ -s "$_csv" ] || continue
    _table="$(basename "$_csv" .csv | tr '[:lower:]' '[:upper:]')"
    exapump_upload "$_csv" "$EXAKIT_SCHEMA.$_table"
    _loaded_any=1
done
if [ "$_loaded_any" -eq 0 ]; then
    info "Pending: no data files in data/ yet — skipping load step"
fi

# --- 3. load transformations (if the team ships any) -----------------------------
if [ -s "$KIT_ROOT/sql/02_load_data.sql" ]; then
    exapump_run_sql_file "$KIT_ROOT/sql/02_load_data.sql" "load statements (02_load_data.sql)"
fi

# --- 4. verify -------------------------------------------------------------------
if [ -s "$KIT_ROOT/sql/03_verify_setup.sql" ]; then
    info "Verification (03_verify_setup.sql):"
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" < "$KIT_ROOT/sql/03_verify_setup.sql" | tee -a "$EXAKIT_LOG_FILE"
fi

if [ "$_loaded_any" -eq 1 ]; then
    info "Row counts:"
    for _csv in "$KIT_ROOT"/data/*.csv; do
        [ -s "$_csv" ] || continue
        _table="$(basename "$_csv" .csv | tr '[:lower:]' '[:upper:]')"
        _rows="$(exapump_count "$EXAKIT_SCHEMA.$_table")"
        printf '   %-30s %s rows\n' "$EXAKIT_SCHEMA.$_table" "${_rows:-?}" | tee -a "$EXAKIT_LOG_FILE"
    done
    manifest_set data.loaded true
    manifest_set data.schema "$EXAKIT_SCHEMA"
    manifest_set data.loaded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ok "Sample data loaded and verified"
else
    info "Nothing was loaded — data files are pending"
fi
