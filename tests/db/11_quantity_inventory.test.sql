-- SKU-level quantity inventory for accessories: receiving, selling, adjusting, overselling, ledger invariants.
do $$
declare
  inv uuid := 'a0000000-0000-0000-0000-000000000004';
  sales uuid := 'a0000000-0000-0000-0000-000000000003';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  p3 uuid := t.fx('p_case');
  vc uuid := t.fx('v_case');
  v1 uuid := t.fx('v_published');
  brand uuid := t.fx('brand'); cat uuid := t.fx('category');
  base int; pur uuid; pi uuid; pi_dev uuid; vs uuid; r jsonb; r2 jsonb; n_mv bigint; bal int;
begin
  perform t.reset();
  select on_hand into base from public.stock_levels where variant_id = vc;

  -- ===== receiving
  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-6001') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, vc, 10, 310) returning id into pi;
  perform t.throws(format($q$select public.receive_purchase('qty-recv-bad-01', %L, %L::jsonb)$q$, pur,
       jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(3001)))::text),
       'takes no unit list', 'a unit list for a quantity SKU is rejected');
  perform t.reset();
  perform t.eq((select on_hand from public.stock_levels where variant_id = vc), base, 'rejected receipt did not change stock');
  perform t.as_user(inv);
  r := public.receive_purchase('qty-recv-good-01', pur, '[]');
  r2 := public.receive_purchase('qty-recv-good-01', pur, '[]');
  perform t.ok((r2 ->> 'replayed')::boolean, 'quantity receipt is idempotent');
  perform t.reset();
  perform t.eq((select on_hand from public.stock_levels where variant_id = vc), base + 10, 'receipt increased on-hand by exactly the ordered quantity (once)');
  perform t.ok(exists (select 1 from public.stock_movements where variant_id = vc and movement_type = 'purchase_receipt' and quantity_delta = 10
                          and balance_after = base + 10 and created_by = inv and inventory_item_id is null), 'receipt movement has delta, balance and actor');

  -- a purchase mixing a phone and an accessory
  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-6002') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, vc, 5, 305) returning id into pi;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 1, 50000) returning id into pi_dev;
  perform t.throws(format($q$select public.receive_purchase('qty-mixed-bad-01', %L, '[]')$q$, pur), 'expects 1 units', 'a mixed purchase still needs the phone IMEI');
  r := public.receive_purchase('qty-mixed-good-1', pur, jsonb_build_array(jsonb_build_object('purchase_item_id', pi_dev, 'imei1', t.imei(3002))));
  perform t.ok((r ->> 'units_received')::int = 1 and (r ->> 'quantity_units_received')::int = 5, 'mixed purchase receives the phone by IMEI and the accessory by quantity');
  perform t.reset();
  base := base + 15;

  -- ===== tracking mode is fixed once history exists
  perform t.throws(format($q$update public.product_variants set tracking_mode = 'serialized' where id = %L$q$, vc), 'tracking mode cannot change', 'a SKU with history cannot switch to serialized');
  perform t.throws(format($q$update public.product_variants set tracking_mode = 'quantity' where id = %L$q$, v1), 'tracking mode cannot change', 'a phone SKU with devices cannot switch to quantity');
  insert into public.product_variants (product_id, sku, color, mrp, selling_price, tracking_mode)
    values (p3, 'NOVA-CASE-RED', 'Red', 999, 799, 'quantity') returning id into vs;
  perform t.lives(format($q$update public.product_variants set tracking_mode = 'serialized' where id = %L$q$, vs), 'a brand-new SKU may still change mode');
  perform t.lives(format($q$update public.product_variants set tracking_mode = 'quantity' where id = %L$q$, vs), '... and back');

  -- ===== selling and overselling
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('qty-sell-over-01', null, %L::jsonb, '{"method":"cash","amount":79900}'::jsonb)$q$,
       jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 100, 'unit_price', 799))::text), 'insufficient stock', 'selling more than on hand is rejected');
  perform t.throws(format($q$select public.finalize_sale('qty-sell-zero-01', null, %L::jsonb, '{"method":"cash","amount":0}'::jsonb)$q$,
       jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 0, 'unit_price', 799))::text), 'TM003', 'quantity 0 is rejected');
  perform t.throws(format($q$select public.finalize_sale('qty-sell-twice-01', null, %L::jsonb, '{"method":"cash","amount":1598}'::jsonb)$q$,
       jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 1, 'unit_price', 799), jsonb_build_object('variant_id', vc, 'quantity', 1, 'unit_price', 799))::text),
       'appears twice', 'the same SKU twice in one cart is rejected (send one line with the total quantity)');
  perform t.throws(format($q$select public.finalize_sale('qty-sell-nosku-01', null, %L::jsonb, '{"method":"cash","amount":799}'::jsonb)$q$,
       jsonb_build_array(jsonb_build_object('variant_id', gen_random_uuid(), 'quantity', 1, 'unit_price', 799))::text), 'unknown device or SKU', 'an unknown SKU is rejected');
  perform t.reset();
  perform t.eq((select on_hand from public.stock_levels where variant_id = vc), base, 'rejected sales did not change stock');

  perform t.as_user(sales);
  r := public.finalize_sale('qty-sell-good-01', null,
       jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 5, 'unit_price', 799)), '{"method":"upi","amount":3995}');
  r2 := public.finalize_sale('qty-sell-good-01', null,
       jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 5, 'unit_price', 799)), '{"method":"upi","amount":3995}');
  perform t.ok((r2 ->> 'replayed')::boolean and r2 ->> 'sale_id' = r ->> 'sale_id', 'repeated accessory sale returns the original');
  perform t.reset();
  perform t.eq((select on_hand from public.stock_levels where variant_id = vc), base - 5, 'accessory stock reduced once by the sold quantity');
  perform t.ok(exists (select 1 from public.stock_movements where sale_id = (r ->> 'sale_id')::uuid and quantity_delta = -5 and balance_after = base - 5 and variant_id = vc),
               'sale movement is -5 with the resulting balance');
  perform t.ok((select quantity = 5 and inventory_item_id is null and line_total = 3995 from public.sale_items where sale_id = (r ->> 'sale_id')::uuid),
               'sale line stores quantity and no device');
  base := base - 5;

  -- sell exactly everything on a fresh SKU, then one more
  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-6003') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, vs, 3, 250) returning id into pi;
  perform public.receive_purchase('qty-fresh-recv-1', pur, '[]');
  perform t.as_user(mgr);
  perform public.finalize_sale('qty-all-sell-001', null, jsonb_build_array(jsonb_build_object('variant_id', vs, 'quantity', 3, 'unit_price', 799)), '{"method":"cash","amount":2397}');
  perform t.throws(format($q$select public.finalize_sale('qty-one-more-001', null, %L::jsonb, '{"method":"cash","amount":799}'::jsonb)$q$,
       jsonb_build_array(jsonb_build_object('variant_id', vs, 'quantity', 1, 'unit_price', 799))::text), 'available 0', 'selling past zero is rejected');
  perform t.reset();
  perform t.eq((select on_hand from public.stock_levels where variant_id = vs), 0, 'stock settles at exactly zero, never negative');

  -- ===== adjustments
  perform t.as_user(inv);
  perform t.throws(format($q$select public.adjust_quantity_stock('qadj-bad-sign-01', %L, 2, 'damaged', 'damaged items cannot increase stock')$q$, vc), 'TM003', 'damaged with a positive change is rejected');
  perform t.throws(format($q$select public.adjust_quantity_stock('qadj-bad-sign-02', %L, -2, 'found', 'found items cannot reduce stock')$q$, vc), 'TM003', 'found with a negative change is rejected');
  perform t.throws(format($q$select public.adjust_quantity_stock('qadj-no-notes-01', %L, -1, 'damaged', '')$q$, vc), 'TM003', 'notes are required');
  perform t.throws(format($q$select public.adjust_quantity_stock('qadj-zero-0001', %L, 0, 'correction', 'nothing')$q$, vc), 'TM003', 'a zero change is rejected');
  perform t.throws(format($q$select public.adjust_quantity_stock('qadj-serial-001', %L, -1, 'damaged', 'phone sku')$q$, v1), 'not quantity-tracked', 'quantity adjustments do not apply to serialized SKUs');
  perform t.throws(format($q$select public.adjust_quantity_stock('qadj-below-0001', %L, -1000, 'correction', 'recount mistake')$q$, vc), 'insufficient stock', 'an adjustment cannot drive stock below zero');
  select count(*) into n_mv from public.stock_movements;
  r := public.adjust_quantity_stock('qadj-good-00001', vc, -2, 'damaged', 'Two cases cracked in storage');
  r2 := public.adjust_quantity_stock('qadj-good-00001', vc, -2, 'damaged', 'Two cases cracked in storage');
  perform t.ok((r2 ->> 'replayed')::boolean and (r ->> 'balance_after')::int = base - 2, 'adjustment returns the new balance; replay is flagged');
  perform public.adjust_quantity_stock('qadj-found-0001', vc, 1, 'found', 'One case found behind the counter');
  perform public.adjust_quantity_stock('qadj-corr-00001', vc, -1, 'correction', 'Stock count showed one fewer');
  perform t.reset();
  perform t.eq((select count(*) from public.stock_movements), n_mv + 3, 'three adjustments (replay excluded) created exactly three movements');
  perform t.eq((select on_hand from public.stock_levels where variant_id = vc), base - 2, 'on-hand = base - 2 + 1 - 1 + ... = base - 2');
  perform t.eq((select count(*) from public.stock_adjustments where variant_id = vc and created_by = inv
                 and notes in ('Two cases cracked in storage', 'One case found behind the counter', 'Stock count showed one fewer')), 3::bigint,
               'each adjustment has a record with reason, notes and actor');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'stock.quantity_adjusted' and actor_id = inv and (detail ->> 'delta')::int = -2), 'quantity adjustment is audited');

  -- ===== ledger invariants (database owner view)
  perform t.eq((select count(*) from public.stock_levels sl
                 where sl.on_hand <> (select coalesce(sum(m.quantity_delta), 0) from public.stock_movements m
                                       where m.variant_id = sl.variant_id and m.inventory_item_id is null)), 0::bigint,
               'for every quantity SKU, on_hand equals the sum of its movements');
  perform t.eq((select count(*) from public.stock_movements m where m.inventory_item_id is null
                  and m.balance_after <> (select sum(m2.quantity_delta) from public.stock_movements m2
                                           where m2.variant_id = m.variant_id and m2.inventory_item_id is null and m2.id <= m.id)), 0::bigint,
               'every movement balance_after equals the running total at that point');
  perform t.eq((select count(*) from public.stock_levels where on_hand < 0), 0::bigint, 'no negative stock anywhere');
  perform t.throws(format($q$insert into public.stock_movements (variant_id, movement_type, quantity_delta, adjustment_id)
                             values (%L, 'adjustment', -100000, (select id from public.stock_adjustments where variant_id = %L limit 1))$q$, vc, vc),
                   'insufficient stock', 'even a raw movement insert cannot overdraw stock');
  perform t.throws(format($q$insert into public.stock_movements (variant_id, movement_type, quantity_delta, adjustment_id)
                             values (%L, 'adjustment', -1, (select id from public.stock_adjustments where variant_id = %L limit 1))$q$, v1, vc),
                   'not quantity-tracked', 'a quantity movement cannot target a serialized SKU');
end $$;
