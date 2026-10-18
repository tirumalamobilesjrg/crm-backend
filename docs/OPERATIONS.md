# Operations

Nothing in this repository has been deployed. These are the intended procedures; each one says whether it has been tested.

## 1. Environment variables

See `.env.example` for names. Secrets (`SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `DATABASE_URL`,
`SUPABASE_SERVICE_ROLE_KEY`, the age private key) live only in the owner's password manager / protected CI
environment. The anon key and project URL are public by design. **Never** put the service-role key into
`crm-frontend` or `public-website` code or into any `VITE_*` / `NEXT_PUBLIC_*` variable.

## 2. Migrations

- Add a new file `supabase/migrations/<UTC timestamp>_<name>.sql`; never edit one that has been applied to a real project.
- Every new table needs: RLS enabled, explicit grants, policies, and entries in the test matrix
  (`tests/db/01` and `02`). The suite fails if a table is missing RLS.
- Procedure for the hosted project (manual, by the owner; **not yet performed**):
  1. `scripts/test-db.sh` passes locally and CI is green.
  2. Take a backup (section 3) before every production migration.
  3. `supabase link --project-ref $SUPABASE_PROJECT_REF`
  4. `supabase db push --dry-run`, review the SQL, then `supabase db push`.
  5. Smoke test with the owner account.
- There is deliberately no CI job that pushes to production.

## 3. Encrypted backups

Free Supabase projects should be assumed to have **no usable backups**; this logical backup is the safety net.

One-time setup (owner):
```bash
age-keygen -o ~/crm-backup-key.txt      # prints the public key (age1...)
```
Store `crm-backup-key.txt` offline (password manager + printed copy in a safe). Put only the **public** key in
`BACKUP_AGE_RECIPIENT`. Whoever holds only the public key can create backups but not read them.

Run a backup (any machine with `pg_dump` and `age`):
```bash
export DATABASE_URL='postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres'   # direct connection
export BACKUP_AGE_RECIPIENT='age1...'
scripts/backup.sh
```
Output: `crm-<ts>.dump.age` (schemas `public` + `app`, with grants/policies), `crm-<ts>.auth.dump.age`
(`auth.users`, `auth.identities`), `.counts` manifest, `.sha256`. Copy them to storage that is separate from the
Supabase project (see ARCHITECTURE.md for free options). Keep several generations (e.g. daily for 7 days, weekly for 8 weeks).

**Status:** the scripts work against a local PostgreSQL (tested, and in CI). They have **not** been run against the hosted
Supabase project (the `auth` tables there have more columns/ownership differences), no schedule exists, and
`.github/workflows/backup.yml` is manual and disabled until `BACKUP_ENABLED=true`. **Do not rely on backups being
operational until the checklist below is done.**

Checklist to declare backups operational:
- [ ] backup run against the real project succeeds
- [ ] copy stored off-platform
- [ ] restore drill (section 4) from that file passes
- [ ] schedule configured and one scheduled run observed
- [ ] owner confirms the private key is stored offline and can decrypt

## 4. Restore

Drill (safe, repeatable) into an empty scratch database that already has the Supabase-compatible `auth` schema
(a throwaway Supabase project, or plain PostgreSQL with `tests/db/support/supabase_shim.sql`):
```bash
export BACKUP_FILE=backups/crm-<ts>.dump.age AGE_IDENTITY_FILE=~/crm-backup-key.txt
export RESTORE_DATABASE_URL='postgresql://...scratch...'
scripts/restore-check.sh      # verifies checksum, restores auth then public/app, compares row counts to the manifest
```
`scripts/backup-drill.sh` automates the same on a local database and also re-runs the security structure tests on the copy.

Disaster recovery (production lost):
1. Create a new Supabase project (free tier) and note the new URL / keys.
2. Run `restore-check.sh` against it **only if it is empty** (the script restores with `--clean`, which drops matching objects).
3. Re-run `tests/db/01_schema_security.test.sql` against the restored database (via `TEST_MODE=supabase`), confirm anon has only the 4 views.
4. Re-point `crm-frontend` / `public-website` to the new URL and anon key; re-issue any user sessions (JWT secret changes with the project).
5. Staff logins: `auth.users`/`identities` are restored; if password hashes do not work in the new project, reset passwords.
Recovery point objective = time since the last backup; there is no point-in-time recovery on the free plan.

## 5. First owner account

Done once by the project owner in the Supabase dashboard / SQL editor (not in code):
1. Create the user in Authentication → Users.
2. Run `insert into public.staff_profiles (user_id, full_name, role) values ('<auth user uuid>', '<name>', 'owner');`
Further staff are added by the owner through the CRM (insert into `staff_profiles`) after creating their auth users.
Sign-ups are disabled in `config.toml`; make sure the hosted project's Auth settings match (**manual, unverified**).
