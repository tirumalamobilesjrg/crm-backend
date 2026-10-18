-- Migration 0020: finalize_sale refuses a unit price above the variant's MRP.
-- Fixture MRPs: Nova X1 (v_published, serialized) 72000; Nova Case (v_case, quantity) 999.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  v1 uuid := t.fx('v_published');
  vc uuid := t.fx('v_case');
  pur uuid; pi uuid;
  d1 uuid; d2 uuid; d3 uuid; d4 uuid;
  n_sales bigint; n_mv bigint; n_audit bigint; seq_before int; fy text := app.fiscal_year(now());
  r jsonb;
begin
  perform t.as_user(mgr);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-9501') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 4, 50000) returning id into pi;
  perform public.receive_purchase('mrp-stock-recv', pur, jsonb_build_array(
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(5001)), jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(5002)),
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(5003)), jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(5004))));
  perform t.reset();
  select id into d1 from public.inventory_items where imei1 = t.imei(5001);
  select id into d2 from public.inventory_items where imei1 = t.imei(5002);
  select id into d3 from public.inventory_items where imei1 = t.imei(5003);
  select id into d4 from public.inventory_items where imei1 = t.imei(5004);
  perform t.eq((select mrp::numeric from public.product_variants where id = v1), 72000.00, 'fixture: phone MRP is 72000');
  perform t.eq((select mrp::numeric from public.product_variants where id = vc), 999.00, 'fixture: accessory MRP is 999');

  select count(*) into n_sales from public.sales;
  select count(*) into n_mv from public.stock_movements;
  select count(*) into n_audit from public.audit_logs;
  select last_number into seq_before from public.invoice_sequences where fiscal_year = fy;

  -- ===== phones
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('mrp-over-0001', null, %L::jsonb, '{"method":"cash","amount":72000.01}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 72000.01))::text),
      'TM003', 'a phone priced 0.01 above its MRP is rejected (TM003)');
  perform t.throws(format($q$select public.finalize_sale('mrp-over-0002', null, %L::jsonb, '{"method":"cash","amount":72000.01}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 72000.01))::text),
      'above the MRP', 'the message says the price is above the MRP');
  perform t.throws(format($q$select public.finalize_sale('mrp-over-0003', null, %L::jsonb, '{"method":"cash","amount":71000}'::jsonb, null, 'Haggling')$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 80000, 'discount_amount', 9000))::text),
      'TM003', 'the check is on the unit price: a discount cannot bring an over-MRP price back under it');
  perform t.as_user(adm);
  perform t.throws(format($q$select public.finalize_sale('mrp-over-0004', null, %L::jsonb, '{"method":"cash","amount":72001}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 72001))::text),
      'TM003', 'an Admin is held to the MRP as well');
  perform t.reset();
  perform t.eq((select status::text from public.inventory_items where id = d1), 'in_stock', 'a rejected sale leaves the device in stock');

  -- ===== accessories
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('mrp-over-0005', null, %L::jsonb, '{"method":"cash","amount":999.01}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 1, 'unit_price', 999.01))::text),
      'above the MRP', 'an accessory priced above its MRP is rejected');
  perform t.throws(format($q$select public.finalize_sale('mrp-over-0006', null, %L::jsonb, '{"method":"cash","amount":2000}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 2, 'unit_price', 1000))::text),
      'TM003', 'the per-unit price is compared, not the line total');

  -- ===== mixed cart: one bad line rejects the whole sale
  perform t.throws(format($q$select public.finalize_sale('mrp-over-0007', null, %L::jsonb, '{"method":"cash","amount":71799}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d2, 'unit_price', 70000),
                        jsonb_build_object('variant_id', vc, 'quantity', 1, 'unit_price', 1799))::text),
      'above the MRP', 'one line above MRP rejects the entire cart');
  perform t.reset();
  perform t.ok((select count(*) from public.sales) = n_sales and (select count(*) from public.stock_movements) = n_mv
               and (select count(*) from public.audit_logs) = n_audit
               and (select last_number from public.invoice_sequences where fiscal_year = fy) = seq_before,
               'rejected sales leave no sale, movement, audit row, and burn no invoice number');
  perform t.eq((select status::text from public.inventory_items where id = d2), 'in_stock', 'the valid line of a rejected mixed cart is not sold either');

  -- ===== prices at or below the MRP still work
  perform t.as_user(mgr);
  r := public.finalize_sale('mrp-ok-000001', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 72000)), '{"method":"cash","amount":72000}');
  perform t.ok(r ->> 'invoice_number' is not null, 'a phone sold exactly at its MRP is accepted');
  r := public.finalize_sale('mrp-ok-000002', null,
      jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 2, 'unit_price', 999)), '{"method":"upi","amount":1998}');
  perform t.ok(r ->> 'invoice_number' is not null, 'an accessory sold exactly at its MRP is accepted');
  r := public.finalize_sale('mrp-ok-000003', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d2, 'unit_price', 65000)), '{"method":"cash","amount":65000}');
  perform t.ok(r ->> 'invoice_number' is not null, 'a price below the MRP is accepted');

  -- ===== a failed attempt stores nothing, so the same key can be reused with a corrected price
  perform t.throws(format($q$select public.finalize_sale('mrp-retry-0001', null, %L::jsonb, '{"method":"cash","amount":73000}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d3, 'unit_price', 73000))::text), 'TM003', 'retry scenario: first attempt over MRP fails');
  r := public.finalize_sale('mrp-retry-0001', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d3, 'unit_price', 72000)), '{"method":"cash","amount":72000}');
  perform t.ok((r ->> 'replayed')::boolean = false, 'retry scenario: the corrected request with the same key succeeds as a fresh sale');

  -- ===== existing behaviour is unchanged
  perform t.throws(format($q$select public.finalize_sale('mrp-zero-0001', null, %L::jsonb, '{"method":"cash","amount":1}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d4, 'unit_price', 0))::text), 'TM003', 'a zero price is still rejected');
  perform t.throws(format($q$select public.finalize_sale('mrp-pay-00001', null, %L::jsonb, '{"method":"cash","amount":1000}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d4, 'unit_price', 60000))::text), 'TM006', 'payment mismatch still raises TM006');
  perform t.reset();
  perform t.ok(not has_function_privilege('anon', 'public.finalize_sale(text,uuid,jsonb,jsonb,text,text,uuid)', 'execute')
               and has_function_privilege('authenticated', 'public.finalize_sale(text,uuid,jsonb,jsonb,text,text,uuid)', 'execute'),
               'grants on finalize_sale are unchanged (authenticated only)');
end $$;
