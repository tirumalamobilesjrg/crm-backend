-- 0018 Task 1B: explicit public price approval and availability for quantity SKUs.
--
-- public_price is the ONLY price the website can ever show. It is separate from selling_price, MRP and
-- purchase cost, can be set only by an owner or manager (guard_publication, 0003), and now records who
-- approved it and when. Setting it to NULL withdraws it ("contact the shop"). It may not exceed the MRP.

alter table public.product_variants
  add column public_price_approved_by uuid references public.staff_profiles (user_id) on delete restrict,
  add column public_price_approved_at timestamptz;

update public.product_variants set public_price_approved_at = updated_at where public_price is not null;

alter table public.product_variants
  add constraint variants_public_price_approved check ((public_price is null) = (public_price_approved_at is null)),
  add constraint variants_public_price_le_mrp check (public_price is null or public_price <= mrp);

create function app.stamp_public_price_approval() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.public_price is distinct from old.public_price then
    if new.public_price is null then
      new.public_price_approved_by := null;
      new.public_price_approved_at := null;
    else
      new.public_price_approved_by := auth.uid();     -- NULL only for direct database sessions (migrations)
      new.public_price_approved_at := now();
    end if;
  end if;
  return new;
end $$;
-- Name sorts after variants_guard_publication, so the permission check runs first.
create trigger variants_public_price_approval before insert or update on public.product_variants
  for each row execute function app.stamp_public_price_approval();

-- Availability: serialized SKUs = at least one device in stock; quantity SKUs = on_hand > 0.
-- Columns are unchanged from 0009, so the exposed surface is unchanged.
create or replace view public.public_catalogue_products with (security_invoker = false) as
select p.id, p.slug, p.name, b.name as brand_name, b.slug as brand_slug,
       c.name as category_name, c.slug as category_slug, p.description, p.published_at, p.updated_at,
       case when exists (select 1
                           from public.product_variants v
                          where v.product_id = p.id and v.is_active
                            and ((v.tracking_mode = 'serialized'
                                  and exists (select 1 from public.inventory_items ii
                                               where ii.variant_id = v.id and ii.status = 'in_stock'))
                              or (v.tracking_mode = 'quantity'
                                  and exists (select 1 from public.stock_levels sl
                                               where sl.variant_id = v.id and sl.on_hand > 0))))
            then 'in_stock' else 'out_of_stock' end as availability
  from public.products p
  join public.brands b on b.id = p.brand_id and b.is_active
  join public.categories c on c.id = p.category_id and c.is_active
 where p.is_published;

create or replace view public.public_catalogue_variants with (security_invoker = false) as
select v.id, p.slug as product_slug, v.color, v.ram_gb, v.storage_gb, v.public_price,
       case when (v.tracking_mode = 'serialized'
                  and exists (select 1 from public.inventory_items ii
                               where ii.variant_id = v.id and ii.status = 'in_stock'))
              or (v.tracking_mode = 'quantity'
                  and exists (select 1 from public.stock_levels sl
                               where sl.variant_id = v.id and sl.on_hand > 0))
            then 'in_stock' else 'out_of_stock' end as availability
  from public.product_variants v
  join public.products p on p.id = v.product_id and p.is_published
  join public.brands b on b.id = p.brand_id and b.is_active
  join public.categories c on c.id = p.category_id and c.is_active
 where v.is_active;
