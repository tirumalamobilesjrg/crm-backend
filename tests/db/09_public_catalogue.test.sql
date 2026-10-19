-- What the anonymous website role can see: published products only, derived availability, no internals.
do $$
declare
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  inv uuid := 'a0000000-0000-0000-0000-000000000003';
  sales uuid := 'a0000000-0000-0000-0000-000000000003';
  p1 uuid := t.fx('p_published');
  p2 uuid := t.fx('p_hidden');
  v1 uuid := t.fx('v_published');
  r jsonb; cols text; pur uuid; pi uuid; ids uuid[]; bal int;
begin
  perform t.as_anon();
  perform t.eq((select count(*) from public.public_catalogue_products), 1::bigint, 'anon sees only the published product');
  perform t.eq((select slug from public.public_catalogue_products), 'nova-x1', 'published product slug is exposed');
  perform t.eq((select availability from public.public_catalogue_products), 'in_stock', 'availability is in_stock while a device is on the shelf');
  perform t.eq((select count(*) from public.public_catalogue_variants), 1::bigint, 'anon sees variants of published products only');
  perform t.eq((select public_price::numeric from public.public_catalogue_variants), 69999::numeric, 'only the explicitly set public price is exposed');
  perform t.eq((select count(*) from public.public_catalogue_images), 1::bigint, 'images of published products are visible');
  perform t.eq((select count(*) from public.public_catalogue_specifications), 1::bigint, 'specs of published products are visible');
  perform t.ok(not exists (select 1 from public.public_catalogue_products where slug = 'hidden-y2'), 'unpublished product is invisible');

  foreach cols in array array['inventory_items', 'inventory_item_costs', 'customers', 'sales', 'invoices', 'purchases', 'suppliers', 'staff_profiles', 'products', 'product_variants'] loop
    perform t.throws(format('select * from public.%I', cols), '42501', format('anon cannot read base table %s directly', cols));
  end loop;
  perform t.throws($q$select public.finalize_sale('anon-sale-key-1', null, '[]', '[]')$q$, '42501', 'anon cannot execute business functions');
  perform t.throws($q$insert into public.public_catalogue_products (id) values (gen_random_uuid())$q$, 'cannot insert into view', 'catalogue views are read-only for anon');

  -- the catalogue never reveals identifiers, costs or exact counts
  perform t.reset();
  perform t.as_anon();
  perform t.ok(not exists (select 1 from public.public_catalogue_variants v where to_jsonb(v)::text ~ '(imei|serial|cost|[0-9]{15})'),
               'no IMEI-looking value or cost field appears in catalogue variant rows');
  perform t.ok(not exists (select 1 from public.public_catalogue_products p where to_jsonb(p)::text ~ '(imei|serial|cost|[0-9]{15})'),
               'no IMEI-looking value or cost field appears in catalogue product rows');

  -- unpublishing hides the product; republishing restores it
  perform t.as_user(mgr);
  update public.products set is_published = false where id = p1;
  perform t.as_anon();
  perform t.eq((select count(*) from public.public_catalogue_products), 0::bigint, 'unpublishing removes the product from the catalogue');
  perform t.eq((select count(*) from public.public_catalogue_variants), 0::bigint, 'unpublishing removes its variants too');
  perform t.eq((select count(*) from public.public_catalogue_images), 0::bigint, 'unpublishing removes its images too');
  perform t.as_user(mgr);
  update public.products set is_published = true where id = p1;
  perform t.ok((select published_at is not null from public.products where id = p1), 'published_at is set on publication');

  -- inactive variant / inactive brand hide the product
  update public.product_variants set is_active = false where id = v1;
  perform t.as_anon();
  perform t.eq((select availability from public.public_catalogue_products), 'out_of_stock', 'a product with only inactive variants reads out_of_stock');
  perform t.eq((select count(*) from public.public_catalogue_variants), 0::bigint, 'inactive variants are not listed');
  perform t.as_user(mgr);
  update public.product_variants set is_active = true where id = v1;
  update public.brands set is_active = false where id = t.fx('brand');
  perform t.as_anon();
  perform t.eq((select count(*) from public.public_catalogue_products), 0::bigint, 'an inactive brand hides its products');
  perform t.as_user(mgr);
  update public.brands set is_active = true where id = t.fx('brand');

  -- availability flips when the last device is sold, and returns on adjustment
  perform t.reset();
  select array_agg(id) into ids from public.inventory_items where variant_id = v1 and status = 'in_stock';
  perform t.as_user(mgr);
  r := public.finalize_sale('pub-sellout-key1', null,
         (select jsonb_agg(jsonb_build_object('inventory_item_id', i, 'unit_price', 70000)) from unnest(ids) i),
         jsonb_build_object('method', 'cash', 'amount', 70000 * coalesce(array_length(ids, 1), 0)));
  perform t.as_anon();
  perform t.eq((select availability from public.public_catalogue_products), 'out_of_stock', 'selling the last device flips availability to out_of_stock');
  perform t.eq((select availability from public.public_catalogue_variants), 'out_of_stock', 'variant availability flips too');
  perform t.eq((select count(*) from public.public_catalogue_products), 1::bigint, 'an out-of-stock product stays listed (informational site)');

  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-9001') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 1, 50000) returning id into pi;
  perform public.receive_purchase('pub-restock-key1', pur, jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(901))));
  perform t.as_anon();
  perform t.eq((select availability from public.public_catalogue_products), 'in_stock', 'receiving a new device flips availability back to in_stock');
  perform t.reset();

  -- ===== explicitly approved public price
  perform t.ok((select public_price_approved_by = mgr and public_price_approved_at is not null from public.product_variants where id = v1),
               'the public price records the manager who approved it');
  perform t.as_user(mgr);
  perform t.throws(format($q$update public.product_variants set public_price = 72001 where id = %L$q$, v1), '23514', 'a public price above the MRP is rejected');
  perform t.lives(format($q$update public.product_variants set public_price = 68500 where id = %L$q$, v1), 'manager can change the public price');
  perform t.as_user(inv);
  perform t.throws(format($q$update public.product_variants set mrp = 68000, selling_price = 60000 where id = %L$q$, v1), '23514', 'MRP cannot be lowered below the approved public price');
  perform t.as_user(mgr);
  perform t.as_anon();
  perform t.eq((select public_price::numeric from public.public_catalogue_variants), 68500::numeric, 'the website sees the approved public price, not selling_price (70000) or MRP (72000)');
  perform t.as_user(mgr);
  update public.product_variants set public_price = null where id = v1;
  perform t.reset();
  perform t.ok((select public_price is null and public_price_approved_by is null and public_price_approved_at is null from public.product_variants where id = v1),
               'withdrawing the price also clears its approval');
  perform t.as_anon();
  perform t.ok((select public_price is null from public.public_catalogue_variants), 'with no approved price the website shows none');
  perform t.as_user(mgr);
  update public.product_variants set public_price = 69999 where id = v1;

  -- ===== quantity SKU availability (accessory)
  perform t.reset();
  select on_hand into bal from public.stock_levels where variant_id = t.fx('v_case');
  perform t.as_user(mgr);
  update public.products set is_published = true where id = t.fx('p_case');
  perform t.as_anon();
  perform t.eq((select count(*) from public.public_catalogue_products where slug = 'nova-case'), 1::bigint, 'a published accessory appears in the catalogue');
  perform t.eq((select availability from public.public_catalogue_products where slug = 'nova-case'), 'in_stock', 'accessory is in_stock while on_hand > 0');
  perform t.eq((select availability from public.public_catalogue_variants where product_slug = 'nova-case' and color = 'Black'), 'in_stock', 'accessory variant is in_stock');
  perform t.as_user(inv);
  perform public.adjust_quantity_stock('pub-zero-stock-01', t.fx('v_case'), -bal, 'correction', 'Public catalogue test: stock to zero');
  perform t.as_anon();
  perform t.eq((select availability from public.public_catalogue_products where slug = 'nova-case'), 'out_of_stock', 'accessory flips to out_of_stock at zero on hand');
  perform t.ok(not exists (select 1 from public.public_catalogue_variants v where to_jsonb(v)::text ~ '(on_hand|quantity|balance)'), 'no stock counts appear in catalogue rows');
  perform t.as_user(inv);
  perform public.adjust_quantity_stock('pub-restock-qty-1', t.fx('v_case'), bal, 'correction', 'Public catalogue test: stock restored');
  perform t.as_anon();
  perform t.eq((select availability from public.public_catalogue_products where slug = 'nova-case'), 'in_stock', 'accessory returns to in_stock when stock is restored');
  perform t.throws('select * from public.stock_levels', '42501', 'anon cannot read stock_levels');
  perform t.throws('select * from public.discount_policies', '42501', 'anon cannot read discount policies');
  perform t.ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name like 'public_catalogue_%'
                            and column_name ~* '(discount|offer|promo|banner|cost|margin|imei|serial|supplier|customer)'),
               'catalogue views have no discount, offer, cost, margin, IMEI, supplier or customer columns');
  perform t.as_user(mgr);
  update public.products set is_published = false where id = t.fx('p_case');
  perform t.reset();
end $$;
