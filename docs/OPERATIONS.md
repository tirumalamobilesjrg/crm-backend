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
- Procedure for the hosted project (manual, by an Admin / the project owner; **not yet performed**):
  1. `scripts/test-db.sh` passes locally and CI is green.
  2. Take a backup (section 3) before every production migration.
  3. `supabase link --project-ref $SUPABASE_PROJECT_REF`
  4. `supabase db push --dry-run`, review the SQL, then `supabase db push`.
  5. Smoke test with the Admin account.
  If the target database still has the five-role model, read docs/ROLE_MIGRATION.md first: migration 0019 refuses to run until unsupported roles are resolved by a human.
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

**Status:** the scripts work against a local PostgreSQL (tested, and in CI). `.github/workflows/backup.yml` is scheduled for
every 10 days (days 1, 11 and 21 of each month, 21:00 UTC) and keeps each encrypted backup as a GitHub Actions artifact for 90 days
(about nine generations). It stays inert until the owner does the one-time setup below. **Do not rely on backups being
operational until the checklist is done.**

One-time setup for the scheduled backup (owner; needs access to the GitHub repository settings and the Supabase dashboard):
1. `age-keygen -o crm-backup-key.txt`; keep the file offline. Copy only the public key (`age1...`).
2. GitHub repository -> Settings -> Secrets and variables -> Actions:
   - Variable `BACKUP_AGE_RECIPIENT` = the public key.
   - Secret `BACKUP_DATABASE_URL` = the **session pooler** connection string (Supabase -> Connect -> Session pooler, port 5432,
     host `aws-0-<region>.pooler.supabase.com`, user `postgres.<ref>`). Do not use the direct `db.<ref>.supabase.co` host: it is
     IPv6-only on the free plan and GitHub's runners cannot reach it.
   - Variable `BACKUP_ENABLED` = `true`.
3. Actions tab -> "Encrypted backup" -> Run workflow once, and download the artifact when it finishes.
4. Run the restore drill (section 4) on that artifact with the private key. Only then tick the checklist.
GitHub turns scheduled workflows off after 60 days with no repository activity; if the Actions tab says so, re-enable it.
The files are encrypted. A GitHub artifact is stored apart from Supabase, which is what matters here, but it is
not your own storage, so also copy one to your own drive every few months.

Checklist to declare backups operational:
- [ ] backup run against the real project succeeds
- [ ] copy stored off-platform
- [ ] restore drill (section 4) from that file passes
- [x] schedule configured in `backup.yml` (every 10 days); [ ] one scheduled run observed
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

## 5. First Admin account

Done once by the project owner in the Supabase dashboard / SQL editor (not in code):
1. Create the user in Authentication -> Users.
2. Run `insert into public.staff_profiles (user_id, full_name, role) values ('<auth user uuid>', '<name>', 'admin');`
3. As that Admin, open the discount policy and **set the Manager limits** (until you do, Managers have no discount
   allowance and every discount needs an Admin approval).
Further staff are created by an Admin through the CRM (insert into `staff_profiles` with role `admin` or `manager`) after
their auth users exist. Managers cannot create or promote accounts. Sign-ups are disabled in `config.toml`; make sure
the hosted project's Auth settings match (**manual, unverified**).
