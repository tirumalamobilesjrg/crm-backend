-- Migration 0026: the public brand-logos bucket and brands.logo_path. Public read, writes only by active staff under brands/<folder>/<file>.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  inactive uuid := 'a0000000-0000-0000-0000-000000000006';
  nostaff uuid := 'a0000000-0000-0000-0000-000000000007';
  good text := 'brands/samsung/logo.svg';
begin
  perform t.reset();
  perform t.ok((select public and file_size_limit = 262144 and allowed_mime_types = array['image/svg+xml', 'image/png', 'image/webp'] from storage.buckets where id = 'brand-logos'),
               'brand-logos bucket exists: public read, 256 KiB limit, SVG/PNG/WebP only');

  perform t.ok(app.is_brand_logo_path('brands/samsung/logo.svg'), 'a slug folder is accepted');
  perform t.ok(app.is_brand_logo_path('brands/8f14e45f-ceea-467a-9575-4c5d7c8b1a3b/3f2a.png'), 'a brand-id folder is accepted');
  perform t.ok(not app.is_brand_logo_path('brands/a/../b.svg'), 'path traversal is refused');
  perform t.ok(not app.is_brand_logo_path('/brands/a/b.svg'), 'a leading slash is refused');
  perform t.ok(not app.is_brand_logo_path('brands/b.svg'), 'a missing folder is refused');
  perform t.ok(not app.is_brand_logo_path('brands/a/b/c.svg'), 'extra nesting is refused');
  perform t.ok(not app.is_brand_logo_path('products/a/b.svg'), 'only the brands/ prefix is allowed');
  perform t.ok(not app.is_brand_logo_path(null), 'null is refused by the helper');

  -- anonymous and non-staff users can do nothing with objects
  perform t.as_anon();
  perform t.throws(format($q$insert into storage.objects (bucket_id, name) values ('brand-logos', %L)$q$, good), '42501', 'anon cannot upload');
  perform t.as_user(nostaff);
  perform t.throws(format($q$insert into storage.objects (bucket_id, name) values ('brand-logos', %L)$q$, good), '42501', 'a login without a staff profile cannot upload');
  perform t.as_user(inactive);
  perform t.throws(format($q$insert into storage.objects (bucket_id, name) values ('brand-logos', %L)$q$, good), '42501', 'a deactivated staff member cannot upload');

  -- staff: upload, list, replace, delete
  perform t.as_user(mgr);
  insert into storage.objects (bucket_id, name, owner) values ('brand-logos', good, mgr);
  perform t.eq((select count(*) from storage.objects where bucket_id = 'brand-logos'), 1::bigint, 'a Manager uploads and lists a logo');
  update storage.objects set metadata = '{"replaced": true}' where bucket_id = 'brand-logos' and name = good;
  perform t.ok((select metadata ->> 'replaced' = 'true' from storage.objects where name = good), 'a Manager can replace a logo');
  perform t.as_user(adm);
  insert into storage.objects (bucket_id, name, owner) values ('brand-logos', 'brands/apple/logo.png', adm);
  delete from storage.objects where bucket_id = 'brand-logos' and name = 'brands/apple/logo.png';
  perform t.eq((select count(*) from storage.objects where bucket_id = 'brand-logos'), 1::bigint, 'an Admin uploads and deletes too');

  -- staff are still confined to the layout
  perform t.as_user(mgr);
  perform t.throws($q$insert into storage.objects (bucket_id, name) values ('brand-logos', 'brands/a/../evil.svg')$q$, '42501', 'a traversal name is refused even for staff');
  perform t.throws($q$insert into storage.objects (bucket_id, name) values ('brand-logos', 'loose.svg')$q$, '42501', 'a file outside brands/<folder>/ is refused');
  perform t.throws($q$update storage.objects set name = 'brands/x/../y.svg' where bucket_id = 'brand-logos'$q$, '42501', 'renaming a logo to a bad path is refused');

  -- brands.logo_path
  perform t.reset();
  insert into public.brands (name, slug) values ('Logo Brand', 'logo-brand');
  perform t.ok((select logo_path is null from public.brands where slug = 'logo-brand'), 'a brand starts with no logo');
  perform t.as_user(mgr);
  perform t.lives($q$update public.brands set logo_path = 'brands/logo-brand/a1.svg' where slug = 'logo-brand'$q$, 'staff can point a brand at a logo');
  perform t.throws($q$update public.brands set logo_path = 'brands/a/../b.svg' where slug = 'logo-brand'$q$, '23514', 'a traversal logo_path is refused');
  perform t.throws($q$update public.brands set logo_path = 'https://evil.example/x.svg' where slug = 'logo-brand'$q$, '23514', 'a logo_path outside the bucket layout is refused');
  perform t.lives($q$update public.brands set logo_path = null where slug = 'logo-brand'$q$, 'the logo can be removed again');

  -- the website sees no logo column
  perform t.as_anon();
  perform t.ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name like 'public\_%' and column_name = 'logo_path'),
               'no public view exposes the raw logo_path column (0027 adds only the brand_logo_path alias)');
end $$;
