-- 0027 category pictures, and brand logos / category pictures on the public catalogue.
--
-- Forward-only. Nothing in 0001-0026 changes.
--   * Bucket `category-images`: public READ, 1 MiB, JPEG / PNG / WebP (enforced by Storage). Only active staff (Admin or Manager)
--     may list, upload, replace or delete, and only under  categories/<folder>/<file>  (same layout rules as products and brands).
--   * categories.image_path: optional picture of the category for the website; when set it must follow that layout.
--   * public_catalogue_products gains two columns at the END: brand_logo_path (brands.logo_path) and category_image_path
--     (categories.image_path). They are only object names inside the two public buckets, the same kind of value as the photo
--     paths already exposed by public_catalogue_images. Nothing else about the view changes (same rows, same filters).
-- Same guard as 0021/0026: refuse to run without Supabase Storage instead of silently skipping the policies.

do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise exception 'Supabase Storage is not initialised (storage.buckets / storage.objects are missing). Apply this migration to a Supabase project or a local stack that includes the storage service.'
      using errcode = 'TM030';
  end if;
end $$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('category-images', 'category-images', true, 1048576, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
   set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create function app.is_category_image_path(p_name text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_name ~ '^categories/[A-Za-z0-9][A-Za-z0-9_-]{0,79}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' and p_name !~ '\.\.', false)
$$;
grant execute on function app.is_category_image_path(text) to authenticated;

create policy category_images_staff_select on storage.objects for select to authenticated
  using (bucket_id = 'category-images' and (select app.is_staff()));
create policy category_images_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'category-images' and (select app.is_staff()) and app.is_category_image_path(name));
create policy category_images_staff_update on storage.objects for update to authenticated
  using (bucket_id = 'category-images' and (select app.is_staff()))
  with check (bucket_id = 'category-images' and (select app.is_staff()) and app.is_category_image_path(name));
create policy category_images_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'category-images' and (select app.is_staff()));

alter table public.categories add column image_path text;
alter table public.categories add constraint categories_image_path_layout check (image_path is null or app.is_category_image_path(image_path));

-- CREATE OR REPLACE VIEW may only append columns, which is exactly what this does.
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
            then 'in_stock' else 'out_of_stock' end as availability,
       b.logo_path as brand_logo_path,
       c.image_path as category_image_path
  from public.products p
  join public.brands b on b.id = p.brand_id and b.is_active
  join public.categories c on c.id = p.category_id and c.is_active
 where p.is_published;
