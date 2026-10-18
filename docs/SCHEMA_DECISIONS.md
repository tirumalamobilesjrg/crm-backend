# Schema decisions

Status after the two-role simplification (migration 0019). "Decided" items were fixed by the business owner; "Open" items are still defaults that need
confirmation. Nothing here is deployed.

## Decided (two-role model)

| Area | Decision | Where it lives |
|---|---|---|
| Roles | **Exactly two staff roles: `admin` and `manager`.** One role per user. The previous owner/sales_executive/inventory_executive/accountant roles are removed from the enum, policies, functions, tests and docs. `owner` maps to `admin` on migration; the other three are never auto-mapped (the migration refuses and lists them). | `staff_role` enum, migration 0019, docs/ROLE_MIGRATION.md |
| Admin | Staff accounts and roles, shop settings, discount policies, approving exceptional discounts, audit log, deleting customers/expenses, plus everything a Manager can do. | RLS policies, `guard_staff_changes`, `grant_discount_approval` |
| Manager | Products (incl. publishing and the approved public price), purchases and receiving, inventory and stock adjustments, audited IMEI corrections, POS sales and invoices, customers, expenses, read access to operational data. **Not**: staff/roles, shop settings, discount policy, approving discounts, audit log. | RLS policies, function role checks |
| Enforcement | Role checks live in RLS policies, SECURITY DEFINER function bodies and triggers, and use the role stored in `staff_profiles` - never a JWT claim or the frontend. | tests 02, 03, 14 |
| Audit | Sensitive actions by both roles are audited with actor id and role (`audit_logs.actor_role` is text so history keeps whatever role name was true at the time). | `audit_row`, explicit audit entries in functions; test 14 |
| Manager discounts | **No allowance by default.** The Manager policy is configuration set by an Admin; until then every Manager discount needs an Admin approval. Unlimited Manager discounts are never the default, and no final percentage is assumed. The Admin saving the row stamps `configured_by/at`. | `discount_policies`, migration 0019 |
| Manager approval right | Managers can never approve discounts (function check + table constraint). | `discount_policy_manager_no_approve` |

## Decided (Task 1B)

| Area | Decision | Where it lives |
|---|---|---|
| Inventory | Serialized phones (IMEI/serial per device) **and** non-serialized accessories (quantity per SKU). A SKU's `tracking_mode` is `serialized` or `quantity`, fixed once the SKU has any purchase, stock or sale history. | `product_variants.tracking_mode`; `inventory_items`, `stock_levels` |
| Stock history | Receiving, selling and adjusting always append a `stock_movements` row (per device with statuses, or per SKU with a signed `quantity_delta` and `balance_after`). Stock and status cannot change any other way. | `stock_movements`, triggers in 0005/0012 |
| Overselling | Quantity SKUs: balance locked and decremented in the same statement, never below zero. Devices: row-locked, `in_stock` → `sold` once. | 0012, 0016; concurrency tests E, A |
| IMEI corrections | Controlled and audited: Admin or Manager, reason ≥ 10 chars, duplicate-checked against all *active* identifiers, old values retired not deleted, correction record + audit entry, invoices keep what they issued. | `correct_item_identifiers`, `inventory_identifiers` (history), `inventory_identifier_corrections` |
| Payments | Physical shop only. **Exactly one payment per sale**, recorded manually, amount must equal the sale total. No split, credit, EMI, gateway, or verification. `payments.entry_source` is always `manual`; `reference` is free text. | `payments` (unique per sale), `finalize_sale`, 0013 |
| Payment methods | `cash`, `upi`, `card`, `bank_transfer`, `cheque` are *labels for what the customer handed over*. `card` means a payment taken on the shop's own terminal and typed in afterwards; nothing is processed or verified here. | `payment_method` enum |
| Tax | **No GST or any tax calculation or breakdown.** Columns for tax, HSN and GSTIN were removed. Prices are plain selling prices; `total = sum(unit_price × qty) − discounts`. Invoices make no statutory claim. | migration 0011; test 01 asserts no tax-like column exists |
| Discounts | Per-role policy rows (`can_discount`, `max_percent` per line, optional `max_amount` per sale, `can_approve`). Over-limit discounts need a single-use, expiring, capped approval from an authorised approver. Every discounted sale stores amount, basis (`role_limit`/`manager_approval`), authorising user, approval id and reason. Enforced in the database, audited. | `discount_policies`, `discount_approvals`, `sales.discount_*` |
| Public price | `product_variants.public_price` is the only price the website can see. Admin or Manager; records approver and time; ≤ MRP; clearing it clears the approval. Never derived from selling price or cost. No offers/discount data is exposed. | 0003 guard, 0018 |
| Sale price ceiling | A sale line's unit price may not exceed the variant's MRP; checked in `finalize_sale` per unit, before discount, for Admin and Manager alike (`TM003`). Equal to MRP is allowed; no floor other than > 0. Past sales are not re-checked. | `finalize_sale`, migration 0020, test 15 |
| Product images | Photos live in the public Supabase Storage bucket `product-images` (2 MiB, JPEG/PNG/WebP). Only active Admin/Manager staff may write, only under `products/<folder>/<file>`; `product_images` rows must use the same paths. The website reads the public URL. Image files are not in the database backups. | migration 0021, test 16 |
| Shop contact details | One source: `shop_settings` (Admin-edited in the CRM). The website reads only `public_shop_profile` (name, address, phone, WhatsApp, email, opening hours, map link, about). | migration 0022, test 17 |
| Public stock | Only a derived `in_stock`/`out_of_stock` (devices: any in stock; accessories: `on_hand > 0`). No counts. | `public_catalogue_*` views |

