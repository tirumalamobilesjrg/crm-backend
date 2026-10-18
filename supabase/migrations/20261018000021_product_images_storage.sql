-- 0021 product images: a public Storage bucket that only active staff (Admin or Manager) can write to.
--
-- Forward-only. Nothing in 0001-0020 changes.
--   * Bucket `product-images`: public READ (the website shows the photos through the public object URL, no login), a 2 MiB limit and
--     JPEG / PNG / WebP only (enforced by Storage itself).
--   * storage.objects policies: only an active staff member (app.is_staff(), role read from staff_profiles, never from the JWT)
--     may list, upload, replace or delete objects in this bucket, and only under  products/<folder>/<file>  where <folder> is a
--     product id or slug and <file> is a plain file name (no slashes, no "..").  Anonymous users get NO policy: public objects are
--     served by the Storage CDN without one, and anon can neither list nor write.
--   * product_images.storage_path must follow the same shape, so a row can never point outside the bucket layout.
--
-- The `storage` schema is created by Supabase Storage. This migration refuses to run without it instead of silently skipping:
-- a project without the policies would otherwise let any authenticated user write to the bucket.

do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise exception 'Supabase Storage is not initialised (storage.buckets / storage.objects are missing). Apply this migration to a Supabase project or a local stack that includes the storage service.'
      using errcode = 'TM030';
  end if;
end $$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
   set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- A stored object name: products/<folder>/<file>
create function app.is_product_image_path(p_name text) returns boolean
language sql immutable set search_path = '' as $$
  -- coalesce: a NULL name must be refused (a NULL result would PASS a CHECK constraint)
  select coalesce(p_name ~ '^products/[A-Za-z0-9][A-Za-z0-9_-]{0,79}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' and p_name !~ '\.\.', false)
$$;
grant execute on function app.is_product_image_path(text) to authenticated;

create policy product_images_staff_select on storage.objects for select to authenticated
  using (bucket_id = 'product-images' and (select app.is_staff()));
create policy product_images_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and (select app.is_staff()) and app.is_product_image_path(name));
create policy product_images_staff_update on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and (select app.is_staff()))
  with check (bucket_id = 'product-images' and (select app.is_staff()) and app.is_product_image_path(name));
create policy product_images_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and (select app.is_staff()));

-- Existing rows already follow the layout (the CRM did not exist to create others); NOT VALID would only hide a problem, so validate.
alter table public.product_images
  add constraint product_images_path_layout check (app.is_product_image_path(storage_path));
