-- Migration 0023: a unit price below the selling price is a discount. Regression for the "type a low price" bypass.
-- Fixtures: Nova X1 (v_published) selling price 70000, MRP 72000; Nova Case (v_case) selling 799, MRP 999.
-- The Manager's policy (fixtures): may discount up to 10 % per line, no cap, may not approve.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  v1 uuid := t.fx('v_published');
  vc uuid := t.fx('v_case');
  pur uuid; pi uuid;
  d1 uuid; d2 uuid; d3 uuid; d4 uuid;
  n_sales bigint;
  r jsonb;
begin
  perform t.as_user(mgr);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-9601') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 4, 50000) returning id into pi;
  perform public.receive_purchase('under-stock-recv', pur, jsonb_build_array(
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(6001)), jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(6002)),
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(6003)), jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(6004))));
  perform t.reset();
  select id into d1 from public.inventory_items where imei1 = t.imei(6001);
  select id into d2 from public.inventory_items where imei1 = t.imei(6002);
  select id into d3 from public.inventory_items where imei1 = t.imei(6003);
  select id into d4 from public.inventory_items where imei1 = t.imei(6004);
  select count(*) into n_sales from public.sales;

  -- ===== the exploit: a Manager types a price of 1 with no discount
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('under-exploit-1', null, %L::jsonb, '{"method":"cash","amount":1}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 1))::text), 'discount reason is required', 'a low unit price now needs a discount reason');
  perform t.throws(format($q$select public.finalize_sale('under-exploit-2', null, %L::jsonb, '{"method":"cash","amount":1}'::jsonb, null, 'because')$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 1))::text), 'exceeds your limit', 'a 99.99 % price cut exceeds the Manager limit and needs an approval');
  perform t.throws(format($q$select public.finalize_sale('under-exploit-3', null, %L::jsonb, '{"method":"cash","amount":56000}'::jsonb, null, 'cheaper for a friend')$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 56000))::text), 'exceeds your limit', 'a 20 % price cut is above the 10 % limit');
  perform t.throws(format($q$select public.finalize_sale('under-exploit-4', null, %L::jsonb, '{"method":"cash","amount":2}'::jsonb, null, 'because')$q$,
      jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 2, 'unit_price', 1))::text), 'exceeds your limit', 'accessories cannot be underpriced either');
  perform t.reset();
  perform t.eq((select count(*) from public.sales), n_sales, 'none of the underpriced sales were stored');
  perform t.eq((select status::text from public.inventory_items where id = d1), 'in_stock', 'the device is still in stock after the refused underpriced sales');

  -- ===== within the allowance the price cut is recorded as a discount with the catalogue price on the invoice
  perform t.as_user(mgr);
  r := public.finalize_sale('under-ok-000001', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d2, 'unit_price', 63000)), '{"method":"cash","amount":63000}', null, 'Regular customer');
  perform t.reset();
  perform t.eq((select unit_price::numeric from public.invoice_items where invoice_id = (r ->> 'invoice_id')::uuid), 70000.00, 'the invoice line shows the catalogue price');
  perform t.eq((select discount_amount::numeric from public.invoice_items where invoice_id = (r ->> 'invoice_id')::uuid), 7000.00, 'and the price cut as the discount');
  perform t.eq((select discount_total::numeric from public.sales where id = (r ->> 'sale_id')::uuid), 7000.00, 'the sale records the discount total');
  perform t.eq((select discount_basis from public.sales where id = (r ->> 'sale_id')::uuid), 'role_limit', 'authorised by the role limit, not "none"');
  perform t.eq((select amount::numeric from public.payments where sale_id = (r ->> 'sale_id')::uuid), 63000.00, 'the single payment equals the lowered total');

  -- ===== an explicit discount and a lower price combine
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('under-comb-0001', null, %L::jsonb, '{"method":"cash","amount":62000}'::jsonb, null, 'combined')$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d3, 'unit_price', 65000, 'discount_amount', 3000))::text), 'exceeds your limit', 'a price cut plus a discount are added together against the limit (8000 > 7000)');

  -- ===== a price above the selling price (up to the MRP) is not a discount
  r := public.finalize_sale('under-above-001', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d4, 'unit_price', 71000)), '{"method":"cash","amount":71000}');
  perform t.reset();
  perform t.eq((select discount_total::numeric from public.sales where id = (r ->> 'sale_id')::uuid), 0.00, 'selling above the selling price (below MRP) records no discount');
  perform t.eq((select discount_basis from public.sales where id = (r ->> 'sale_id')::uuid), 'none', 'and needs no approval');

  -- ===== invalid prices are still rejected as invalid, not silently raised to the selling price
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('under-zero-0001', null, %L::jsonb, '{"method":"cash","amount":1}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 1, 'unit_price', 0))::text), 'TM003', 'a zero price is still rejected');
  perform t.throws(format($q$select public.finalize_sale('under-neg-00001', null, %L::jsonb, '{"method":"cash","amount":1}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 1, 'unit_price', -5))::text), 'TM003', 'a negative price is still rejected');
  perform t.throws(format($q$select public.finalize_sale('under-paisa-001', null, %L::jsonb, '{"method":"cash","amount":1}'::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 1, 'unit_price', 100.555))::text), 'TM003', 'a sub-paisa price is still rejected');
end $$;
