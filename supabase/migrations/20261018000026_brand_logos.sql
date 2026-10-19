-- 0026 brand logos: a public Storage bucket for brand logos, and brands.logo_path pointing into it.
--
-- Forward-only. Nothing in 0001-0025 changes.
--   * Bucket `brand-logos`: public READ (the CRM shows the logo through the public object URL), a 256 KiB limit and
--     SVG / PNG / WebP only (enforced by Storage itself).
--   * storage.objects policies: only an active staff member (app.is_staff()) may list, upload, replace or delete objects in this
--     bucket, and only under  brands/<folder>/<file>  where <folder> is a brand slug or id and <file> is a plain file name.
--     Anonymous users get NO policy: public objects are served by the Storage CDN without one.
--   * brands.logo_path is optional and, when set, must follow the same layout. It is NOT exposed through any public view
--     (the website shows brand names only), so anon still sees nothing new.
-- Same guard as 0021: refuse to run without Supabase Storage instead of silently skipping the policies.

do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise exception 'Supabase Storage is not initialised (storage.buckets / storage.objects are missing). Apply this migration to a Supabase project or a local stack that includes the storage service.'
      using errcode = 'TM030';
  end if;
end $$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brand-logos', 'brand-logos', true, 262144, array['image/svg+xml', 'image/png', 'image/webp'])
on conflict (id) do update
   set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- A stored object name: brands/<folder>/<file>
create function app.is_brand_logo_path(p_name text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_name ~ '^brands/[A-Za-z0-9][A-Za-z0-9_-]{0,79}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' and p_name !~ '\.\.', false)
$$;
grant execute on function app.is_brand_logo_path(text) to authenticated;

create policy brand_logos_staff_select on storage.objects for select to authenticated
  using (bucket_id = 'brand-logos' and (select app.is_staff()));
create policy brand_logos_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'brand-logos' and (select app.is_staff()) and app.is_brand_logo_path(name));
create policy brand_logos_staff_update on storage.objects for update to authenticated
  using (bucket_id = 'brand-logos' and (select app.is_staff()))
  with check (bucket_id = 'brand-logos' and (select app.is_staff()) and app.is_brand_logo_path(name));
create policy brand_logos_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'brand-logos' and (select app.is_staff()));

alter table public.brands add column logo_path text;
-- NULL means "no logo"; app.is_brand_logo_path(NULL) is false, so NULL is allowed explicitly.
alter table public.brands add constraint brands_logo_path_layout check (logo_path is null or app.is_brand_logo_path(logo_path));
