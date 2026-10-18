# Testing

## What runs

`scripts/test-db.sh` (also `.github/workflows/ci.yml`):

1. creates an empty database, 2. installs the Supabase emulation shim (`tests/db/support/supabase_shim.sql`),
3. applies every migration in order, 4. loads the assertion helpers, 5. runs `tests/db/*.test.sql` in order,
6. runs real concurrent transactions (`tests/db/concurrency.sh`), 7. fails if any assertion failed.

| File | Covers |
|---|---|
| `00_fixtures` | builds a shop through the real RPCs/RLS as Admin and Managers (phones, an accessory SKU, mixed-cart sale, approval, correction); asserts the default Manager discount policy (no allowance) before an Admin configures it |
| `01_schema_security` | RLS on every table; anon has no privileges beyond 4 views; no PUBLIC function execution; exact view column lists; definer functions pin `search_path`; no tax-like columns; the role enum is exactly admin/manager and no function or policy mentions a removed role |
| `02_rls_read_matrix` | every table x 5 identities (Admin, Manager, second Manager, deactivated Manager, no profile) + anon |
| `03_write_permissions` | ledger/financial tables closed to both roles, Manager and Admin catalogue/customer/expense rules, RPC access denied to anon, no-profile, deactivated and former-role accounts |
| `04_imei_integrity` | duplicate/cross-column/in-request IMEI and serial rejection, Luhn, direct-edit blocks, receipt-movement check, device-vs-quantity SKU guard |
| `05_purchasing` | receipt, rollback on bad counts, idempotent replay, key reuse, frozen purchases |
| `06_sales` | totals (no tax), invoice numbering, rollback with no trace, validation, idempotency, completeness constraints |
| `07_stock_adjustments` | allowed transitions, ledger reconstructs history, raw movement paths closed |
| `08_audit_immutability` | append-only tables (even for the table owner), audit content, audit log readable by Admin only |
| `09_public_catalogue` | what anon sees, derived availability for phones and accessories, unpublish, approved `public_price` |
| `10_discounts` | Admin-configured Manager limits, caps, switch-off, Admin policy, Admin-only approvals (use, expiry, reuse, wrong user, approver demoted or deactivated), authorisation record, audit |
| `11_quantity_inventory` | accessory receiving, mixed purchases, tracking-mode lock, selling, overselling, adjustments, ledger invariants |
| `12_identifier_corrections` | authority, validation, duplicates, history, reuse of retired values, swap/clear, sold devices, tamper-proofing |
| `13_single_payment` | single-payment shape, reconciliation, no gateway/credit semantics, DB uniqueness |
| `14_two_role_model` | removed roles cannot be assigned or used; every Admin-only power denied to a Manager; Admin and Manager positive cases; audit of sensitive actions by both roles |
| `concurrency.sh` | A two sales of one device; B same idempotency key at once; C invoice-number serialisation; D aborted transaction; E two accessory sales racing for stock; F one Admin approval used twice at once; G two corrections racing for one IMEI |
| `tests/upgrade/role_migration.sh` (separate command) | migration 0019 against legacy five-role data: refuses unsupported roles (active and inactive) and a missing owner without changing anything; succeeds after remediation; owner -> admin; nobody promoted; audit history and configured Manager limits preserved |

Backup/restore is exercised separately by `scripts/backup-drill.sh` (CI job `backup-drill`): encrypt → restore into a
scratch database → compare row counts → re-run the structural security test on the restored copy.

The suite was also mutation-checked by hand (not part of CI): disabling RLS on a table, adding a permissive policy,
granting `anon` a table or `stock_levels`, widening a catalogue view, disabling the stock-movement or stock-level
triggers, dropping the active-identifier unique index or the single-payment indexes, removing the discount-limit,
payment-equals-total, idempotency or accessory-stock checks from `finalize_sale`, and dropping the
`sales_discount_record` constraint each made at least one assertion fail or a test file abort. Two mutations were
not detected because they only remove a redundant backstop (the `on_hand >= 0` check behind the guarded update,
and one of two unique payment indexes).

## Last recorded result (local PostgreSQL 16, shim mode)

`scripts/test-db.sh`: **711 assertions, 0 failed** (exit 0): fixtures 11, schema security 25, RLS read matrix 192,
write permissions 66, IMEI integrity 22, purchasing 30, sales 51, stock adjustments 17, audit/immutability 21,
public catalogue 49, discounts 47, quantity inventory 38, identifier corrections 42, single payment 20,
two-role model 65, concurrency 15.
`tests/upgrade/role_migration.sh`: **29 checks, 0 failed**. `scripts/backup-drill.sh`: passed.
The GitHub Actions workflow has **not** run (no push access yet), so the PostgreSQL 17 matrix leg, `shellcheck`
and `supabase-local` are unverified.

## Upgrade checks

Role model: `tests/upgrade/role_migration.sh` (automated, see the table above).

Earlier, manual and one-off: migrations 0010-0018 on top of a database populated by the Task 1 test suite
(commit `ecc3277`): (a) with a legacy split payment present the upgrade stops with a readable error; (b) after merging that payment by
hand it completes, legacy data is back-filled, and `receive_purchase` + `finalize_sale` work afterwards (invoice
numbering continued at 000007). This is not automated in CI.

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
