# Role migration: five roles -> Admin and Manager (migration 0019)

The platform supports **exactly two staff roles**: `admin` and `manager`. Migration
`supabase/migrations/20261018000019_two_role_model.sql` converts a database that still has the five-role model
(owner, manager, sales_executive, inventory_executive, accountant). It is a forward migration; earlier migrations were
not edited. Nothing has been applied to a hosted database - Task 1/1B were never deployed - so this document is for the
first time the migration meets real data, and for any database built from the earlier commits.

## What the migration does

| Legacy | Becomes | Why |
|---|---|---|
| `owner` | `admin` | A rename: the same people keep the same authority. Not a promotion. |
| `manager` | `manager` | unchanged |
| `sales_executive`, `inventory_executive`, `accountant` | **not migrated** | The migration stops (see below). Nobody is silently promoted, demoted or deleted. |

Other effects, all in one transaction:

- The `staff_role` enum is **replaced** (Postgres cannot drop enum values): the old type is renamed, a new
  `('admin','manager')` type is created, `staff_profiles.role` and `discount_policies.role` are converted, the old type
  is dropped. Removed role names then fail with `22P02 invalid input value for enum` everywhere.
- `audit_logs.actor_role` becomes `text`, so history keeps the role names that were true when each row was written
  (old rows may say `owner`, `sales_executive`, ...). Audit rows are never rewritten.
- Discount policy rows for the three removed roles are deleted (the deletion is audited). The old `owner` row becomes
  the `admin` row unchanged. The `manager` row is reset to **no allowance** (`can_discount=false`, 0 %, no cap) **unless
  an Admin/owner ever edited it through the API** (proved by an `audit_logs` update by a non-null actor), in which case
  the configured limits are kept. In both cases the Manager's approval right (`can_approve`) is removed and a
  constraint forbids it from now on.
- All 49 RLS policies and the role-dependent functions are recreated for the two roles; see SECURITY.md.

## It refuses to run when it cannot be safe

The migration begins with read-only checks and stops with SQLSTATE `TM020` and a readable message when:

1. any `staff_profiles` row has a role other than `owner` or `manager` - **active or inactive** (inactive accounts still
   hold the role, so they are listed too); or
2. staff accounts exist but none is an **active** `owner` (there would be no Admin).

Nothing is changed in either case (verified by `tests/upgrade/role_migration.sh`, scenarios S1 and S2).

## Remediation (done by a human, before re-running the migration)

Run in the **old** schema (the old enum still has all five values), as the project owner via the SQL editor or the
service role. Decide per user; there is deliberately no automatic mapping.

```sql
-- 1. See who is affected (active and inactive)
select user_id, full_name, role, is_active
  from public.staff_profiles
 where role not in ('owner', 'manager')
 order by role, full_name;

-- 2a. Staff who should keep working: make them Managers. This is a decision, not a default.
update public.staff_profiles set role = 'manager' where user_id in ('<uuid>', '<uuid>');

-- 2b. Staff who should lose access: deactivate AND move to the only remaining non-admin role so the migration can run.
--     (Profiles are never deleted; a deactivated Manager has no access to anything.)
update public.staff_profiles set role = 'manager', is_active = false where user_id in ('<uuid>');

-- 3. Anyone who should become an Admin: promote to owner first (the migration renames owner -> admin).
update public.staff_profiles set role = 'owner' where user_id = '<uuid>';

-- 4. Confirm there is at least one active owner, and no unsupported roles remain
select count(*) filter (where role = 'owner' and is_active) as active_owners,
       count(*) filter (where role not in ('owner', 'manager')) as unsupported
  from public.staff_profiles;
```
Then take a backup (`scripts/backup.sh`) and apply the migration (`supabase db push --dry-run`, review, `supabase db push`).
Record the decisions in your own change log: the audit log shows the `staff_profiles` updates and who ran them.

## After the migration

- Review **Admin > Discount policy**: the Manager row is either "no allowance, never reviewed" (`configured_at IS NULL`)
  or your previously configured limits. Until an Admin saves Manager limits, every Manager discount needs an Admin approval.
- Sessions of removed-role users stop working immediately (their profiles are inactive Managers); consider also
  disabling their Supabase Auth accounts.
- Rolling back is a restore from the pre-migration backup; the migration is not reversible in place.
