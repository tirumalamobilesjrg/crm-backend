-- Migration 0021: the public product-images bucket. Public read through the CDN, writes only by active staff
-- (Admin or Manager) and only under products/<folder>/<file>. Anonymous users and non-staff can do nothing.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  inactive uuid := 'a0000000-0000-0000-0000-000000000006';
  nostaff uuid := 'a0000000-0000-0000-0000-000000000007';
  p1 uuid := t.fx('p_published');
  good text := 'products/nova-x1/side.webp';
begin
  -- ===== the bucket
  perform t.reset();
  perform t.ok((select public and file_size_limit = 2097152 and allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'] from storage.buckets where id = 'product-images'),
               'product-images bucket exists: public read, 2 MiB limit, JPEG/PNG/WebP only');

  -- ===== path layout helper
  perform t.ok(app.is_product_image_path('products/nova-x1/front.webp'), 'a slug folder is accepted');
  perform t.ok(app.is_product_image_path('products/8f14e45f-ceea-467a-9575-4c5d7c8b1a3b/3f2a.jpg'), 'a product-id folder is accepted');
  perform t.ok(not app.is_product_image_path('products/a/../b.webp'), 'path traversal is refused');
  perform t.ok(not app.is_product_image_path('/products/a/b.webp'), 'a leading slash is refused');
  perform t.ok(not app.is_product_image_path('products/b.webp'), 'a missing folder is refused');
  perform t.ok(not app.is_product_image_path('products/a/b/c.webp'), 'extra nesting is refused');
  perform t.ok(not app.is_product_image_path('products/a/b c.webp'), 'spaces and odd characters are refused');
  perform t.ok(not app.is_product_image_path('other/a/b.webp'), 'only the products/ prefix is allowed');
  perform t.ok(not app.is_product_image_path(null), 'null is refused');

  -- ===== anonymous and non-staff users can do nothing with objects
  perform t.as_anon();
  perform t.throws(format($q$insert into storage.objects (bucket_id, name) values ('product-images', %L)$q$, good), '42501', 'anon cannot upload');
  perform t.eq((select count(*) from storage.objects), 0::bigint, 'anon sees no object rows (public files are served by the CDN, not by listing)');
  perform t.as_user(nostaff);
  perform t.throws(format($q$insert into storage.objects (bucket_id, name) values ('product-images', %L)$q$, good), '42501', 'a login without a staff profile cannot upload');
  perform t.as_user(inactive);
  perform t.throws(format($q$insert into storage.objects (bucket_id, name) values ('product-images', %L)$q$, good), '42501', 'a deactivated staff member cannot upload');

  -- ===== staff: upload, list, replace, delete
  perform t.as_user(mgr);
  insert into storage.objects (bucket_id, name, owner) values ('product-images', good, mgr);
  perform t.eq((select count(*) from storage.objects where bucket_id = 'product-images'), 1::bigint, 'a Manager uploads and lists an image');
  update storage.objects set metadata = '{"replaced": true}' where bucket_id = 'product-images' and name = good;
  perform t.ok((select metadata ->> 'replaced' = 'true' from storage.objects where name = good), 'a Manager can replace an image');
  perform t.as_user(adm);
  insert into storage.objects (bucket_id, name, owner) values ('product-images', 'products/nova-x1/back.png', adm);
  perform t.eq((select count(*) from storage.objects where bucket_id = 'product-images'), 2::bigint, 'an Admin uploads too (both roles may)');
  delete from storage.objects where bucket_id = 'product-images' and name = 'products/nova-x1/back.png';
  perform t.eq((select count(*) from storage.objects where bucket_id = 'product-images'), 1::bigint, 'staff can delete an image');

  -- ===== staff are still confined to the layout and the bucket
  perform t.as_user(mgr);
  perform t.throws($q$insert into storage.objects (bucket_id, name) values ('product-images', 'products/a/../evil.webp')$q$, '42501', 'a traversal name is refused even for staff');
  perform t.throws($q$insert into storage.objects (bucket_id, name) values ('product-images', 'loose.webp')$q$, '42501', 'a file outside products/<folder>/ is refused');
  perform t.throws($q$insert into storage.objects (bucket_id, name) values ('product-images', 'products/a/b/c.webp')$q$, '42501', 'extra nesting is refused');
  perform t.throws($q$update storage.objects set name = 'products/x/../y.webp' where bucket_id = 'product-images'$q$, '42501', 'renaming an image to a bad path is refused');
  perform t.reset();
  insert into storage.buckets (id, name, public) values ('private-docs', 'private-docs', false);
  insert into storage.objects (bucket_id, name) values ('private-docs', 'secret.pdf');
  perform t.as_user(mgr);
  perform t.eq((select count(*) from storage.objects where bucket_id = 'private-docs'), 0::bigint, 'staff cannot see objects of other buckets');
  perform t.throws($q$insert into storage.objects (bucket_id, name) values ('private-docs', 'products/a/b.webp')$q$, '42501', 'staff cannot write to another bucket through this policy set');
  perform t.eq(t.affected($q$update storage.buckets set public = false where id = 'product-images'$q$), 0::bigint, 'staff cannot change the bucket settings (no policy: zero rows)');
  perform t.as_user(adm);
  perform t.eq(t.affected($q$update storage.buckets set public = false where id = 'product-images'$q$), 0::bigint, 'not even an Admin can change the bucket from the API (bucket settings are infrastructure)');
  perform t.reset();
  perform t.ok((select public from storage.buckets where id = 'product-images'), 'the bucket is still public after those attempts');

  -- ===== product_images rows follow the same layout
  perform t.as_user(mgr);
  perform t.lives(format($q$insert into public.product_images (product_id, storage_path, alt_text, sort_order) values (%L, %L, 'Side view', 2)$q$, p1, good), 'a product image row with a valid path is accepted');
  perform t.throws(format($q$insert into public.product_images (product_id, storage_path) values (%L, 'products/a/../b.webp')$q$, p1), '23514', 'a traversal path in product_images is refused');
  perform t.throws(format($q$insert into public.product_images (product_id, storage_path) values (%L, 'elsewhere/x.webp')$q$, p1), '23514', 'a path outside products/<folder>/ in product_images is refused');
  perform t.throws(format($q$insert into public.product_images (product_id, storage_path) values (%L, %L)$q$, p1, good), '23505', 'the same file cannot back two image rows');
  perform t.as_anon();
  perform t.ok(exists (select 1 from public.public_catalogue_images where storage_path = good), 'the public catalogue view exposes the path (the website builds the public URL from it)');
  perform t.ok(not exists (select 1 from public.public_catalogue_images where storage_path ~ '(^/|\.\.)'), 'no unsafe path is ever exposed');
end $$;
