# Security model

## Principles

1. **Database is the security boundary.** RLS is enabled on every table (a test fails if one is not). Frontend role
   checks are cosmetic.
2. **Deny by default.** Migration 0001 removes Supabase's default open grants; migration 0008 revokes everything
   from `anon`/`authenticated` and re-grants explicitly. Tests assert `anon` has zero privileges outside four views
   and cannot execute any function.
3. **Writes that must be consistent go through functions.** Ledger and financial tables have no INSERT/UPDATE/DELETE
   privilege for API roles at all.
4. **Secrets:** the service-role key bypasses RLS and is never needed by browser code. `.env.example` documents
   names only; `.gitignore` excludes `.env*`, `*.age`, keys and backups.

## Roles (one per user, `staff_profiles.role`)

Legend: **R** read all, **r** read own only, **W** direct write, **F** via function only, **–** no access.

| Data | owner | manager | sales_executive | inventory_executive | accountant | anon |
|---|---|---|---|---|---|---|
| shop_settings | R, W | R | R | R | R | – |
| staff_profiles | R, W | R | r | r | r | – |
| audit_logs | R | R | – | – | – | – |
| brands, categories, products, variants, specs, images | R, W | R, W | R | R, W | R | – |
| Publish product / set public price | yes | yes | no | no | no | – |
| suppliers, purchases (draft), purchase_items | R, W | R, W | – | R, W | R | – |
| Receive purchase (`receive_purchase`) | F | F | – | F | – | – |
| inventory_items (IMEI, status, no cost) | R | R | R | R | R | – |
| inventory_item_costs, stock_movements, stock_adjustments | R | R | – | R | R | – |
| Adjust stock (`adjust_stock`) | F | F | – | F | – | – |
| customers | R, W | R, W | R, W | – | R | – |
| sales, sale_items, invoices, invoice_items, payments | R | R | r (own sales) | – | R | – |
| Sell (`finalize_sale`) | F | F | F (discount ≤ `max_sales_exec_discount_pct`, default 5 %) | – | – | – |
| expenses | R, W | R, W | – | – | R, W | – |
| public_catalogue_* views | R | R | R | R | R | **R** |
| idempotency_keys, inventory_identifiers, invoice_sequences | – (internal) | | | | | |

Deactivated staff and authenticated users without a profile have no access to anything (`app.current_staff_role()`
returns NULL). Master data (catalogue, suppliers, draft purchases) can be deleted by the roles that may write it, but foreign keys are `ON DELETE RESTRICT`, so anything referenced by a device, purchase or sale cannot be removed; customers and expenses are deletable only by the owner (customers referenced by sales/invoices are protected by the same FKs); staff are deactivated, never deleted.
The last active owner cannot be demoted or deactivated.

These cells are asserted in `tests/db/02_rls_read_matrix.test.sql` (reads, all roles × all tables) and
`tests/db/03_write_permissions.test.sql` (writes and RPC access).

## Public catalogue exposure

Anonymous users can `SELECT` four views. They are definer-rights views, so their safety is their column list and
`WHERE` clause (published product, active brand/category, active variant). Test 01 asserts the **exact** column
list of every view in `public`, and that they read no cost/customer/supplier/sales/staff table; test 09 asserts
behaviour. Never exposed: IMEI/serial, purchase cost, supplier, customer, stock counts, internal SKU, selling price
(only the explicitly set `public_price`). Supabase's database linter will flag these as "security definer views";
that is intentional.

## Known gaps and risks (be aware before go-live)

- Authentication hardening (MFA for owner/manager, password policy, email provider) is a Supabase dashboard
  configuration, not code here. Not verified.
- Image storage bucket policies (Supabase Storage) are not defined yet; `product_images.storage_path` is metadata only.
- Rate limiting of the anon key is Supabase's platform behaviour; the catalogue views are cheap but unthrottled here.
- A user with the database password or the service-role key can still do anything; keep both out of repos and browsers.
- `audit_logs` can contain customer PII (before/after images of `customers`); only owner/manager can read it.
- IMEI typo correction has no workflow (identity is immutable): needs a deliberate owner-only procedure, see
  SCHEMA_DECISIONS.md.
