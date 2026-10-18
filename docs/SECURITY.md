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
| inventory_items (IMEI, status, no cost), stock_levels | R | R | R | R | R | – |
| inventory_item_costs, stock_movements, stock_adjustments | R | R | – | R | R | – |
| Adjust stock (`adjust_stock`, `adjust_quantity_stock`) | F | F | – | F | – | – |
| Correct IMEI/serial (`correct_item_identifiers`) | F | F | – | – | – | – |
| inventory_identifier_corrections (history) | R | R | – | R | R | – |
| customers | R, W | R, W | R, W | – | R | – |
| sales, sale_items, invoices, invoice_items, payments | R | R | r (own sales) | – | R | – |
| Sell (`finalize_sale`) | F | F | F | – | – | – |
| discount_policies (limits) | R, W | R | R | R | R | – |
| Grant discount approval (`grant_discount_approval`) | F (if `can_approve`) | F (if `can_approve`) | – | – | – | – |
| discount_approvals | R | R | r (own) | r (own) | R | – |
| expenses | R, W | R, W | – | – | R, W | – |
| public_catalogue_* views | R | R | R | R | R | **R** |
| idempotency_keys, inventory_identifiers, invoice_sequences | – (internal) | | | | | |

Deactivated staff and authenticated users without a profile have no access to anything (`app.current_staff_role()`
returns NULL). Master data (catalogue, suppliers, draft purchases) can be deleted by the roles that may write it,
but foreign keys are `ON DELETE RESTRICT`, so anything referenced by a device, purchase or sale cannot be removed;
customers and expenses are deletable only by the owner (customers referenced by sales/invoices are protected by the
same FKs); staff are deactivated, never deleted; discount policies cannot be deleted. The last active owner cannot be
demoted or deactivated.

What the discount cells mean: *whether* a user may discount, *how much*, and *who may approve more* is data in
`discount_policies`, editable only by the owner and audited; the sale function reads it on every sale. Nothing about
5 %, 20 % or any other number is hardcoded in functions or policies.

These cells are asserted in `tests/db/02_rls_read_matrix.test.sql` (reads, all roles x all tables) and
`tests/db/03_write_permissions.test.sql` (writes and RPC access).

## Money-handling controls (Task 1B)

- **One manually recorded payment per sale**, equal to the total, enforced by `finalize_sale`, a unique index on
  `payments(sale_id)` and the commit-time completeness trigger. The system never claims a payment was verified:
  `payments.entry_source` is always `manual`; `reference` is unverified free text. No gateway, webhook or card
  processing exists, and a test asserts no gateway/verification/EMI/credit columns appear.
- **Discounts** are validated in the database against the seller's policy or a single-use approval; the authoriser,
  basis and reason are stored on the sale and in the audit log; policy changes are audited with before/after values.
- **Stock** (devices and accessories) changes only by appending ledger rows; accessory balances cannot go negative.
- **No tax calculations** exist, so none can be wrong; invoices do not claim to be statutory tax invoices.

## Public catalogue exposure

Anonymous users can `SELECT` four views. They are definer-rights views, so their safety is their column list and
`WHERE` clause (published product, active brand/category, active variant). Test 01 asserts the **exact** column
list of every view in `public`, and that they read no cost/customer/supplier/sales/staff table; test 09 asserts
behaviour. Never exposed: IMEI/serial, purchase cost, supplier, customer, stock counts, internal SKU, selling price
(only the explicitly approved `public_price`, which records its approver and cannot exceed the MRP). Supabase's database linter will flag these as "security definer views";
that is intentional.

## Known gaps and risks (be aware before go-live)

- Authentication hardening (MFA for owner/manager, password policy, email provider) is a Supabase dashboard
  configuration, not code here. Not verified.
- Image storage bucket policies (Supabase Storage) are not defined yet; `product_images.storage_path` is metadata only.
- Rate limiting of the anon key is Supabase's platform behaviour; the catalogue views are cheap but unthrottled here.
- A user with the database password or the service-role key can still do anything; keep both out of repos and browsers.
- `audit_logs` can contain customer PII (before/after images of `customers`); only owner/manager can read it.
- `audit_logs` and `inventory_identifier_corrections` hold before/after values; both are append-only for every role,
  including the table owner, but a superuser can still disable triggers - treat database-superuser access as
  equivalent to full control.
- Discount approvals are only as trustworthy as the approver's account: protect owner/manager logins (MFA is a
  dashboard setting, unverified).
