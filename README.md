# Tirumala Mobiles — CRM backend

Database foundation (Supabase / PostgreSQL) shared by the CRM (`crm-frontend`) and the public website
(`public-website`). **This repository owns every schema change, migration, RLS policy and database test.**
The other two repositories only consume it.

| Concern | Where |
|---|---|
| Schema, RLS, business functions | `supabase/migrations/` (applied in filename order) |
| Database tests (RLS, IMEI, transactions) | `tests/db/`, run by `scripts/test-db.sh` |
| Backup / restore tooling | `scripts/backup.sh`, `scripts/restore-check.sh`, `scripts/backup-drill.sh` |
| Documentation | `docs/` |

## Status

Tasks 1, 1B and the two-role simplification (foundation + finalized shop rules + Admin/Manager). There is no application server: clients talk to Supabase's Data
API (PostgREST) and call database functions for the operations that must be transactional. Not yet built: the CRM
UI, the website, returns/voids/refunds, image storage policies. Out of scope by decision: GST/tax, online
payments, split payments, credit/EMI.
See [docs/SCHEMA_DECISIONS.md](docs/SCHEMA_DECISIONS.md) for decisions and open questions,
[docs/API_CONTRACTS.md](docs/API_CONTRACTS.md) for the client contract and
[docs/TESTING.md](docs/TESTING.md) for what is and is not verified.

## Domain model in one paragraph

A **product** is a model ("Nova X1") that the website describes. A **variant** is a sellable SKU of that
model (colour / RAM / storage) with its prices and a `tracking_mode`: `serialized` for phones, `quantity` for
accessories. A serialized variant has one **inventory item** per physical device (own IMEI(s)/serial and a status:
`in_stock`, `sold`, `damaged`, `lost`, `returned_to_supplier`); a quantity variant has one `stock_levels.on_hand`
number. Both change only by appending to the `stock_movements` ledger. Acquisition cost of devices lives in a
separate table (`inventory_item_costs`) so it can have stricter access than the device record.

## Roles (exactly two)

| Role | Can |
|---|---|
| **Admin** | Everything a Manager can, plus: create staff accounts and assign roles, change shop settings, configure discount policies (including the Manager's limits), approve exceptional discounts, read the audit log, delete customers and expenses. |
| **Manager** | Manage and **publish** products, receive purchases, manage inventory and stock adjustments, perform audited IMEI corrections, create POS sales and invoices, manage customers, record expenses, read operational data (sales, stock, costs, expenses). Cannot create or promote staff, change roles, change discount policies, shop settings or other security settings, approve discounts, or read the audit log. |

The removed roles (owner, sales executive, inventory executive, accountant) cannot be assigned or used.
Migration from the five-role model: [docs/ROLE_MIGRATION.md](docs/ROLE_MIGRATION.md). Checks live in the database
(RLS policies, triggers and function bodies), never only in the frontend.

## Write paths

| Operation | How | Who |
|---|---|---|
| Catalogue (incl. publishing), suppliers, draft purchases, customers, expenses | direct table writes, RLS-checked | Admin, Manager (deleting customers/expenses: Admin) |
| Staff accounts and roles, shop settings, discount policy | direct table writes, RLS-checked | **Admin only** |
| Receive a purchase (devices by IMEI/serial, accessories by quantity) | `rpc/receive_purchase` | Admin, Manager |
| Adjust stock (device status / accessory quantity) | `rpc/adjust_stock`, `rpc/adjust_quantity_stock` | Admin, Manager |
| Correct an IMEI/serial (audited, history kept) | `rpc/correct_item_identifiers` | Admin, Manager |
| Sell (sale, invoice, one payment, movements, audit) | `rpc/finalize_sale` | Admin, Manager |
| Approve a discount above someone's limit | `rpc/grant_discount_approval` | **Admin only** |

All RPCs take an **idempotency key** (8-128 chars, generated once per user action by the client and reused on
retry). Everything else that touches stock, sales, invoices, payments, approvals or audit logs is blocked at the
privilege level. Exact argument shapes and errors: [docs/API_CONTRACTS.md](docs/API_CONTRACTS.md).

## Run the tests

```bash
# PostgreSQL 16/17 server reachable via PG* variables (superuser needed to create the test database)
export PGHOST=localhost PGUSER=postgres PGPASSWORD=...
scripts/test-db.sh
```

The script creates a fresh database, emulates the Supabase roles/auth schema, applies every migration, runs
`tests/db/*.test.sql` and `tests/db/concurrency.sh`, and exits non-zero on any failed assertion.
`tests/upgrade/role_migration.sh` separately tests migration 0019 against legacy five-role data.
CI (`.github/workflows/ci.yml`) is configured to run both on PostgreSQL 16 and 17 plus a backup/restore drill
(it has not run yet: the repository has not been pushed).

## Environment variables

Names and purpose only, in [.env.example](.env.example). **The Supabase service-role key bypasses RLS and must
never be placed in browser code or in any `NEXT_PUBLIC_*` / `VITE_*` variable.** This repository does not need it.

## Documentation

- [Architecture and zero-cost deployment](docs/ARCHITECTURE.md)
- [Security model and role matrix](docs/SECURITY.md)
- [Schema decisions (decided and still open)](docs/SCHEMA_DECISIONS.md)
- [API contracts](docs/API_CONTRACTS.md)
- [Acceptance tests](docs/ACCEPTANCE_TESTS.md)
- [Role migration (five roles to Admin/Manager)](docs/ROLE_MIGRATION.md)
- [Testing and Supabase differences](docs/TESTING.md)
- [Operations: migrations, backups, restore](docs/OPERATIONS.md)
