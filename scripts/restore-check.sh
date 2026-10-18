#!/usr/bin/env bash
# Restore drill: decrypt a backup, restore it into a SCRATCH database and compare row counts with the
# manifest written at backup time. Never point RESTORE_DATABASE_URL at production.
#
# Required: BACKUP_FILE (the …dump.age file; its …auth.dump.age sibling is restored first), AGE_IDENTITY_FILE (private key file), RESTORE_DATABASE_URL (empty scratch DB).
# The scratch DB needs the Supabase-compatible `auth` schema + roles first: on plain PostgreSQL apply
# tests/db/support/supabase_shim.sql; on a fresh Supabase project they already exist.
set -euo pipefail

: "${BACKUP_FILE:?}"; : "${AGE_IDENTITY_FILE:?}"; : "${RESTORE_DATABASE_URL:?}"
if [[ -n "${DATABASE_URL:-}" && "$DATABASE_URL" == "$RESTORE_DATABASE_URL" ]]; then
  echo "refusing: RESTORE_DATABASE_URL equals DATABASE_URL (production)" >&2; exit 2
fi
COUNTS="${BACKUP_FILE%.dump.age}.counts"
[[ -f "$COUNTS" ]] || { echo "missing manifest $COUNTS" >&2; exit 2; }

SUM="${BACKUP_FILE%.dump.age}.sha256"
if [[ -f "$SUM" ]]; then ( cd "$(dirname "$BACKUP_FILE")" && sha256sum --check --quiet "$(basename "$SUM")" ); echo "checksum ok"; fi

AUTH_FILE="${BACKUP_FILE%.dump.age}.auth.dump.age"
[[ -f "$AUTH_FILE" ]] || { echo "missing $AUTH_FILE" >&2; exit 2; }
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
for f in "$AUTH_FILE" "$BACKUP_FILE"; do   # identities first: staff_profiles references auth.users
  age --decrypt --identity "$AGE_IDENTITY_FILE" --output "$TMP" "$f"
  pg_restore --dbname "$RESTORE_DATABASE_URL" --clean --if-exists --no-owner --exit-on-error "$TMP"
done

fail=0
while IFS=$'\t' read -r tbl expected; do
  got="$(psql "$RESTORE_DATABASE_URL" -X -At -c "select count(*) from $tbl")"
  if [[ "$got" != "$expected" ]]; then echo "MISMATCH $tbl: backup=$expected restored=$got"; fail=1; fi
done < "$COUNTS"
if [[ $fail == 0 ]]; then
  echo "restore check passed: all table row counts match the manifest"
else
  echo "restore check FAILED"
  exit 1
fi
