-- Migration 0025: a discount approval is for ONE phone (or one accessory product), a rupee limit, single use, short validity.
-- Fixtures: Nova X1 (v_published, serialized) selling price 70000; Nova Case (v_case, quantity) selling 799.
-- The Manager's own allowance (fixtures): 10 % per line (7000 on a 70000 phone), no cap. Admin may approve up to 100 %.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  mgr2 uuid := 'a0000000-0000-0000-0000-000000000003';
  v1 uuid := t.fx('v_published');
  vc uuid := t.fx('v_case');
  pur uuid; pi uuid;
  d1 uuid; d2 uuid; d3 uuid; sold_item uuid;
  a1 uuid; a2 uuid; r jsonb; n_sales bigint;
begin
  perform t.as_user(mgr);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-9701') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 3, 50000) returning id into pi;
  perform public.receive_purchase('bound-stock-recv', pur, jsonb_build_array(
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(8101)), jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(8102)),
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(8103))));
  perform t.reset();
  select id into d1 from public.inventory_items where imei1 = t.imei(8101);
  select id into d2 from public.inventory_items where imei1 = t.imei(8102);
  select id into d3 from public.inventory_items where imei1 = t.imei(8103);
  select id into sold_item from public.inventory_items where status = 'sold' limit 1;
  select count(*) into n_sales from public.sales;

  -- ===== granting: exactly one valid target
  perform t.as_user(adm);
  perform t.throws(format($q$select public.grant_discount_approval('bound-grant-none', %L, 1000, 'no item given', 30)$q$, mgr), 'exactly one item', 'an approval with no item is refused');
  perform t.throws(format($q$select public.grant_discount_approval('bound-grant-both', %L, 1000, 'both items given', 30, %L, %L)$q$, mgr, d1, vc), 'exactly one item', 'an approval for a phone AND a product is refused');
  perform t.throws(format($q$select public.grant_discount_approval('bound-grant-sold', %L, 1000, 'a sold phone', 30, %L)$q$, mgr, sold_item), 'not in stock', 'an approval for a phone that is not in stock is refused');
  perform t.throws(format($q$select public.grant_discount_approval('bound-grant-ser', %L, 1000, 'phone product as accessory', 30, null, %L)$q$, mgr, v1), 'not an active accessory', 'a phone model cannot be used as an accessory target');
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.grant_discount_approval('bound-grant-mgr', %L, 1000, 'a Manager tries', 30, %L)$q$, mgr2, d1), '42501', 'a Manager still cannot grant approvals');

  -- ===== a phone approval: 20000 for d1, granted to the Manager
  perform t.as_user(adm);
  a1 := (public.grant_discount_approval('bound-grant-d1', mgr, 20000, 'Display model, agreed with the owner', 30, d1) ->> 'approval_id')::uuid;
  perform t.reset();
  perform t.ok((select inventory_item_id = d1 and variant_id is null from public.discount_approvals where id = a1), 'the approval is stored against that phone');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'discount.approval_granted' and record_id = a1::text and detail ->> 'inventory_item_id' = d1::text), 'the grant is audited with the phone');

  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('bound-use-01', null, %L::jsonb, '{"method":"cash","amount":55000}'::jsonb, null, 'wrong phone', %L)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d2, 'unit_price', 70000, 'discount_amount', 15000))::text, a1),
      'different item', 'the approval cannot be used for another phone');
  perform t.throws(format($q$select public.finalize_sale('bound-use-02', null, %L::jsonb, '{"method":"cash","amount":60000}'::jsonb, null, 'no discount on its phone', %L)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 70000), jsonb_build_object('inventory_item_id', d2, 'unit_price', 70000, 'discount_amount', 10000))::text, a1),
      'has no discount', 'a discount only on another phone does not make use of the approval');
  perform t.throws(format($q$select public.finalize_sale('bound-use-03', null, %L::jsonb, '{"method":"cash","amount":45000}'::jsonb, null, 'above the limit', %L)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 70000, 'discount_amount', 25000))::text, a1),
      'exceeds the approved amount', 'the discount on the approved phone cannot exceed the approved amount');
  perform t.throws(format($q$select public.finalize_sale('bound-use-04', null, %L::jsonb, '{"method":"cash","amount":110000}'::jsonb, null, 'spread the discount', %L)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 70000, 'discount_amount', 15000), jsonb_build_object('inventory_item_id', d2, 'unit_price', 70000, 'discount_amount', 15000))::text, a1),
      'other items', 'a discount on a second phone is not covered by the approval (10 % own limit applies there)');
  perform t.reset();
  perform t.eq((select count(*) from public.sales), n_sales, 'none of the refused sales were stored');
  perform t.ok((select used_at is null from public.discount_approvals where id = a1), 'the approval is still unused after the refused attempts');

  perform t.as_user(mgr);
  r := public.finalize_sale('bound-use-05', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d1, 'unit_price', 70000, 'discount_amount', 15000),
                        jsonb_build_object('inventory_item_id', d2, 'unit_price', 70000, 'discount_amount', 5000)),
      '{"method":"upi","amount":120000}', null, 'Display model plus a small deal on the second phone', a1);
  perform t.reset();
  perform t.eq((select discount_total::numeric from public.sales where id = (r ->> 'sale_id')::uuid), 20000.00, 'approved discount (15000) plus an own-limit discount (5000) are both recorded');
  perform t.eq((select discount_basis from public.sales where id = (r ->> 'sale_id')::uuid), 'manager_approval', 'the sale is recorded as approved');
  perform t.ok((select used_at is not null from public.discount_approvals where id = a1), 'the approval is now used up');
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('bound-use-06', null, %L::jsonb, '{"method":"cash","amount":55000}'::jsonb, null, 'reuse', %L)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', d3, 'unit_price', 70000, 'discount_amount', 15000))::text, a1),
      'already used', 'a used approval cannot be used again');

  -- ===== an accessory-product approval
  perform t.as_user(adm);
  a2 := (public.grant_discount_approval('bound-grant-vc', mgr, 400, 'Two cases for a regular customer', 30, null, vc) ->> 'approval_id')::uuid;
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('bound-use-07', null, %L::jsonb, '{"method":"cash","amount":1}'::jsonb, null, 'cases and a phone', %L)$q$,
      jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 2, 'unit_price', 799, 'discount_amount', 300),
                        jsonb_build_object('inventory_item_id', d3, 'unit_price', 70000, 'discount_amount', 8000))::text, a2),
      'other items', 'the accessory approval does not cover a bigger discount on a phone in the same cart');
  r := public.finalize_sale('bound-use-08', null,
      jsonb_build_array(jsonb_build_object('variant_id', vc, 'quantity', 2, 'unit_price', 799, 'discount_amount', 300)),
      '{"method":"cash","amount":1298}', null, 'Two cases for a regular customer', a2);
  perform t.ok(r ->> 'invoice_number' is not null, 'an accessory approval works for a sale of that accessory');

  -- ===== database backstops
  perform t.reset();
  perform t.throws($q$insert into public.discount_approvals (requested_for, approved_by, max_amount, reason, expires_at)
                      values ('a0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 100, 'no item', now() + interval '10 minutes')$q$,
                   '23514', 'a new approval row without an item cannot be stored');
  perform t.as_user(adm);
  a1 := (public.grant_discount_approval('bound-grant-d3', mgr, 1000, 'for the immutability check', 30, d3) ->> 'approval_id')::uuid;
  perform t.reset();
  perform t.throws(format($q$update public.discount_approvals set inventory_item_id = %L where id = %L$q$, d2, a1), 'single-use', 'the item an approval is for cannot be changed afterwards');
end $$;
