# Architecture

## Components and ownership

```
 public-website (Next.js, SEO)          crm-frontend (React + Vite)
        |  anon key                            |  user JWT (authenticated)
        |  SELECT public_catalogue_*           |  tables via RLS + rpc/finalize_sale|receive_purchase|adjust_stock
        v                                      v
        +---------------- Supabase (PostgREST + Auth) ----------------+
                              |
                         PostgreSQL  <-- owned by THIS repository (migrations, RLS, functions, tests)
```

- **No custom API server.** PostgREST exposes tables/views/RPCs; authorisation is enforced in the database.
  Frontend role checks are for UX only.
- **Auth:** Supabase Auth issues JWTs; `staff_profiles(user_id, role, is_active)` maps a user to exactly one
  role. Self sign-up is disabled in `supabase/config.toml` (and a user without an active profile can do nothing
  even if an account exists). Every policy and function resolves the role from `staff_profiles` through
  `app.current_staff_role()` — never from a client-supplied claim.
- **Public website:** reads only the four `public_catalogue_*` views with the anon key. Availability is a derived
  `in_stock` / `out_of_stock`; no counts, IMEIs, costs or customer data. Publishing is a CRM action
  (`products.is_published`, owner/manager only), so CRM → website propagation is "the views change when the row
  changes"; the website decides how often to revalidate (ISR/on-demand revalidation is a website-repo task).

## Schema map (all in `public`, helpers in private schema `app`)

| Area | Tables |
|---|---|
| Settings and people | `shop_settings` (singleton), `staff_profiles` |
| Catalogue | `brands`, `categories`, `products`, `product_variants`, `product_specifications`, `product_images` |
| Purchasing | `suppliers`, `purchases`, `purchase_items` |
| Inventory | `inventory_items` (serialized devices), `stock_levels` (quantity per accessory SKU), `inventory_identifiers` (IMEI/serial history, one active holder per value), `inventory_identifier_corrections`, `inventory_item_costs`, `stock_adjustments`, `stock_movements` (ledger for both kinds) |
| Selling | `customers`, `sales`, `sale_items`, `invoice_sequences`, `invoices`, `invoice_items`, `payments` (one per sale) |
| Finance and control | `expenses`, `discount_policies`, `discount_approvals`, `audit_logs`, `idempotency_keys` |
| Public surface | views `public_catalogue_products`, `_variants`, `_images`, `_specifications` |

Money is `numeric(12,2)` INR via the `inr` domain (non-negative). There is **no tax or GST handling** in the MVP:
the POS enters ordinary selling prices and discounts, and `total = Σ(unit_price × quantity) − discounts`.

## Product vs variant vs device

| Level | Example | Holds | Table |
|---|---|---|---|
| Product model | Nova X1 | name, brand, description, specs, images, **publication** | `products` |
| Variant (sellable SKU) | Nova X1 8/128 Black | SKU, tracking mode, MRP, selling price, optional approved public price | `product_variants` |
| Physical device | the unit with IMEI 49015… | IMEI/serial, status, condition, shelf, cost (separate table) | `inventory_items` |
| Accessory stock | 48 × Nova Case Black | one `on_hand` number per quantity SKU | `stock_levels` |

A variant's `tracking_mode` decides which of the last two rows applies: `serialized` (phones; one `inventory_items`
row per unit) or `quantity` (accessories; one `stock_levels` row per SKU). It cannot change after history exists.

## Integrity mechanisms

- **IMEI uniqueness:** per-column unique indexes plus the `inventory_identifiers` history (partial unique index on
  the *active* value) so an IMEI-2 can never equal any other device's active IMEI-1/2/serial, even under concurrent
  inserts. IMEIs must be 15 digits with a valid Luhn check digit. Identifiers change only through
  `correct_item_identifiers`, which retires (never deletes) the old value and records who/why.
- **Single status path:** `inventory_items.status` can only change while a `stock_movements` row is being inserted
  (trigger-enforced, valid transitions only, stale `from_status` rejected). Movements are append-only.
- **Quantity stock:** `stock_levels.on_hand` changes only inside the movement trigger (guarded update that refuses
  to go below zero; the row lock serialises concurrent sales of the same SKU); every movement stores `balance_after`,
  so the ledger reconstructs the balance.
- **Atomic sale:** `finalize_sale` locks the devices and SKU balances (stable order), prices lines, applies the
  seller's discount policy or a single-use approval, requires the single payment to equal the total, allocates a
  gapless invoice number, and writes sale, lines, invoice (with shop/customer snapshots), the payment, movements,
  audit row and idempotency record in one transaction. Deferred constraint triggers re-verify completeness at
  commit (one payment equal to the total, discounts add up, a movement per line, an audit row), so a half-written
  sale cannot commit through any path.
- **Idempotency:** the key row is inserted inside the transaction; a concurrent duplicate blocks on the unique
  index and then receives the stored response (`replayed: true`). Reusing a key with a different payload fails
  (`TM002`). Failed attempts store nothing, so a corrected retry may reuse the key.
- **Immutability:** sales, lines, invoices, payments, movements, costs, adjustments and audit logs reject
  UPDATE/DELETE for every role, including the table owner.

## Zero-monthly-cost deployment (subject to free-tier limits — verify current limits before relying on them)

| Need | Service | Notes |
|---|---|---|
| Database + Auth + API | Supabase free plan | Limits to check: database size, inactivity pausing of free projects, no point-in-time recovery, backups not guaranteed on the free plan. **Treat the free plan as having no backups; use the scripts here.** |
| CRM hosting | Cloudflare Pages / Netlify / Vercel hobby (static Vite build) | `crm-frontend` repository |
| Website hosting | Vercel hobby or Cloudflare Pages (Next.js) | `public-website` repository; hobby plans restrict commercial use — check terms |
| Backup storage | any encrypted-at-rest free object storage (e.g. Cloudflare R2 free tier) or an offline drive | files are already age-encrypted; none configured yet |
| CI | GitHub Actions free minutes | this repository's `ci.yml` |

Mandatory paid services: none. Risks: free-tier pausing/limits can interrupt a live shop; decide before go-live
whether the shop accepts that or upgrades.
