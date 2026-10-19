-- Migration 0024: prices are Admin-only; a sold phone's identifier can only be corrected by an Admin.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  mgr2 uuid := 'a0000000-0000-0000-0000-000000000003';
  v1 uuid := t.fx('v_published');
  p1 uuid := t.fx('p_published');
  sold_item uuid; stock_item uuid; r jsonb;
begin
  perform t.reset();
  select id into sold_item from public.inventory_items where status = 'sold' limit 1;
  select id into stock_item from public.inventory_items where status = 'in_stock' and variant_id = v1 limit 1;

  -- ===== prices
  perform t.as_user(mgr);
  perform t.throws(format($q$update public.product_variants set selling_price = 100 where id = %L$q$, v1), '42501', 'a Manager cannot change the selling price');
  perform t.throws(format($q$update public.product_variants set mrp = 99999 where id = %L$q$, v1), '42501', 'a Manager cannot change the MRP');
  perform t.throws(format($q$update public.product_variants set public_price = 123 where id = %L$q$, v1), '42501', 'a Manager cannot change the website price');
  perform t.throws(format($q$insert into public.product_variants (product_id, sku, mrp, selling_price) values (%L, 'MGR-NEW', 500, 400)$q$, p1), '42501', 'a Manager cannot create a variant (it needs prices)');
  perform t.lives(format($q$update public.product_variants set color = 'Green' where id = %L$q$, v1), 'a Manager can still edit non-price variant fields');
  perform t.lives(format($q$update public.product_variants set color = 'Black' where id = %L$q$, v1), '... and restore them');
  perform t.lives(format($q$update public.products set is_published = false where id = %L$q$, p1), 'a Manager can still unpublish');
  perform t.lives(format($q$update public.products set is_published = true where id = %L$q$, p1), '... and publish');
  perform t.as_user(adm);
  perform t.lives(format($q$update public.product_variants set selling_price = 70000 where id = %L$q$, v1), 'an Admin can edit prices');
  perform t.lives(format($q$insert into public.product_variants (product_id, sku, mrp, selling_price) values (%L, 'ADM-NEW', 500, 400)$q$, p1), 'an Admin can create a variant');
  perform t.reset();
  perform t.lives(format($q$update public.product_variants set selling_price = 70000 where id = %L$q$, v1), 'direct database sessions (migrations) are not blocked');

  -- ===== sold-phone identifiers
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.correct_item_identifiers('fix-sold-mgr-01', %L, '{"serial_number":"SN-FIXED-1"}'::jsonb, 'wrong serial typed at receiving')$q$, sold_item),
                   '42501', 'a Manager cannot correct the identifier of a sold phone');
  perform t.lives(format($q$select public.correct_item_identifiers('fix-stock-mgr-01', %L, '{"serial_number":"SN-STOCK-1"}'::jsonb, 'wrong serial typed at receiving')$q$, stock_item),
                  'a Manager can still correct a phone that is in stock');
  perform t.as_user(adm);
  perform t.lives(format($q$select public.correct_item_identifiers('fix-sold-adm-01', %L, '{"serial_number":"SN-FIXED-1"}'::jsonb, 'wrong serial typed at receiving')$q$, sold_item),
                  'an Admin can correct the identifier of a sold phone');

  -- ===== indexes exist
  perform t.reset();
  perform t.ok(exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'invoices_issued_at_idx')
               and exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'invoices_customer_idx'), 'invoice indexes exist');
end $$;
