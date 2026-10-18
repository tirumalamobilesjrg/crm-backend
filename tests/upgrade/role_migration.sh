#!/usr/bin/env bash
# Verifies migration 0019 (five roles -> Admin/Manager) against databases built from migrations 0001-0018 and
# populated with legacy data. Needs a PostgreSQL server reachable through the PG* variables (superuser).
# Each scenario gets a fresh database. Exit status is non-zero if any check fails.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1${2:+ ($2)}"; }
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}
q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

new_db() { # name -> database holding migrations 0001-0018
  DB="crm_rolemig_$1"
  psql -X -q -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB" >/dev/null
  q -f "$ROOT/tests/db/support/supabase_shim.sql" >/dev/null 2>&1
  for f in "$ROOT"/supabase/migrations/*.sql; do
    [[ "$(basename "$f")" > "20261018000018" ]] && continue
    q -f "$f" >/dev/null || { bad "legacy schema builds ($(basename "$f"))"; return 1; }
  done
}
migrate() { # applies 0019 in a single transaction; prints errors
  q -1 -f "$ROOT/supabase/migrations/20261018000019_two_role_model.sql" 2>&1
}
user() { q -c "insert into auth.users (id, email) values ('$1', '$2@example.test')"; }
U_OWNER=b0000000-0000-0000-0000-000000000001; U_MGR=b0000000-0000-0000-0000-000000000002
U_SALES=b0000000-0000-0000-0000-000000000003; U_ACCT=b0000000-0000-0000-0000-000000000004
U_INV=b0000000-0000-0000-0000-000000000005

echo "S1: unsupported roles present -> the migration refuses, changes nothing, promotes nobody"
new_db s1 && {
  for u in OWNER MGR SALES ACCT; do eval "user \$U_$u $u"; done
  q -c "insert into public.staff_profiles (user_id, full_name, role, is_active) values
        ('$U_OWNER','O','owner',true), ('$U_MGR','M','manager',true), ('$U_SALES','S','sales_executive',true), ('$U_ACCT','A','accountant',false)"
  OUT="$(migrate)"; RC=$?
  [[ $RC -ne 0 ]] && ok "migration exits non-zero" || bad "migration exits non-zero"
  grep -q "Unsupported staff roles" <<<"$OUT" && ok "message says unsupported roles" || bad "message says unsupported roles" "$OUT"
  grep -q "$U_SALES (sales_executive, active)" <<<"$OUT" && ok "lists the sales_executive user with status" || bad "lists the sales_executive user" "$OUT"
  grep -q "$U_ACCT (accountant, inactive)" <<<"$OUT" && ok "lists the inactive accountant too (inactive accounts are not skipped)" || bad "lists the inactive accountant"
  grep -q "docs/ROLE_MIGRATION.md" <<<"$OUT" && ok "points to the remediation document" || bad "points to the remediation document"
  check "role type is still the 5-value legacy enum" 5 "$(q -c "select cardinality(enum_range(null::public.staff_role))")"
  check "nobody was promoted: roles unchanged" "accountant,manager,owner,sales_executive" "$(q -c "select string_agg(role::text, ',' order by role::text) from public.staff_profiles")"
  check "discount policy rows untouched (5)" 5 "$(q -c "select count(*) from public.discount_policies")"
  check "no new objects from 0019 leaked (guard trigger absent)" 0 "$(q -c "select count(*) from pg_trigger where tgname = 'staff_profiles_guard_changes'")"
}

echo "S2: accounts exist but no active owner -> refuses"
new_db s2 && {
  user $U_MGR M; user $U_OWNER O
  q -c "insert into public.staff_profiles (user_id, full_name, role, is_active) values ('$U_MGR','M','manager',true), ('$U_OWNER','O','owner',false)"
  OUT="$(migrate)"; RC=$?
  [[ $RC -ne 0 ]] && grep -q "no active owner" <<<"$OUT" && ok "refuses when no active owner exists" || bad "refuses when no active owner exists" "$OUT"
  check "state unchanged" 5 "$(q -c "select cardinality(enum_range(null::public.staff_role))")"
}

echo "S3: remediation applied (unsupported users moved to inactive Manager by a human), then the migration succeeds"
new_db s3 && {
  for u in OWNER MGR SALES ACCT INV; do eval "user \$U_$u $u"; done
  q -c "insert into public.staff_profiles (user_id, full_name, role, is_active) values
        ('$U_OWNER','O','owner',true), ('$U_MGR','M','manager',true), ('$U_SALES','S','sales_executive',true),
        ('$U_ACCT','A','accountant',false), ('$U_INV','I','inventory_executive',true)"
  q -c "insert into public.audit_logs (action, actor_id, actor_role, table_name) values ('legacy.sale', '$U_SALES', 'sales_executive', 'sales')"
  # documented remediation: decide per user. Here: deactivate and move to the only non-admin role. Nobody becomes Admin.
  q -c "update public.staff_profiles set role = 'manager', is_active = false where role::text in ('sales_executive','inventory_executive','accountant')"
  OUT="$(migrate)"; RC=$?
  [[ $RC -eq 0 ]] && ok "migration succeeds after remediation" || bad "migration succeeds after remediation" "$OUT"
  check "role type is now exactly admin,manager" "{admin,manager}" "$(q -c "select enum_range(null::public.staff_role)")"
  check "owner became admin; others stayed manager" "admin:1,manager:4" "$(q -c "select string_agg(role::text || ':' || c, ',' order by role::text) from (select role, count(*) c from public.staff_profiles group by 1) x")"
  check "the remediated users are still inactive" 3 "$(q -c "select count(*) from public.staff_profiles where not is_active")"
  check "nobody except the former owner holds admin" "$U_OWNER" "$(q -c "select user_id from public.staff_profiles where role = 'admin'")"
  check "discount policy now has only admin and manager" "admin,manager" "$(q -c "select string_agg(role::text, ',' order by role::text) from public.discount_policies")"
  check "Manager seeded allowance reset (never edited by a person)" "false|0.00|false" "$(q -c "select can_discount||'|'||max_percent||'|'||can_approve from public.discount_policies where role = 'manager'")"
  check "Admin policy kept (owner row renamed)" "true|100.00|true" "$(q -c "select can_discount||'|'||max_percent||'|'||can_approve from public.discount_policies where role = 'admin'")"
  check "audit history preserved verbatim" "sales_executive" "$(q -c "select actor_role from public.audit_logs where action = 'legacy.sale'")"
  check "removal of obsolete policy rows is itself audited" 3 "$(q -c "select count(*) from public.audit_logs where table_name = 'discount_policies' and action = 'delete'")"
  check "legacy enum is gone" "" "$(q -c "select to_regtype('public.staff_role_legacy')")"
  OUT2="$(q -c "insert into public.staff_profiles (user_id, full_name, role) values ('$U_INV','x','sales_executive')" 2>&1 || true)"
  grep -q "invalid input value for enum" <<<"$OUT2" && ok "removed role names are rejected after the migration" || bad "removed role names are rejected" "$OUT2"
  check "RLS policies were recreated (49)" 49 "$(q -c "select count(*) from pg_policies where schemaname = 'public'")"
}

echo "S4: Manager policy already configured by a person is preserved (approval right still removed)"
new_db s4 && {
  user $U_OWNER O
  q -c "insert into public.staff_profiles (user_id, full_name, role) values ('$U_OWNER','O','owner')"
  # an edit made through the API by the owner is audited with a non-null actor
  q <<SQL >/dev/null
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$U_OWNER","role":"authenticated"}', true);
update public.discount_policies set max_percent = 15 where role = 'manager';
commit;
SQL
  OUT="$(migrate)"; RC=$?
  [[ $RC -eq 0 ]] && ok "migration succeeds" || bad "migration succeeds" "$OUT"
  check "configured Manager limit kept at 15 %; approval right removed" "true|15.00|false" "$(q -c "select can_discount||'|'||max_percent||'|'||can_approve from public.discount_policies where role = 'manager'")"
}

echo "S5: empty staff table (fresh project) -> succeeds"
new_db s5 && {
  OUT="$(migrate)"; RC=$?
  [[ $RC -eq 0 ]] && ok "migration succeeds with no staff yet" || bad "migration succeeds with no staff yet" "$OUT"
  check "enum" "{admin,manager}" "$(q -c "select enum_range(null::public.staff_role)")"
}

for s in s1 s2 s3 s4 s5; do psql -X -q -d postgres -c "drop database if exists crm_rolemig_$s with (force)" >/dev/null 2>&1; done
echo
echo "role migration checks: passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 && $PASS -gt 0 ]]
