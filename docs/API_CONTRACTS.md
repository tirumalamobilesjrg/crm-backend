# API contracts

The backend is Supabase: clients call PostgREST. Direct table access is governed by RLS (see SECURITY.md);
operations that must be atomic are database functions called as `POST /rest/v1/rpc/<name>` with the signed-in
user's JWT. All amounts are INR as JSON numbers with at most 2 decimals. All UUIDs are strings.

> **Verification status.** Contracts below are verified at the SQL level (`select public.<fn>(...)` under the
> `authenticated` role with JWT claims set). The PostgREST HTTP layer (status codes, error JSON, argument naming,
> schema cache) was **not** exercised. PostgREST normally returns database errors as JSON
> `{"code": "<SQLSTATE>", "message": "...", "details": ..., "hint": ...}`; custom `TMxxx` codes are expected to
> come back as HTTP 400 and `42501` as 401/403. Confirm against a real project before relying on status codes.

## Idempotency (all RPCs)

Every RPC takes `p_idempotency_key` (text, 8–128 chars). Generate one UUID per user *intent* (one "Complete sale"
button press) and **reuse it on retries**.

| Situation | Result |
|---|---|
| First call | does the work, stores the response, `"replayed": false` |
| Same key, same user, same arguments | returns the stored response with `"replayed": true`; no side effects |
| Same key, same user, different arguments | error `TM002` |
| Same key while the first call is still running | waits, then behaves as above |
| Call failed (any error) | nothing is stored, the key may be reused for a corrected retry |
| Same key, different user | independent (keys are per user and per function) |

## Error codes (SQLSTATE)

