#!/usr/bin/env bash
# Applies every migration to a fresh database and runs the SQL tests in tests/db.
#
#   TEST_MODE=shim      (default) create $DB_NAME on a plain PostgreSQL server and emulate Supabase
#                       roles/auth with tests/db/support/supabase_shim.sql.
#   TEST_MODE=supabase  run against a real local Supabase stack (`supabase start` + `supabase db reset`
#                       already applied the migrations). Needs DATABASE_URL.
#
# Connection for shim mode comes from the standard PG* variables (PGHOST, PGPORT, PGUSER, PGPASSWORD).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${TEST_MODE:-shim}"
DB_NAME="${DB_NAME:-crm_foundation_test}"

if [[ "$MODE" == "shim" ]]; then
  ADMIN=(psql -X -q -v ON_ERROR_STOP=1 -d postgres)
  "${ADMIN[@]}" -c "drop database if exists \"$DB_NAME\" with (force)" -c "create database \"$DB_NAME\""
  export PGDATABASE="$DB_NAME"
  PSQL=(psql -X -q -v ON_ERROR_STOP=1)
  "${PSQL[@]}" -f "$ROOT/tests/db/support/supabase_shim.sql"
  for f in "$ROOT"/supabase/migrations/*.sql; do
    echo "migrate: $(basename "$f")"
    "${PSQL[@]}" -f "$f"
  done
elif [[ "$MODE" == "supabase" ]]; then
  : "${DATABASE_URL:?DATABASE_URL is required in supabase mode}"
  PSQL=(psql -X -q -v ON_ERROR_STOP=1 "$DATABASE_URL")
else
  echo "unknown TEST_MODE=$MODE" >&2; exit 2
fi

"${PSQL[@]}" -f "$ROOT/tests/db/support/helpers.sql"

for f in "$ROOT"/tests/db/*.test.sql; do
  name="$(basename "$f" .test.sql)"
  echo "test: $name"
  { echo "do \$\$ begin perform set_config('t.file', '$name', false); end \$\$;"; cat "$f"; } | "${PSQL[@]}" -o /dev/null -f -
done

if [[ -x "$ROOT/tests/db/concurrency.sh" ]]; then
  echo "test: concurrency"
  "$ROOT/tests/db/concurrency.sh"
fi

echo
"${PSQL[@]}" -At -F $'\t' -c "select case when ok then 'PASS' else 'FAIL' end, file, name, coalesce(detail,'') from t.results where not ok order by id" \
  | sed 's/^/  /' || true
FAILED="$("${PSQL[@]}" -At -c "select count(*) from t.results where not ok")"
TOTAL="$("${PSQL[@]}" -At -c "select count(*) from t.results")"
echo "assertions: $TOTAL, failed: $FAILED"
[[ "$FAILED" == "0" && "$TOTAL" -gt 0 ]]
