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

Task 1 (foundation) only. There is no application server: clients talk to Supabase's Data API (PostgREST)
and call three database functions for the operations that must be transactional. Not yet built: the
CRM UI, the website, returns/voids, credit sales, non-serialised stock, image storage policies.
See [docs/SCHEMA_DECISIONS.md](docs/SCHEMA_DECISIONS.md) for open questions and
[docs/TESTING.md](docs/TESTING.md) for what is and is not verified.

## Domain model in one paragraph

A **product** is a model ("Nova X1") that the website describes. A **variant** is a sellable SKU of that
model (colour / RAM / storage) with GST rate and prices. An **inventory item** is one physical device with its
own IMEI(s) or serial number and a status (`in_stock`, `sold`, `damaged`, `lost`, `returned_to_supplier`).
Status changes only by appending to the `stock_movements` ledger. Acquisition cost lives in a separate table
(`inventory_item_costs`) so it can have stricter access than the device record.

## Write paths

| Operation | How | Who |
|---|---|---|
| Catalogue, suppliers, draft purchases, customers, expenses | direct table writes, RLS-checked | see [docs/SECURITY.md](docs/SECURITY.md) |
| Receive a purchase (creates devices, costs, movements) | `rpc/receive_purchase` | owner, manager, inventory executive |
| Adjust stock (damaged / lost / found / repaired / returned to supplier) | `rpc/adjust_stock` | owner, manager, inventory executive |
| Sell devices (sale, invoice, payments, movements, audit) | `rpc/finalize_sale` | owner, manager, sales executive |

All three take an **idempotency key** (8–128 chars, generated once per user action by the client and reused on retry).
Everything else that touches stock, sales, invoices, payments or audit logs is blocked at the privilege level.

## Run the tests

```bash
# PostgreSQL 16/17 server reachable via PG* variables (superuser needed to create the test database)
export PGHOST=localhost PGUSER=postgres PGPASSWORD=...
scripts/test-db.sh
```

The script creates a fresh database, emulates the Supabase roles/auth schema, applies every migration, runs
`tests/db/*.test.sql` and `tests/db/concurrency.sh`, and exits non-zero on any failed assertion.
CI (`.github/workflows/ci.yml`) does the same on PostgreSQL 16 and 17 plus a backup/restore drill.

## Environment variables

Names and purpose only, in [.env.example](.env.example). **The Supabase service-role key bypasses RLS and must
never be placed in browser code or in any `NEXT_PUBLIC_*` / `VITE_*` variable.** This repository does not need it.

## Documentation

- [Architecture and zero-cost deployment](docs/ARCHITECTURE.md)
- [Security model and role matrix](docs/SECURITY.md)
- [Schema decisions that need your confirmation](docs/SCHEMA_DECISIONS.md)
- [Testing and Supabase differences](docs/TESTING.md)
- [Operations: migrations, backups, restore](docs/OPERATIONS.md)
