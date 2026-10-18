#!/usr/bin/env bash
# Encrypted logical backup of the business data. Produces, in $BACKUP_DIR:
#   crm-<UTC timestamp>.dump.age       schemas `public` + `app` (pg_dump custom format), encrypted to an age public key
#   crm-<UTC timestamp>.auth.dump.age  auth.users + auth.identities (staff identities that staff_profiles points at)
#   crm-<UTC timestamp>.counts     row counts per table (used by restore-check.sh)
#   crm-<UTC timestamp>.sha256     checksum of the encrypted file
#
# Required: DATABASE_URL (use the DIRECT or session-pooler connection string), BACKUP_AGE_RECIPIENT (age public key, "age1...").
# The private key is NOT needed here and must never be stored next to the backups.
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${BACKUP_AGE_RECIPIENT:?BACKUP_AGE_RECIPIENT (age public key) is required}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
command -v age >/dev/null || { echo "age is not installed" >&2; exit 2; }
command -v pg_dump >/dev/null || { echo "pg_dump is not installed" >&2; exit 2; }

umask 077
mkdir -p "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$BACKUP_DIR/crm-$STAMP.dump.age"

# Row counts first (cheap integrity manifest). Table names are listed from the catalog, not user input.
psql "$DATABASE_URL" -X -At -v ON_ERROR_STOP=1 -c "
  select 'public.' || tablename || E'\t' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', tablename), false, true, '')))[1]::text
    from pg_tables where schemaname = 'public' order by tablename" > "$BACKUP_DIR/crm-$STAMP.counts"

# (pg_dump intersects -n and -t, so the two scopes are separate dumps.)
pg_dump "$DATABASE_URL" --format=custom --no-owner --compress=6 --schema=public --schema=app \
  | age --recipient "$BACKUP_AGE_RECIPIENT" --output "$OUT"
pg_dump "$DATABASE_URL" --format=custom --no-owner --compress=6 \
  --table=auth.users --table=auth.identities \
  | age --recipient "$BACKUP_AGE_RECIPIENT" --output "$BACKUP_DIR/crm-$STAMP.auth.dump.age"
echo -e "auth.users\t$(psql "$DATABASE_URL" -X -At -c 'select count(*) from auth.users')" >> "$BACKUP_DIR/crm-$STAMP.counts"

( cd "$BACKUP_DIR" && sha256sum "crm-$STAMP.dump.age" "crm-$STAMP.auth.dump.age" > "crm-$STAMP.sha256" )
echo "backup written: $OUT ($(wc -c < "$OUT") bytes)"
