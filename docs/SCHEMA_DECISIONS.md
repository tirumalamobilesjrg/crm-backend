# Schema decisions — need your confirmation

Everything below is implemented as a *default* so Task 1 is testable. Each item says what was assumed and what
changes if you disagree. Items marked **blocking** should be decided before the CRM is built on top.

| # | Decision (as implemented) | Why | If you disagree |
|---|---|---|---|
| 1 **blocking** | **Only serialised stock** (every unit has an IMEI/serial). Accessories without serials (cases, chargers, tempered glass) are *not* supported yet. | The brief stresses IMEI-level inventory; quantity stock needs a different model (stock levels per variant, no per-unit locking). | Add `tracking_mode` to variants and a `stock_levels` table + movements keyed by variant. Changes sales/purchase functions. |
| 2 **blocking** | **Sales must be fully paid at billing** (payments = invoice total). Split tenders allowed (cash + UPI). No credit/EMI/part payment. | Keeps "paid" unambiguous. | Add `payment_status`, `balance_due`, a `record_payment` function and customer ledger. |
| 3 | **Prices are GST-inclusive**; tax = total × rate/(100+rate); one `gst_rate` per variant (default 18 %). CGST/SGST/IGST split is **not** stored. | Indian retail MRP convention. | Add place-of-supply logic and split columns on `invoice_items` (needs shop and customer state codes). |
| 4 | **Invoice number** `PFX/YY-YY/NNNNNN`, prefix ≤ 3 chars (`TM`), gapless per financial year (April–March, India time), serialised by a row lock. | GST rule 46 caps invoice numbers at 16 chars and requires a consecutive series. | Different format → change `finalize_sale` + `invoices` check. Gapless numbering means concurrent POS sales queue briefly; fine for one shop. |
| 5 | **No returns, voids or cancellations** yet. Sales, invoices and payments are immutable; sold devices cannot return to stock. | A safe return flow needs credit notes (GST) and refund payments — a design of its own. | Next task candidate: `return_sale` + `credit_notes` + `refunds`. |
| 6 | **Sales-executive discount limit** 5 % per line (`shop_settings.max_sales_exec_discount_pct`); manager/owner unlimited. | Typical control; tunable. | Change setting or rule; no schema change. |
| 7 | **IMEI must pass Luhn** (15 digits). Dual-SIM stored as `imei2`; eSIM EIDs not modelled. | Catches typos at receipt. | Relax `app.is_valid_imei` if suppliers deliver non-compliant IMEIs. |
| 8 | **Identity of a device is immutable** (IMEIs, serial, variant). A typo at receipt currently needs a privileged manual fix by the project owner. | Prevents history rewriting. | Add an owner-only `correct_identifiers` function that audits old/new values. |
| 9 | **Cost is excluding GST** and recorded per device; sales margin = taxable value − cost. Input-tax-credit accounting is out of scope. | Simple, auditable. | — |
| 10 | **Website price**: only `product_variants.public_price` (null ⇒ "contact shop"), settable by owner/manager. Selling price is never exposed. | Brief says no offers/discounts; avoids leaking a negotiable price. | Expose selling price via the view instead. |
| 11 | **Out-of-stock products remain listed** (`availability = out_of_stock`). | Informational SEO site keeps indexed pages. | Filter in the view. |
| 12 | **Customer phone unique** when present; walk-in sales allowed without a customer. | De-duplication. | Drop the unique index if family members share numbers. |
| 13 | **Roles are fixed to five and one role per user.** | Matches the brief. | Multi-role would change `app.current_staff_role()`. |
| 14 | **Supplier credit / payables** and **expense approval** are not modelled. | Out of Task 1 scope. | Later task. |
| 15 | **Time zone**: timestamps are `timestamptz`; the financial year is computed in Asia/Kolkata. | — | — |
| 16 | **Audit** is row-level (before/after JSON) for master data and key events for business operations; reads are not audited. | Cost/benefit on free tier. | Add read auditing via an RPC layer if required. |
