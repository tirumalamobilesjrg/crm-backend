# Schema decisions

Status after Task 1B. "Decided" items were fixed by the business owner; "Open" items are still defaults that need
confirmation. Nothing here is deployed.

## Decided (Task 1B)

| Area | Decision | Where it lives |
|---|---|---|
| Inventory | Serialized phones (IMEI/serial per device) **and** non-serialized accessories (quantity per SKU). A SKU's `tracking_mode` is `serialized` or `quantity`, fixed once the SKU has any purchase, stock or sale history. | `product_variants.tracking_mode`; `inventory_items`, `stock_levels` |
| Stock history | Receiving, selling and adjusting always append a `stock_movements` row (per device with statuses, or per SKU with a signed `quantity_delta` and `balance_after`). Stock and status cannot change any other way. | `stock_movements`, triggers in 0005/0012 |
| Overselling | Quantity SKUs: balance locked and decremented in the same statement, never below zero. Devices: row-locked, `in_stock` → `sold` once. | 0012, 0016; concurrency tests E, A |
| IMEI corrections | Controlled and audited: owner/manager only, reason ≥ 10 chars, duplicate-checked against all *active* identifiers, old values retired not deleted, correction record + audit entry, invoices keep what they issued. | `correct_item_identifiers`, `inventory_identifiers` (history), `inventory_identifier_corrections` |
| Payments | Physical shop only. **Exactly one payment per sale**, recorded manually, amount must equal the sale total. No split, credit, EMI, gateway, or verification. `payments.entry_source` is always `manual`; `reference` is free text. | `payments` (unique per sale), `finalize_sale`, 0013 |
| Payment methods | `cash`, `upi`, `card`, `bank_transfer`, `cheque` are *labels for what the customer handed over*. `card` means a payment taken on the shop's own terminal and typed in afterwards; nothing is processed or verified here. | `payment_method` enum |
| Tax | **No GST or any tax calculation or breakdown.** Columns for tax, HSN and GSTIN were removed. Prices are plain selling prices; `total = sum(unit_price × qty) − discounts`. Invoices make no statutory claim. | migration 0011; test 01 asserts no tax-like column exists |
| Discounts | Per-role policy rows (`can_discount`, `max_percent` per line, optional `max_amount` per sale, `can_approve`). Over-limit discounts need a single-use, expiring, capped approval from an authorised approver. Every discounted sale stores amount, basis (`role_limit`/`manager_approval`), authorising user, approval id and reason. Enforced in the database, audited. | `discount_policies`, `discount_approvals`, `sales.discount_*` |
| Public price | `product_variants.public_price` is the only price the website can see. Owner/manager only; records approver and time; ≤ MRP; clearing it clears the approval. Never derived from selling price or cost. No offers/discount data is exposed. | 0003 guard, 0018 |
| Public stock | Only a derived `in_stock`/`out_of_stock` (devices: any in stock; accessories: `on_hand > 0`). No counts. | `public_catalogue_*` views |

### Initial discount policy values (configuration, not code)

Seeded rows the owner is expected to review before go-live; they are data in `discount_policies` and are changed by
the owner in the CRM (audited), never by editing code.

| Role | can_discount | max_percent (per line) | max_amount (per sale) | can_approve |
|---|---|---|---|---|
| owner | yes | 100 | none | yes |
| manager | yes | 20 | none | yes |
| sales_executive | yes | 5 | none | no |
| inventory_executive | no | 0 | – | no |
| accountant | no | 0 | – | no |

## Still open — please confirm

| # | Open question | Current default | If you disagree |
|---|---|---|---|
| 1 | Are the seeded discount limits above right for go-live? | table above | owner edits `discount_policies`; no code change |
| 2 | Discount percent basis: per **line** (of that line's gross) plus an optional per-sale amount cap. Should there also be a per-sale **percent** cap? | no | add `max_sale_percent` column + check |
| 3 | Approval lifetime 1–120 min, default 15; one approval = one sale. | as stated | adjust function limits |
| 4 | Cost of accessories: purchase cost is kept on the purchase line only (no weighted-average cost per SKU), so accessory margin reporting is approximate. | yes | add average-cost column maintained by the receipt movement |
| 5 | Partial receipt of a purchase is not supported: a draft purchase is received in full or not at all. | yes | add per-line received quantities |
| 6 | No returns, voids or cancellations, no refunds, no credit notes. Sales, invoices, payments are immutable. Sold devices cannot go back to stock. | yes | next task candidate (`return_sale`) |
| 7 | IMEI must pass the Luhn check (15 digits). eSIM EIDs not modelled. | yes | relax `app.is_valid_imei` |
| 8 | Invoice number `PFX/YY-YY/NNNNNN`, gapless per April–March year, prefix ≤ 3 chars. Kept only as a readable series. | yes | change format in `finalize_sale` |
| 9 | Customer phone unique when present; walk-in sales allowed. | yes | drop the unique index |
| 10 | Roles fixed to five; one role per user. | yes | — |
| 11 | Audit is row-level for master data and event-level for operations; reads are not audited. | yes | — |
| 12 | An accessory line cannot be sold while its variant is inactive; an inactive *device* SKU also blocks sale. | yes | — |
| 13 | Supplier payables, expense approval, stock locations beyond a free-text shelf, multi-branch: not modelled. | yes | later |
| 14 | Upgrade from Task 1 data. Task 1 was never deployed, but migrations 0010-0018 were verified against a database holding Task 1 test data: legacy discounted sales are labelled `discount_basis = 'legacy_unrecorded'` (no authoriser or reason is invented), device movements are back-filled with their `variant_id`, identifier history is back-filled, and invoice numbering continues. A database containing **split payments** is refused with a readable error; they must be reviewed by hand. | as stated | — |
