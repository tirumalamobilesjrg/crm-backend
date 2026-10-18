-- 0009 public catalogue: the ONLY objects readable by the anon role.
--
-- These views run with their owner's rights (security_invoker = false) so they can read tables that
-- anon cannot. Safety therefore comes from the column list and WHERE clause here, not from RLS:
-- no IMEI/serial, cost, supplier, customer, sale or staff data, and no stock counts. Availability
-- is only 'in_stock' / 'out_of_stock'. Supabase's linter flags security-definer views; this is
-- intentional and covered by tests/db/09_public_catalogue.test.sql.

create view public.public_catalogue_products with (security_invoker = false) as
select p.id, p.slug, p.name, b.name as brand_name, b.slug as brand_slug,
       c.name as category_name, c.slug as category_slug, p.description, p.published_at, p.updated_at,
       case when exists (select 1
                           from public.product_variants v
                           join public.inventory_items ii on ii.variant_id = v.id and ii.status = 'in_stock'
                          where v.product_id = p.id and v.is_active)
            then 'in_stock' else 'out_of_stock' end as availability
  from public.products p
  join public.brands b on b.id = p.brand_id and b.is_active
  join public.categories c on c.id = p.category_id and c.is_active
 where p.is_published;

create view public.public_catalogue_variants with (security_invoker = false) as
select v.id, p.slug as product_slug, v.color, v.ram_gb, v.storage_gb, v.public_price,
       case when exists (select 1 from public.inventory_items ii
                          where ii.variant_id = v.id and ii.status = 'in_stock')
            then 'in_stock' else 'out_of_stock' end as availability
  from public.product_variants v
  join public.products p on p.id = v.product_id and p.is_published
  join public.brands b on b.id = p.brand_id and b.is_active
  join public.categories c on c.id = p.category_id and c.is_active
 where v.is_active;

create view public.public_catalogue_images with (security_invoker = false) as
select i.id, p.slug as product_slug, i.storage_path, i.alt_text, i.sort_order, i.is_primary
  from public.product_images i
  join public.products p on p.id = i.product_id and p.is_published
  join public.brands b on b.id = p.brand_id and b.is_active
  join public.categories c on c.id = p.category_id and c.is_active;

create view public.public_catalogue_specifications with (security_invoker = false) as
select s.id, p.slug as product_slug, s.group_name, s.spec_key, s.spec_value, s.sort_order
  from public.product_specifications s
  join public.products p on p.id = s.product_id and p.is_published
  join public.brands b on b.id = p.brand_id and b.is_active
  join public.categories c on c.id = p.category_id and c.is_active;

revoke all on public.public_catalogue_products, public.public_catalogue_variants,
  public.public_catalogue_images, public.public_catalogue_specifications from public, anon, authenticated;
grant select on public.public_catalogue_products, public.public_catalogue_variants,
  public.public_catalogue_images, public.public_catalogue_specifications to anon, authenticated;