### Initial discount policy values (configuration, not code)

Seed rows created by the migrations; they are data in `discount_policies`, changed only by an Admin (audited).

| Role | can_discount | max_percent (per line) | max_amount (per sale) | can_approve | Note |
|---|---|---|---|---|---|
| admin | yes | 100 | none | yes | the Admin may tighten their own limits too |
| manager | **no** | **0** | none | no (never) | "never reviewed" (`configured_at IS NULL`) until an Admin saves it; discounts need an Admin approval until then |

Upgrade note: if an Admin/owner had already configured the Manager row before migration 0019, those limits are kept.

## Still open — please confirm

| # | Open question | Current default | If you disagree |
|---|---|---|---|
| 1 | What Manager discount limits should go live (percent per line, optional per-sale cap)? | none until an Admin sets them | Admin edits `discount_policies`; no code change |
| 2 | Discount percent basis: per **line** (of that line's gross) plus an optional per-sale amount cap. Should there also be a per-sale **percent** cap? | no | add `max_sale_percent` column + check |
| 3 | Approval lifetime 1–120 min, default 15; one approval = one sale. | as stated | adjust function limits |
| 4 | Cost of accessories: purchase cost is kept on the purchase line only (no weighted-average cost per SKU), so accessory margin reporting is approximate. | yes | add average-cost column maintained by the receipt movement |
| 5 | Partial receipt of a purchase is not supported: a draft purchase is received in full or not at all. | yes | add per-line received quantities |
| 6 | No returns, voids or cancellations, no refunds, no credit notes. Sales, invoices, payments are immutable. Sold devices cannot go back to stock. | yes | next task candidate (`return_sale`) |
| 7 | IMEI must pass the Luhn check (15 digits). eSIM EIDs not modelled. | yes | relax `app.is_valid_imei` |
| 8 | Invoice number `PFX/YY-YY/NNNNNN`, gapless per April–March year, prefix ≤ 3 chars. Kept only as a readable series. | yes | change format in `finalize_sale` |
| 9 | Customer phone unique when present; walk-in sales allowed. | yes | drop the unique index |
| 10 | Two roles, one per user. Multi-role or finer permissions would change `app.current_staff_role()` and every policy. | yes | — |
| 10a | Managers cannot read the audit log, and see only their own discount approvals. (They can read sales, payments, costs, stock and expenses.) Should Managers see the audit log of their own actions? | no | change `audit_select` policy |
| 10b | Reports are not built. Rule when they are: Admin all, Manager operational only (SECURITY.md). Which reports exactly? | — | later task |
| 10c | Manager may read the staff list (names/roles) for the UI; only Admin writes it. | yes | tighten `staff_select` |
| 10d | An Admin can edit their own discount policy and deactivate themselves only if another active Admin exists. Should Admin-to-Admin changes need a second Admin? | no | add a two-person rule |
| 11 | Audit is row-level for master data and event-level for operations; reads are not audited. | yes | — |
| 12 | An accessory line cannot be sold while its variant is inactive; an inactive *device* SKU also blocks sale. | yes | — |
| 13 | Supplier payables, expense approval, stock locations beyond a free-text shelf, multi-branch: not modelled. | yes | later |
| 14 | Upgrade from Task 1 data. Task 1 was never deployed, but migrations 0010-0018 were verified against a database holding Task 1 test data: legacy discounted sales are labelled `discount_basis = 'legacy_unrecorded'` (no authoriser or reason is invented), device movements are back-filled with their `variant_id`, identifier history is back-filled, and invoice numbering continues. A database containing **split payments** is refused with a readable error; they must be reviewed by hand. | as stated | — |
