# Acceptance tests

Each business rule, the automated test(s) that prove it, and whether the proof is complete. "SQL" = executed in
`tests/db/*.test.sql` (names below are the assertion titles); "race" = real concurrent sessions in
`tests/db/concurrency.sh`. Run everything with `scripts/test-db.sh`. Last full result: see TESTING.md.

| # | Rule | Evidence | Status |
|---|---|---|---|
| **Inventory** | | | |
| I1 | Serialized phones have unique IMEI/serial; duplicates (incl. IMEI-2 vs another IMEI-1, within one request, case-insensitive serial) are rejected | 04: all `…is rejected` cases | verified |
| I2 | Accessories are tracked as a quantity per SKU | 11: receipt, sale, adjustment, ledger-sum invariants | verified |
| I3 | Receiving, selling and adjusting each create a stock movement; stock cannot change otherwise | 04 `status cannot be changed without a stock movement`; 03 `…stock_levels directly`; 11 `on_hand equals the sum of its movements`; 07 `ledger reconstructs the device history` | verified |
| I4 | No overselling of accessories; no negative stock, even by raw inserts | 11 `selling more than on hand…`, `stock settles at exactly zero`, `raw movement cannot overdraw`; race E | verified |
| I5 | No double allocation of a device under concurrency | race A (`exactly one succeeds`), race B | verified |
| I6 | IMEI corrections are controlled and audited, duplicate-validated, history preserved | 12: authority, validation, duplicate cases, `identifier history keeps both values`, audit rows, `retired value can be reused`, race G | verified |
| **Payments** | | | |
| P1 | Exactly one manually recorded payment per sale; split payments rejected | 13 `split payments (array) are rejected`; `a second payment … unique`; invariant `every sale has exactly one payment` | verified |
| P2 | Payment amount must equal the final sale total (no part/credit/EMI) | 06 under/overpayment; 13 `part payment / credit sale is rejected`; invariants `every payment equals its sale total` | verified |
| P3 | No gateway/verification claims or fields | 13 `gateway-style fields … rejected`, `no gateway, verification, EMI or credit columns exist`, `payment cannot claim any source other than manual` | verified |
| P4 | Duplicate submissions are idempotent | 06 `a repeated submission returns the original sale`, `same key … different cart/payment is refused`; 11; race B | verified |
| **Tax** | | | |
| T1 | No GST/tax columns or calculations anywhere | 01 `no GST/tax/HSN columns exist`; 06 totals `list price - discount = total` | verified |
| **Discounts** | | | |
| D1 | Limits are configurable data, not hardcoded | 10 `after the Admin raises the limit to 15 %…`, `per-sale amount cap`, `switched off for Managers`, `Admin policy is configurable too` | verified |
| D2 | Server-side enforcement (frontend irrelevant) | 10 every `TM005` case; 14 `manager cannot raise their own discount limit`; DB constraint `sales_discount_record` test | verified |
| D3 | Amount, authorising user, basis, reason and approval recorded; audit history | 10 `discount within the limit records…`, `approved discount records the approver…`, audit assertions | verified |
| D4 | Approvals: single-use, expiring, capped, bound to the seller, approver must still be authorised | 10 approval block; race F | verified |
| D5 | No offers/discount banners or pages on the public site | 09 `catalogue views have no discount, offer, cost… columns`; `anon cannot read discount policies` | verified at the data layer (no website exists yet) |
| **Public catalogue** | | | |
| C1 | Only published fields + derived in/out-of-stock; accessories and phones | 01 exact column lists; 09 availability flips for both kinds | verified |
| C2 | `public_price` explicitly approved, separate from costs/selling price, ≤ MRP | 09 `public price` block; 09 `public price` block (approval stamp, <= MRP) | verified |
| C3 | Never expose IMEIs, costs, margins, customers, internal finance | 01 `catalogue views read no cost, customer…`; 09 `no IMEI-looking value or cost field`; 02 anon denied everywhere else | verified |
| **Roles** | | | |
| R1 | Exactly two roles; removed roles cannot be assigned | 01 `staff_role has exactly the values admin and manager`; 14 loop: owner, sales_executive, inventory_executive, accountant, superuser, Admin all fail with `22P02` on profile update, insert, discount policy and cast | verified |
| R2 | Admin can manage staff, roles, settings, discount policy, approvals, read audit | 14 `Admin can create a staff account` ... `Admin can read the audit log` | verified |
| R3 | Manager cannot create/promote staff, change roles, policies, settings, approve discounts, read audit | 14 `manager cannot ...` (12 assertions); 03 `manager cannot grant discount approvals`; mutation checks | verified |
| R4 | Manager can do operational work (products, publish, purchases, inventory, IMEI correction, POS, customers, expenses) | 03/14 positive cases; 05, 06, 11, 12 run as Managers | verified |
| R5 | Removed-role accounts and unprofiled/deactivated users are denied everywhere | 03 loop over former holders, no-profile and inactive users x 6 RPCs; 02 columns `inactive`, `nostaff` | verified |
| R6 | Sensitive actions by both roles are audited with actor and role | 14 `audit: ...` (12 assertions) | verified |
| R7 | Role migration is safe: refuses unsupported roles, promotes nobody, keeps history | `tests/upgrade/role_migration.sh` S1-S5 (29 checks) | verified locally; not yet in a CI run |
| R8 | Manager discount limits are configuration; unlimited Manager discounts are not the default | 00 `default: Manager discount policy grants no allowance`, `...even a 1 rupee Manager discount is refused`; 10 | verified |
| **Access control** | | | |
| A1 | RLS everywhere; deny by default; every identity × table | 01, 02 (Admin, Manager, second Manager, deactivated Manager, no-profile user x all tables, plus anon), 03 | verified (SQL level) |
| A2 | Unauthorized RPC access refused | 03 `… cannot call …` for anon, no-profile, inactive, wrong role | verified |
| A3 | Service-role key never needed in browsers | docs + `.env.example`; no code path requires it | process control, not testable here |
| **Transactions** | | | |
| X1 | Failed operations roll back completely (stock, sale, invoice number, audit, idempotency key) | 06 `failed sales created no …`, 05, 12 `rejected corrections left no correction rows`; race D | verified |
| X2 | A sale cannot commit incomplete | 06 `a sale without lines cannot exist`; 13; mutation checks | verified |
| X3 | Invoice numbers unique, gapless | 06; race C | verified |

## Not covered by these tests

HTTP/PostgREST behaviour and JWT verification; a hosted Supabase project; the `supabase-local` CI job (unverified);
returns/voids/refunds (not implemented); performance and free-tier limits; CRM/website behaviour (not built).
