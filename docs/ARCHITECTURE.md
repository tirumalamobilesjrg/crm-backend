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
| Inventory | `inventory_items`, `inventory_identifiers` (global IMEI/serial registry), `inventory_item_costs`, `stock_adjustments`, `stock_movements` |
| Selling | `customers`, `sales`, `sale_items`, `invoice_sequences`, `invoices`, `invoice_items`, `payments` |
| Finance and control | `expenses`, `audit_logs`, `idempotency_keys` |
| Public surface | views `public_catalogue_products`, `_variants`, `_images`, `_specifications` |

Money is `numeric(12,2)` INR via the `inr` domain (non-negative). GST rate is `numeric(5,2)`.
Prices entered at the POS are GST-inclusive; tax is extracted as `total × rate / (100 + rate)`.

## Product vs variant vs device

| Level | Example | Holds | Table |
|---|---|---|---|
| Product model | Nova X1 | name, brand, description, specs, images, **publication** | `products` |
| Variant (sellable SKU) | Nova X1 8/128 Black | SKU, MRP, selling price, GST rate, HSN, optional public price | `product_variants` |
| Physical device | the unit with IMEI 49015… | IMEI/serial, status, condition, shelf, cost (separate table) | `inventory_items` |

## Integrity mechanisms

- **IMEI uniqueness:** per-column unique indexes plus the `inventory_identifiers` registry (primary key on the value)
  so an IMEI-2 can never equal any other device's IMEI-1/2/serial, even under concurrent inserts. IMEIs must be
  15 digits with a valid Luhn check digit. Identifiers are immutable.
- **Single status path:** `inventory_items.status` can only change while a `stock_movements` row is being inserted
  (trigger-enforced, valid transitions only, stale `from_status` rejected). Movements are append-only.
- **Atomic sale:** `finalize_sale` locks the devices (ordered `FOR UPDATE`), prices lines, checks the role's discount
  limit, requires payments to equal the total, allocates a gapless invoice number, and writes sale, lines,
  invoice (with shop/customer snapshots), payments, movements, audit row and idempotency record in one
  transaction. Deferred constraint triggers re-verify completeness at commit, so a half-written sale cannot commit
  through any path.
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
