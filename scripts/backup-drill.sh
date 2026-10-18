#!/usr/bin/env bash
# CI/local drill: back up the populated test database, restore into a scratch database, compare row counts,
# and re-run the structural security checks against the restored copy. Needs age + PG* variables.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${DB_NAME:-crm_foundation_test}"; DST="crm_restore_drill"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

age-keygen -o "$WORK/key.txt" 2> "$WORK/pub.txt"
PUB="$(grep -o 'age1[a-z0-9]*' "$WORK/pub.txt" | head -1)"
URL() { echo "dbname=$1"; }   # libpq conninfo: host/user/password come from the PG* variables

DATABASE_URL="$(URL "$SRC")" BACKUP_AGE_RECIPIENT="$PUB" BACKUP_DIR="$WORK" "$ROOT/scripts/backup.sh"

psql -X -q -d postgres -c "drop database if exists $DST with (force)" -c "create database $DST"
psql -X -q -d "$DST" -v ON_ERROR_STOP=1 -f "$ROOT/tests/db/support/supabase_shim.sql" >/dev/null 2>&1

BACKUP_FILE="$(ls "$WORK"/crm-*Z.dump.age)" AGE_IDENTITY_FILE="$WORK/key.txt" RESTORE_DATABASE_URL="$(URL "$DST")" \
  "$ROOT/scripts/restore-check.sh"

export PGDATABASE="$DST"
psql -X -q -v ON_ERROR_STOP=1 -f "$ROOT/tests/db/support/helpers.sql" >/dev/null 2>&1
{ echo "do \$\$ begin perform set_config('t.file', 'restored-copy', false); end \$\$;"; cat "$ROOT/tests/db/01_schema_security.test.sql"; } \
  | psql -X -q -o /dev/null -v ON_ERROR_STOP=1 -f -
FAILED="$(psql -X -At -c "select count(*) from t.results where not ok")"
echo "security structure checks on the restored copy: failed=$FAILED"
psql -X -q -d postgres -c "drop database $DST with (force)"
[[ "$FAILED" == "0" ]]
