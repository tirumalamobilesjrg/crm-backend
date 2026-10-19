-- Migration 0027: the public category-images bucket, categories.image_path, and brand_logo_path / category_image_path on the
-- public catalogue. Public read, staff-only writes under categories/<folder>/<file>.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  inactive uuid := 'a0000000-0000-0000-0000-000000000006';
  nostaff uuid := 'a0000000-0000-0000-0000-000000000007';
  good text := 'categories/smartphones/banner.webp';
begin
  perform t.reset();
  perform t.ok((select public and file_size_limit = 1048576 and allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'] from storage.buckets where id = 'category-images'),
               'category-images bucket exists: public read, 1 MiB limit, JPEG/PNG/WebP only');

  perform t.ok(app.is_category_image_path('categories/smartphones/a.webp'), 'a slug folder is accepted');
  perform t.ok(not app.is_category_image_path('categories/a/../b.webp'), 'path traversal is refused');
  perform t.ok(not app.is_category_image_path('/categories/a/b.webp'), 'a leading slash is refused');
  perform t.ok(not app.is_category_image_path('categories/b.webp'), 'a missing folder is refused');
  perform t.ok(not app.is_category_image_path('categories/a/b/c.webp'), 'extra nesting is refused');
  perform t.ok(not app.is_category_image_path('brands/a/b.webp'), 'only the categories/ prefix is allowed');
  perform t.ok(not app.is_category_image_path(null), 'null is refused by the helper');

  perform t.as_anon();
  perform t.throws(format($q$insert into storage.objects (bucket_id, name) values ('category-images', %L)$q$, good), '42501', 'anon cannot upload');
  perform t.as_user(nostaff);
  perform t.throws(format($q$insert into storage.objects (bucket_id, name) values ('category-images', %L)$q$, good), '42501', 'a login without a staff profile cannot upload');
  perform t.as_user(inactive);
  perform t.throws(format($q$insert into storage.objects (bucket_id, name) values ('category-images', %L)$q$, good), '42501', 'a deactivated staff member cannot upload');

  perform t.as_user(mgr);
  insert into storage.objects (bucket_id, name, owner) values ('category-images', good, mgr);
  perform t.eq((select count(*) from storage.objects where bucket_id = 'category-images'), 1::bigint, 'a Manager uploads and lists a category picture');
  perform t.as_user(adm);
  insert into storage.objects (bucket_id, name, owner) values ('category-images', 'categories/accessories/a.png', adm);
  delete from storage.objects where bucket_id = 'category-images' and name = 'categories/accessories/a.png';
  perform t.eq((select count(*) from storage.objects where bucket_id = 'category-images'), 1::bigint, 'an Admin uploads and deletes too');
  perform t.as_user(mgr);
  perform t.throws($q$insert into storage.objects (bucket_id, name) values ('category-images', 'categories/a/../evil.webp')$q$, '42501', 'a traversal name is refused even for staff');
  perform t.throws($q$insert into storage.objects (bucket_id, name) values ('category-images', 'loose.webp')$q$, '42501', 'a file outside categories/<folder>/ is refused');

  -- categories.image_path
  perform t.reset();
  perform t.ok((select image_path is null from public.categories limit 1), 'a category starts with no picture');
  perform t.as_user(mgr);
  perform t.lives($q$update public.categories set image_path = 'categories/smartphones/banner.webp' where slug = (select slug from public.categories order by slug limit 1)$q$, 'staff can point a category at a picture');
  perform t.throws($q$update public.categories set image_path = 'categories/a/../b.webp' where slug = (select slug from public.categories order by slug limit 1)$q$, '23514', 'a traversal image_path is refused');
  perform t.throws($q$update public.categories set image_path = 'https://evil.example/x.png' where slug = (select slug from public.categories order by slug limit 1)$q$, '23514', 'an image_path outside the bucket layout is refused');

  -- the public catalogue shows the two paths (and only those two new columns), for published products of active brands/categories
  perform t.reset();
  update public.brands set logo_path = 'brands/nova/logo.svg' where id = (select brand_id from public.products where is_published limit 1);
  update public.categories set image_path = 'categories/smartphones/banner.webp' where id = (select category_id from public.products where is_published limit 1);
  perform t.as_anon();
  perform t.ok((select brand_logo_path = 'brands/nova/logo.svg' and category_image_path = 'categories/smartphones/banner.webp' from public.public_catalogue_products limit 1),
               'anon sees the brand logo path and the category image path of a published product');
  perform t.ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name like 'public\_%' and column_name in ('logo_path', 'image_path')),
               'no public view exposes the raw logo_path / image_path columns, only the two named aliases');
end $$;
