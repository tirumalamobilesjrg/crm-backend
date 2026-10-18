# Security model

## Principles

1. **Database is the security boundary.** RLS is enabled on every table (a test fails if one is not). Frontend role
   checks are cosmetic.
2. **Deny by default.** Migration 0001 removes Supabase's default open grants; migration 0008 revokes everything
   from `anon`/`authenticated` and re-grants explicitly. Tests assert `anon` has zero privileges outside five views
   and cannot execute any function.
3. **Writes that must be consistent go through functions.** Ledger and financial tables have no INSERT/UPDATE/DELETE
   privilege for API roles at all.
4. **Secrets:** the service-role key bypasses RLS and is never needed by browser code. `.env.example` documents
   names only; `.gitignore` excludes `.env*`, `*.age`, keys and backups.

## Roles (exactly two: `admin`, `manager`; one per user, `staff_profiles.role`)

The `staff_role` enum has only these two values; the removed roles (owner, sales_executive, inventory_executive,
accountant) are not valid anywhere (`22P02`). The role is looked up from `staff_profiles` by `app.current_staff_role()`
on every request - never from a JWT claim.

Legend: **R** read, **W** direct write (RLS-checked), **F** via database function only, **-** no access.

| Data / action | Admin | Manager | anon |
|---|---|---|---|
| staff_profiles (accounts, roles, activation) | R, W | R | - |
| shop_settings | R, W | R | - |
| discount_policies (limits) | R, W | R | - |
| Grant discount approval (`grant_discount_approval`) | F | **denied** (`42501`, and a constraint forbids `can_approve` on Manager) | - |
| discount_approvals | R all | R own (granted to / by them) | - |
| audit_logs | R | **-** | - |
| brands, categories, products, variants, specs, images (incl. publishing, `public_price`) | R, W | R, W | - |
| suppliers, purchases (draft), purchase_items | R, W | R, W | - |
| Receive purchase (`receive_purchase`) | F | F | - |
| inventory_items, stock_levels, inventory_item_costs, stock_movements, stock_adjustments | R | R | - |
| Adjust stock (`adjust_stock`, `adjust_quantity_stock`) | F | F | - |
| Correct IMEI/serial (`correct_item_identifiers`), history table | F, R | F, R | - |
| customers | R, W, delete | R, W | - |
| sales, sale_items, invoices, invoice_items, payments | R | R | - |
| Sell (`finalize_sale`) | F | F | - |
| expenses | R, W, delete | R, W | - |
| public_catalogue_* views | R | R | **R** |
| idempotency_keys, inventory_identifiers, invoice_sequences | - (internal) | - | - |

Deactivated staff, users without a profile, and accounts that used to hold a removed role but have no profile now
have no access to anything (`app.current_staff_role()` returns NULL; every RPC raises `42501`). Master data can be deleted
by the roles that may write it, but foreign keys are `ON DELETE RESTRICT`, so anything referenced by a device, purchase
or sale cannot be removed; staff are deactivated, never deleted; discount policies cannot be deleted. **The last active
Admin cannot be demoted or deactivated** (`TM011`).

Three layers protect Admin-only actions: the RLS policy (Manager sees zero updatable rows or gets `42501` on insert),
a `BEFORE INSERT/UPDATE` trigger on `staff_profiles` that refuses any non-Admin session (`42501`), and for discount
approvals a check inside the function plus a table constraint. Mutation tests confirm that loosening only one of
the first two does not open the hole.

### Discount policy

`discount_policies` has one row per role. Columns: `can_discount`, `max_percent` (per line), `max_amount` (per sale,
NULL = no cap), `can_approve` (Admin only), `configured_by/at` (stamped when an Admin saves it through the API).
- Only an Admin can change it (audited with old and new values).
- **A Manager has no allowance until an Admin sets one.** The seeded Manager row is `can_discount=false, 0 %`,
  `configured_at IS NULL` ("never reviewed"). Every Manager discount then needs an Admin approval. There is no
  assumed final percentage, and unlimited Manager discounts are never enabled by default.
- The Admin row defaults to 100 % / no cap / may approve; that is also just configuration the Admin can tighten.
- An approval is single-use, expires (1-120 minutes), is capped, is bound to one seller and is re-validated at use
  (approver still an active Admin whose own per-line limit and cap still cover the discount).

### Reports (not built yet - rule for when they are)

Admin sees all business reports; Manager sees operational ones (sales, payments, stock, purchase cost, expenses,
customers) as already granted by the read policies above. Reports must be built as SECURITY INVOKER views or functions
that check `app.has_any_role(...)`, must not expose the audit log, staff, or policy tables to a Manager, and must be added to
`tests/db/02_rls_read_matrix.test.sql`.

These cells are asserted in `tests/db/02_rls_read_matrix.test.sql` (reads, all identities x all tables),
`tests/db/03_write_permissions.test.sql` and `tests/db/14_two_role_model.test.sql` (writes, RPC access, Admin-only powers,
removed roles, audit of sensitive actions by both roles).

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

Anonymous users can `SELECT` five views (four catalogue views and `public_shop_profile`). They are definer-rights views, so their safety is their column list and
`WHERE` clause (published product, active brand/category, active variant). Test 01 asserts the **exact** column
list of every view in `public`, and that they read no cost/customer/supplier/sales/staff table; test 09 asserts
behaviour. Never exposed: IMEI/serial, purchase cost, supplier, customer, stock counts, internal SKU, selling price
(only the explicitly approved `public_price`, which records its approver and cannot exceed the MRP). Supabase's database linter will flag these as "security definer views";
that is intentional.

## Known gaps and risks (be aware before go-live)

- Authentication hardening (MFA for Admin and Manager accounts, password policy, email provider) is a Supabase dashboard
  configuration, not code here. Not verified.
- Product images (migration 0021): the `product-images` bucket is public for reading by design (they are shown on the public website). Writing is limited to active Admin/Manager staff and to `products/<folder>/<file>` names; anon and non-staff logins can neither list nor write. Image files are not covered by the database backup scripts.
- Rate limiting of the anon key is Supabase's platform behaviour; the catalogue views are cheap but unthrottled here.
- A user with the database password or the service-role key can still do anything; keep both out of repos and browsers.
- `audit_logs` can contain customer PII (before/after images of `customers`); only an Admin can read it.
- `audit_logs` and `inventory_identifier_corrections` hold before/after values; both are append-only for every role,
  including the table owner, but a superuser can still disable triggers - treat database-superuser access as
  equivalent to full control.
- Discount approvals are only as trustworthy as the approver's account: protect Admin logins (Manager logins matter less here: only an Admin can approve) (MFA is a
  dashboard setting, unverified).
