# Testing

## What runs

`scripts/test-db.sh` (also `.github/workflows/ci.yml`):

1. creates an empty database, 2. installs the Supabase emulation shim (`tests/db/support/supabase_shim.sql`),
3. applies every migration in order, 4. loads the assertion helpers, 5. runs `tests/db/*.test.sql` in order,
6. runs real concurrent transactions (`tests/db/concurrency.sh`), 7. fails if any assertion failed.

| File | Covers |
|---|---|
| `00_fixtures` | builds a shop through the real RPCs/RLS; asserts the happy paths |
| `01_schema_security` | RLS on every table; anon has no privileges beyond 4 views; no PUBLIC function execution; exact view column lists; definer functions pin `search_path` |
| `02_rls_read_matrix` | every table × 8 identities (5 roles, deactivated staff, no profile, second sales exec) + anon |
| `03_write_permissions` | unauthorised writes, privilege escalation attempts, publication guard, RPC access per role, ledger tables closed |
| `04_imei_integrity` | duplicate/cross-column/in-request IMEI and serial rejection, Luhn, immutability, receipt-movement check |
| `05_purchasing` | receipt, rollback on bad counts, idempotent replay, key reuse, frozen purchases |
| `06_sales` | totals/GST, invoice numbering, rollback with no trace, validation, discount authority, idempotency, completeness constraints |
| `07_stock_adjustments` | allowed transitions, ledger reconstructs history, raw movement paths closed |
| `08_audit_immutability` | append-only tables (even for the table owner), audit content |
| `09_public_catalogue` | what anon sees, derived availability flips on sell-out / restock, unpublish |
| `concurrency.sh` | two sales of one device (one wins, loser waits on the lock), same idempotency key at once, invoice-number serialisation, aborted transaction leaves nothing |

Backup/restore is exercised separately by `scripts/backup-drill.sh` (CI job `backup-drill`): encrypt → restore into a
scratch database → compare row counts → re-run the structural security test on the restored copy.

The suite was also mutation-checked once by hand: disabling RLS on a table, adding a permissive policy, granting
`anon` a table, widening a catalogue view, and disabling the stock trigger each made it fail.

## Local PostgreSQL vs real Supabase — known differences

| Area | Shim (plain PostgreSQL) | Real Supabase |
|---|---|---|
| Roles | `anon`, `authenticated`, `service_role`, `authenticator` created by the shim; connecting role may `SET ROLE` to them | Created by the platform; `postgres` is not a true superuser |
| `auth` schema | Only `auth.users(id,email)`, `auth.uid()/role()/jwt()` | Full GoTrue schema; `auth.users` has many more columns |
| JWT context | Simulated with `request.jwt.claims` + `SET ROLE` (the same mechanism PostgREST uses) | PostgREST sets them per request from a verified JWT; token verification itself is **not** tested here |
| Default privileges | Shim grants everything to API roles on new `public` objects to mimic Supabase; migrations must revoke it | Platform default ACLs (believed equivalent; verify with the `supabase-local` CI job) |
| Extensions / pg_graphql / realtime / storage / Data API schema cache | Not present | Present. pg_graphql can expose tables to anon introspection if enabled; this repo's grants leave anon only the 4 views |
| PostgreSQL version | 16 locally, 16 and 17 in CI | Hosted versions are chosen by Supabase (`config.toml` targets 17) |
| PostgREST behaviour | Not exercised (no HTTP layer). Error text/status mapping of SQLSTATEs (e.g. `42501` → 403) is untested | Real |

The `supabase-local` CI job (`TEST_MODE=supabase`) runs the same tests against `supabase start`. It is configured
`continue-on-error` until it has been observed passing; check the latest Actions run before trusting it.

## Not verified

- Anything over HTTP (PostgREST routing, JWT signature checks, CORS, Auth settings).
- Behaviour against a real hosted Supabase project (nothing was deployed).
- Performance under load; free-tier limits.
- Automated backups on a schedule (not configured — see OPERATIONS.md).