| Code | Meaning |
|---|---|
| `42501` | not permitted (no staff profile, deactivated, role not allowed, no privilege) |
| `22P02` | also returned when a removed role name is supplied for `staff_role` |
| `TM002` | idempotency key reused with different arguments |
| `TM003` | invalid request (shape, missing field, bad value; for `finalize_sale` also a unit price above the variant's MRP) |
| `TM004` | device unavailable / insufficient stock / invalid stock transition |
| `TM005` | discount not authorised (over limit, bad/used/expired approval, ineligible approver) |
| `TM006` | payment amount does not equal the sale total |
| `TM007` | purchase in the wrong state |
| `TM010` | row is append-only / protected from direct change |
| `TM011` | cannot demote or deactivate the last active Admin |
| `TM012` | commit-time integrity check failed (incomplete sale or device) |
| `TM013` | wrong SKU tracking mode |
| `TM020` | (migration only) unsupported legacy staff roles - see ROLE_MIGRATION.md |
| `23505` | duplicate (IMEI/serial, customer phone, supplier invoice, invoice number…) |
| `23514` | check constraint (bad IMEI check digit, negative amount, …) |
| `22P02` | malformed UUID / enum / number |

## `rpc/finalize_sale` — roles: Admin, Manager

```
p_idempotency_key text
p_customer_id     uuid | null          -- null = walk-in
p_items           jsonb array (1..50)
p_payment         jsonb object          -- exactly one payment
p_notes           text | null
p_discount_reason text | null           -- required (>= 3 chars) when any discount > 0
p_discount_approval_id uuid | null      -- see grant_discount_approval
```
Line shapes (discount is for the whole line; `unit_price` > 0, max 2 decimals):
```json
{"inventory_item_id": "<uuid>", "unit_price": 70000, "discount_amount": 1000}          // phone/serialized, quantity is always 1
{"variant_id": "<uuid>", "quantity": 2, "unit_price": 799, "discount_amount": 0}      // accessory/quantity SKU
```
Payment (anything other than these keys is rejected; arrays are rejected — no split payments):
```json
{"method": "cash|upi|card|bank_transfer|cheque", "amount": 66598, "reference": "optional free text"}
```
`amount` must equal Σ(unit_price × quantity − discount_amount) exactly (`TM006` otherwise).

**Price ceiling (migration 0020).** Each line's `unit_price` must be **at most the variant's MRP** (`product_variants.mrp`,
read at sale time). A price above it is rejected with `TM003` and a message of the form
`line 2: unit price 72000.01 is above the MRP 72000.00 for SKU NOVA-X1-8-128-BLK`; the whole request fails and
nothing is written (no sale, movement, audit row or invoice number is consumed, and the idempotency key may be
reused with a corrected price). The check is on the per-unit price *before* discount, so a discount cannot be used to
offset an over-MRP price. A price equal to the MRP is accepted.

**A price below the variant's selling price is a discount (migration 0023).** `app.sale_lines` restates such a line as `unit_price = selling_price` with the shortfall added to the line discount, so a reason, the role's allowance or an Admin approval is required, and the invoice shows the catalogue price plus the discount. Typing a low price is therefore never a way around the discount rules. A price above the selling price (up to the MRP) is not a discount. The payment must still equal the total the client computed from its own unit price and discount (the total is unchanged by the restatement).
Applies to Admin and Manager alike; past sales are not re-checked. A client should still validate against the MRP
it shows to the user, since the database is the final check.

Returns `{"sale_id","invoice_id","invoice_number","total","discount_total","replayed"}`.

Effects (one transaction): locks devices and SKU balances in a stable order; validates availability, prices, the
role's discount policy or the supplied approval; inserts `sales`, `sale_items`, `invoices` (shop/customer snapshot),
`invoice_items`, one `payments` row, one `stock_movements` row per line, one audit entry; marks the approval used.
Commit-time triggers re-verify completeness. Error cases: `42501`, `TM002`, `TM003` (including price above MRP), `TM004`, `TM005`, `TM006`, `TM013`.

## `rpc/receive_purchase` — Admin, Manager

```
p_idempotency_key text, p_purchase_id uuid, p_units jsonb array
```
`p_units`: one element per **serialized** device:
`{"purchase_item_id","imei1"?,"imei2"?,"serial_number"?,"condition"?,"shelf_location"?}`; at least one of `imei1`/`serial_number`.
Quantity SKU lines take **no** units (use `[]` for accessory-only purchases) and are received in full.
Returns `{"purchase_id","units_received","quantity_lines_received","quantity_units_received","replayed"}`.
Errors: `TM003` (wrong unit counts, foreign line), `TM007` (not a draft / no lines), `23505` (duplicate IMEI/serial), `23514` (bad IMEI).

## `rpc/adjust_stock` — Admin, Manager (serialized devices)

```
p_idempotency_key text, p_inventory_item_id uuid, p_reason 'damaged'|'lost'|'found'|'repaired'|'returned_to_supplier', p_notes text (>= 3)
```
Allowed: in_stock → damaged|lost|returned_to_supplier; damaged → in_stock (`repaired`)|returned_to_supplier; lost → in_stock (`found`).
Sold devices and `returned_to_supplier` are terminal here. Returns `{"adjustment_id","from_status","to_status","replayed"}`. Errors: `TM003`, `TM004`.

## `rpc/adjust_quantity_stock` — Admin, Manager (accessory SKUs)

```
p_idempotency_key text, p_variant_id uuid, p_quantity_delta int (non-zero), p_reason adjustment_reason, p_notes text (>= 3)
```
Sign rules: `damaged`/`lost`/`returned_to_supplier` negative; `found` positive; `correction` either; `repaired` not allowed.
Never drives stock below zero (`TM004`). Returns `{"adjustment_id","balance_after","replayed"}`.

## `rpc/grant_discount_approval` — Admin only

```
p_idempotency_key text, p_requested_for uuid, p_max_amount numeric (> 0, cap on the discount of the approved item),
p_reason text (>= 3), p_valid_minutes int default 15 (1..120),
p_inventory_item_id uuid default null,   -- EXACTLY ONE of these two (migration 0025):
p_variant_id uuid default null           --   a phone that is in stock, or an active accessory product
```
**Item-bound (0025).** An approval is for the one phone or accessory product it names. `finalize_sale` accepts it only for a sale that contains that item (`TM005` "different item" otherwise), measures the approved amount against the discount on THAT item only, and requires any discount on other items in the cart to fit the seller's own allowance (`TM005` "other items"). Approvals granted before 0025 have no item and cannot be used. Single use, expiry, approver authority and auditing are unchanged.
The caller must be an Admin whose policy has `can_approve` (a Manager is refused with `42501`, and the database
forbids `can_approve` on the Manager policy). The target must be an active staff member (an Admin or a Manager) - it
does **not** need its own discount allowance, which is exactly when approvals matter; self-approval is refused; the
amount may not exceed the approver's own per-sale cap. At use time the approval is checked again: right seller, unused, unexpired,
discount ≤ `max_amount`, approver still active and authorised, and each line within the approver's per-line percent.
Returns `{"approval_id","expires_at","replayed"}`.

## `rpc/correct_item_identifiers` — Admin, Manager

```
p_idempotency_key text, p_inventory_item_id uuid, p_changes jsonb, p_reason text (>= 10)
```
`p_changes` has any of `imei1`, `imei2`, `serial_number`; a JSON `null` clears that value; omitted keys are untouched.
New values are validated (15-digit IMEI with check digit; serial `[A-Z0-9-]{4,40}`, upper-cased) and must not be
active on any other device (`23505`). Allowed in any stock status. Old values are retired, not deleted; a
correction record and audit entry are written; stock status and issued invoices are unaffected.
Returns `{"correction_id","inventory_item_id","replayed"}`.

## Direct table access (RLS-checked)

| Resource | Read | Write |
|---|---|---|
| staff_profiles | Admin, Manager (all rows) | **Admin only**: insert (create account), update (`role` in `admin`/`manager`, `is_active`, name). The last active Admin cannot be demoted/deactivated (`TM011`). A Manager's attempt returns `42501` (insert) or affects 0 rows (update). Removed role names fail with `22P02`. Rows are never deleted. |
| shop_settings | Admin, Manager | **Admin only** (update the single row) |
| discount_policies | Admin, Manager | **Admin only** (update; one row per role; `can_approve` only on `admin`) |
| brands, categories, products, product_variants, specifications, images | Admin, Manager | Admin, Manager (publishing a product and setting `public_price` included) |
| suppliers, purchases, purchase_items | Admin, Manager | Admin, Manager - drafts only; `status` may go draft -> cancelled; receiving only via RPC |
| customers | Admin, Manager | insert/update: Admin, Manager; delete: **Admin** |
| expenses | Admin, Manager | insert/update: Admin, Manager; delete: **Admin** |
| audit_logs | **Admin only** | never directly |
| discount_approvals | Admin: all; Manager: those granted to or by them | never directly |
| stock_levels, inventory_items, inventory_item_costs, stock_movements, stock_adjustments, inventory_identifier_corrections, sales, sale_items, invoices, invoice_items, payments | Admin, Manager | **never directly** |

Staff management example (Admin session):
```http
POST /rest/v1/staff_profiles     {"user_id": "<auth user uuid>", "full_name": "A. Kumar", "role": "manager"}
PATCH /rest/v1/staff_profiles?user_id=eq.<uuid>    {"role": "admin"}      {"is_active": false}
PATCH /rest/v1/discount_policies?role=eq.manager   {"can_discount": true, "max_percent": 10, "max_amount": 5000}
```
The auth user must exist first (created in Supabase Auth); self sign-up is disabled.

Creating a quantity SKU: insert into `product_variants` with `"tracking_mode": "quantity"` (default `serialized`).

## Product images (Supabase Storage, migration 0021)

Bucket `product-images`: **public read** (the website uses the public object URL `<project>/storage/v1/object/public/product-images/<storage_path>`, no login),
2 MiB limit, JPEG / PNG / WebP only (enforced by Storage). Object names must be `products/<folder>/<file>`, where `<folder>` is a product id or slug and `<file>` a plain
name (letters, digits, `.`, `_`, `-`; no slashes, no `..`).

| Who | List | Upload / replace | Delete |
|---|---|---|---|
| Admin, Manager (active staff) | yes | yes | yes |
| anon, a login without a staff profile, a deactivated staff member | no | no | no |

Workflow for a client: upload the file to `products/<product id>/<random>.<ext>`, then insert a `product_images` row (`product_id`, `storage_path` = the object name, `alt_text`,
`sort_order`, `is_primary`). To remove: delete the object, then the row. `product_images.storage_path` must follow the same layout (check constraint, `23514` otherwise) and be unique.
Bucket settings themselves cannot be changed from the API. Image files are **not** included in `scripts/backup.sh` (it dumps the database only).

## Public catalogue (anon key, read-only)

| View | Columns |
|---|---|
| `public_catalogue_products` | id, slug, name, brand_name, brand_slug, category_name, category_slug, description, published_at, updated_at, availability |
| `public_catalogue_variants` | id, product_slug, color, ram_gb, storage_gb, public_price, availability |
| `public_catalogue_images` | id, product_slug, storage_path, alt_text, sort_order, is_primary |
| `public_catalogue_specifications` | id, product_slug, group_name, spec_key, spec_value, sort_order |

`availability` ∈ `in_stock` | `out_of_stock`. `public_price` is null when no approved price exists ("contact the shop").
There are no offer, discount, cost, margin, stock-count, IMEI, supplier or customer fields, and none will be added.

## Public shop profile (anon key, read-only, migration 0022)

| View | Columns |
|---|---|
| `public_shop_profile` | shop_name, address, phone, whatsapp, email, opening_hours, map_url, about |

One row (the `shop_settings` singleton). An Admin edits these fields in the CRM Settings page; `map_url` must be an `https://` link. Empty fields are `NULL`
and the website hides what is missing. `legal_name`, `invoice_prefix`, `currency` and every other `shop_settings` column are **not** exposed.

## Who may change prices and sold-phone identifiers (migration 0024)

- `product_variants.mrp`, `selling_price` and `public_price` can be inserted or changed only by an **Admin** (error `42501`, "only an Admin can set or change prices"). Managers can read them, publish/unpublish products, edit products and other variant fields, and receive stock into existing variants. Creating a variant needs prices, so it is an Admin action.
- `rpc/correct_item_identifiers` on a phone whose status is `sold` is Admin-only (`42501`); in-stock phones can still be corrected by a Manager.
- Indexes `invoices_issued_at_idx` and `invoices_customer_idx` back the sales list, reports and customer history.
