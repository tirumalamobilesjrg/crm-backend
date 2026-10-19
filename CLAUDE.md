# CLAUDE.md — crm-backend

Database foundation for Tirumala Mobiles on Supabase/PostgreSQL. **This repo owns every schema change, migration, RLS policy and DB test.**
No application server: clients (the `crm-frontend` CRM, later the `public-website`) call Supabase's REST API and database functions.

## Layout
`supabase/migrations/` (applied in filename order, 0001..0024) · `tests/db/*.test.sql` + `concurrency.sh` · `tests/upgrade/role_migration.sh` ·
`scripts/test-db.sh` (run all DB tests) · `scripts/backup*.sh`, `restore-check.sh` · `docs/` (ARCHITECTURE, SECURITY, API_CONTRACTS, SCHEMA_DECISIONS, ROLE_MIGRATION, TESTING, OPERATIONS).

## Non-negotiable rules
- **Never edit a migration that has been applied** (the hosted project has 0001–0024 (0001–0022 applied 2026-10-19 after a schema+data dump, 0023–0024 later the same day after a second dump)). Add a new forward migration instead.
- Every new table: enable RLS, grant explicitly (default is deny; `anon`/`authenticated` get nothing by default), add policies, and add it to the
  RLS read matrix (`tests/db/02_rls_read_matrix.test.sql`). Test 01 fails if RLS is missing or anon gains access.
- Stock, sales, invoices, payments, approvals, audit logs change ONLY through the SECURITY DEFINER functions (`finalize_sale`, `receive_purchase`,
  `adjust_stock`, `adjust_quantity_stock`, `correct_item_identifiers`, `grant_discount_approval`). Direct writes are not granted. Definer functions pin `search_path = ''`.
- Public website surface = only the four `public_catalogue_*` views plus `public_shop_profile` (exact column lists are asserted by tests). Never expose IMEI, cost, margin, customer or stock counts.
- Role checks live in the database (RLS + function bodies + triggers). Roles come from `staff_profiles`, never from the JWT.

## Decided business rules
Two roles only (Admin, Manager; removed roles cannot be assigned — migration 0019, remediation in docs/ROLE_MIGRATION.md). Serialized phones + quantity accessories,
append-only stock ledger, gapless invoice numbers, **no GST/tax**, **exactly one manual payment per sale equal to the total**, discounts via Admin-managed
`discount_policies` (Manager has no allowance until configured) and single-use Admin approvals, audited IMEI corrections with history, explicit approved `public_price`, a sale line's unit price may not exceed the variant's MRP (migration 0020, `TM003`), a unit price below the selling price is restated as a discount (migration 0023: typing a low price never bypasses the discount rules), **prices (MRP, selling price, website price) are set and changed only by an Admin** (migration 0024; Managers can still publish, edit products and receive stock), the IMEI/serial of a SOLD phone is corrected only by an Admin (0024), and product photos live in the public `product-images` Storage bucket writable only by active staff (migration 0021).

## Commands
`scripts/test-db.sh` (needs PostgreSQL 16/17 + `psql`; PG* env vars; use Git Bash/WSL on Windows) · `tests/upgrade/role_migration.sh` · `shellcheck scripts/*.sh tests/db/concurrency.sh tests/upgrade/role_migration.sh`.
Last recorded: 764 assertions pass, role migration 29 checks pass, CI green on GitHub (PostgreSQL 16 and 17, backup drill, shellcheck).
Apply to hosted project (manual, owner only): `supabase link`, `supabase db push --dry-run`, then `supabase db push`. Take a backup first.

## Known gaps / ideas
No returns/voids/refunds; no partial purchase receipts; no weighted-average accessory cost; image files are not in the database backups; PostgREST/HTTP behaviour was only
verified manually; backups are not scheduled or off-platform.

## Working agreements
Never commit secrets (`.env*` is git-ignored). Never put the service_role/secret key in any browser-facing repo. Do not touch the hosted database without the owner's say-so.
If you change behaviour, update `docs/API_CONTRACTS.md` and the tests in the same commit.
