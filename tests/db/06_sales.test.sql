-- POS sale finalisation: correctness, rollback, idempotency, invoice numbering (no tax, one payment).
do $$
declare
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  sales uuid := 'a0000000-0000-0000-0000-000000000003';
  inv uuid := 'a0000000-0000-0000-0000-000000000004';
  v1 uuid := t.fx('v_published');
  fy text := app.fiscal_year(now());
  hidden uuid := t.fx('item_hidden');
  sold1 uuid := t.fx('item_sold_1');
  extra1 uuid; extra2 uuid; extra3 uuid; extra4 uuid;
  r jsonb; r2 jsonb; n_sales bigint; n_mv bigint; n_audit bigint; seq_before int;
  pur uuid; pi uuid;
begin
  -- ===== fixture sales
  perform t.reset();
  perform t.ok((select grand_total = 69000 and discount_total = 1000 and subtotal = 70000
                  from public.invoices where id = t.fx('invoice_by_sales')), 'invoice totals: list price - discount = total, no tax lines');
  perform t.ok((select invoice_number = 'TM/' || fy || '/000001' and length(invoice_number) <= 16 from public.invoices where id = t.fx('invoice_by_sales')),
               'first invoice number follows PREFIX/FY/NNNNNN');
  perform t.ok((select invoice_number = 'TM/' || fy || '/000002' from public.invoices where id = t.fx('invoice_by_manager')), 'second invoice number is consecutive');
  perform t.ok((select customer_name = 'Test Customer' and shop_name = 'Tirumala Mobiles' from public.invoices where id = t.fx('invoice_by_sales')),
               'invoice snapshots customer and shop details');
  perform t.ok((select imei1 = t.imei(1) and imei2 = t.imei(101) and description like 'TestBrand Nova X1 Black 128GB%' and quantity = 1
                  from public.invoice_items where invoice_id = t.fx('invoice_by_sales')), 'invoice line snapshots IMEIs and description');
  perform t.ok((select count(*) = 2 and bool_or(sku = 'NOVA-CASE-BLK' and quantity = 2 and imei1 is null and line_total = 1598)
                  from public.invoice_items where invoice_id = t.fx('invoice_by_manager')), 'mixed cart: accessory line carries SKU and quantity, no IMEI');
  perform t.ok((select grand_total = 66598 and discount_total = 5000 and subtotal = 71598 from public.invoices where id = t.fx('invoice_by_manager')),
               'mixed-cart totals reconcile');
  perform t.ok((select customer_name = 'Walk-in customer' from public.invoices where id = t.fx('invoice_by_manager')), 'walk-in sale needs no customer');
  perform t.ok((select count(*) = 1 and bool_and(amount = 66598 and method = 'cash' and entry_source = 'manual') from public.payments where sale_id = t.fx('sale_by_manager')),
               'exactly one manual payment equal to the total');
  perform t.eq((select status::text from public.inventory_items where id = sold1), 'sold', 'sold device is marked sold');
  perform t.eq((select count(*) from public.stock_movements where sale_id = t.fx('sale_by_manager')), 2::bigint, 'one movement per sale line (device + accessory)');
  perform t.ok(exists (select 1 from public.stock_movements where sale_id = t.fx('sale_by_manager') and quantity_delta = -2 and balance_after = 48),
               'accessory sale movement is -2 with balance 48');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'sale.finalized' and record_id = t.fx('sale_by_sales')::text and actor_role = 'sales_executive'),
               'sale audit record names the acting role');

  -- more stock to play with
  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-4001') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 4, 50000) returning id into pi;
  perform public.receive_purchase('sales-stock-recv', pur, jsonb_build_array(
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(601)), jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(602)),
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(603)), jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(604))));
  perform t.reset();
  select id into extra1 from public.inventory_items where imei1 = t.imei(601);
  select id into extra2 from public.inventory_items where imei1 = t.imei(602);
  select id into extra3 from public.inventory_items where imei1 = t.imei(603);
  select id into extra4 from public.inventory_items where imei1 = t.imei(604);

  -- ===== rollback: payment mismatch leaves no trace and does not burn an invoice number
  select count(*) into n_sales from public.sales;
  select count(*) into n_mv from public.stock_movements;
  select count(*) into n_audit from public.audit_logs;
  select last_number into seq_before from public.invoice_sequences where fiscal_year = fy;
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('pos-mismatch-01', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 60000))::text,
      jsonb_build_object('method', 'cash', 'amount', 59999)::text), 'TM006', 'underpayment is rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-mismatch-02', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 60000))::text,
      jsonb_build_object('method', 'cash', 'amount', 60001)::text), 'TM006', 'overpayment is rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-badmethod-01', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 60000))::text,
      jsonb_build_object('method', 'bitcoin', 'amount', 60000)::text), '22P02', 'unknown payment method is rejected');
  -- failure AFTER the earlier lines validated: a batch containing a sold device is rejected as a whole
  perform t.throws(format($q$select public.finalize_sale('pos-partial-0001', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 60000),
                        jsonb_build_object('variant_id', t.fx('v_case'), 'quantity', 1, 'unit_price', 799),
                        jsonb_build_object('inventory_item_id', sold1, 'unit_price', 60000))::text,
      jsonb_build_object('method', 'cash', 'amount', 121599)::text), 'TM004', 'a batch containing a sold device is rejected as a whole');
  perform t.reset();
  perform t.eq((select count(*) from public.sales), n_sales, 'failed sales created no sale rows');
  perform t.eq((select count(*) from public.stock_movements), n_mv, 'failed sales created no stock movements');
  perform t.eq((select count(*) from public.audit_logs), n_audit, 'failed sales created no audit rows (they roll back too)');
  perform t.eq((select status::text from public.inventory_items where id = extra1), 'in_stock', 'failed sales left the device in stock');
  perform t.eq((select on_hand from public.stock_levels where variant_id = t.fx('v_case')), 48, 'failed sales left accessory stock untouched');
  perform t.eq((select last_number from public.invoice_sequences where fiscal_year = fy), seq_before, 'failed sales did not consume an invoice number');
  perform t.eq((select count(*) from public.idempotency_keys where idem_key like 'pos-%'), 0::bigint, 'failed sales stored no idempotency key, so a corrected retry can reuse it');

  -- ===== validation
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('pos-validate-01', null, %L::jsonb, %L::jsonb)$q$, '[]', '{"method":"cash","amount":1}'), 'TM003', 'an empty cart is rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-02', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 1000), jsonb_build_object('inventory_item_id', extra1, 'unit_price', 1000))::text,
      '{"method":"cash","amount":2000}'), 'appears twice', 'the same device twice in a cart is rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-03', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 0))::text, '{"method":"cash","amount":1}'), 'TM003', 'a zero price is rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-04', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 1000.555))::text, '{"method":"cash","amount":1000.56}'), 'TM003', 'sub-paisa prices are rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-05', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', gen_random_uuid(), 'unit_price', 1000))::text, '{"method":"cash","amount":1000}'), 'unknown device', 'an unknown device is rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-06', gen_random_uuid(), %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 1000))::text, '{"method":"cash","amount":1000}'), 'customer does not exist', 'an unknown customer is rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-07', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', hidden, 'unit_price', 1000))::text, '{"method":"cash","amount":1000}'), 'not available', 'a damaged device cannot be sold');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-08', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', sold1, 'unit_price', 1000))::text, '{"method":"cash","amount":1000}'), 'not available', 'a sold device cannot be sold again');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-09', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 1000, 'discount_amount', 2000))::text, '{"method":"cash","amount":1}'), 'TM003', 'a discount above the line price is rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-10', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'variant_id', v1, 'unit_price', 1000))::text, '{"method":"cash","amount":1000}'), 'exactly one of', 'a line with both a device and a SKU is rejected');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-11', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('variant_id', v1, 'quantity', 1, 'unit_price', 1000))::text, '{"method":"cash","amount":1000}'), 'serialized', 'a serialized SKU cannot be sold by quantity');
  perform t.throws(format($q$select public.finalize_sale('pos-validate-12', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'quantity', 3, 'unit_price', 1000))::text, '{"method":"cash","amount":3000}'), 'quantity 1', 'a serialized device cannot be sold with quantity 3');

  -- ===== a plain sale (no discount) by the sales executive and by the manager
  r := public.finalize_sale('pos-plain-0001', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra1, 'unit_price', 70000)),
      '{"method":"cash","amount":70000}');
  perform t.ok(r ->> 'invoice_number' = 'TM/' || fy || '/000003', 'a sale without discount needs no reason or approval; invoice 3 issued');
  perform t.as_user(mgr);
  r := public.finalize_sale('pos-plain-0002', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra2, 'unit_price', 70000)),
      '{"method":"upi","amount":70000,"reference":"UPI-9"}');
  perform t.ok(r ->> 'invoice_number' = 'TM/' || fy || '/000004', 'manager sale; invoice 4 issued');

  -- ===== idempotency
  perform t.as_user(sales);
  r := public.finalize_sale('pos-idem-key-01', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra3, 'unit_price', 65000)), '{"method":"cash","amount":65000}');
  r2 := public.finalize_sale('pos-idem-key-01', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra3, 'unit_price', 65000)), '{"method":"cash","amount":65000}');
  perform t.ok((r2 ->> 'replayed')::boolean and r2 ->> 'sale_id' = r ->> 'sale_id' and r2 ->> 'invoice_number' = r ->> 'invoice_number',
               'a repeated submission returns the original sale and invoice');
  perform t.reset();
  perform t.eq((select count(*) from public.sales where id = (r ->> 'sale_id')::uuid), 1::bigint, 'duplicate submission created exactly one sale');
  perform t.eq((select count(*) from public.stock_movements where sale_id = (r ->> 'sale_id')::uuid), 1::bigint, 'duplicate submission created exactly one stock movement');
  perform t.eq((select count(*) from public.payments where sale_id = (r ->> 'sale_id')::uuid), 1::bigint, 'duplicate submission recorded the payment once');
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('pos-idem-key-01', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra4, 'unit_price', 65000))::text, '{"method":"cash","amount":65000}'),
      'TM002', 'the same key with a different cart is refused, not silently replayed');
  perform t.throws(format($q$select public.finalize_sale('pos-idem-key-01', null, %L::jsonb, %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra3, 'unit_price', 65000))::text, '{"method":"upi","amount":65000}'),
      'TM002', 'the same key with a different payment method is refused');
  perform t.as_user(mgr);
  r2 := public.finalize_sale('pos-idem-key-01', null,
      jsonb_build_array(jsonb_build_object('inventory_item_id', extra4, 'unit_price', 65000)), '{"method":"cash","amount":65000}');
  perform t.ok(not (r2 ->> 'replayed')::boolean and r2 ->> 'sale_id' <> r ->> 'sale_id', 'idempotency keys are scoped per user');

  -- ===== invoice numbers stayed consecutive across all of the above
  perform t.reset();
  perform t.eq((select string_agg(sequence_number::text, ',' order by sequence_number) from public.invoices where fiscal_year = fy), '1,2,3,4,5,6',
               'invoice numbers are gapless after failures and replays');
  perform t.eq((select count(*) from public.invoices), (select count(distinct invoice_number) from public.invoices), 'invoice numbers are unique');
  perform t.throws(format($q$insert into public.invoices (sale_id, invoice_number, fiscal_year, sequence_number, shop_name, customer_name, subtotal, discount_total, grand_total)
                              select sale_id, invoice_number, fiscal_year, 99, shop_name, customer_name, subtotal, discount_total, grand_total from public.invoices limit 1$q$),
                   '23505', 'duplicate invoice numbers are rejected by the database');

  -- ===== completeness is enforced by the database, not only by the function
  set constraints all immediate;
  perform t.throws(format($q$insert into public.sales (sold_by, subtotal, discount_total, total) values (%L, 1000, 0, 1000)$q$, sales),
                   'no lines', 'a sale without lines cannot exist');
  perform t.throws(format($q$insert into public.stock_movements (inventory_item_id, movement_type, from_status, to_status, sale_id)
                              values (%L, 'sale', 'in_stock', 'sold', %L)$q$, t.fx('item_stock'), t.fx('sale_by_sales')),
                   'no matching sale line', 'a sale stock movement without a matching sale line cannot exist');
  set constraints all deferred;
  perform t.eq((select status::text from public.inventory_items where id = t.fx('item_stock')), 'in_stock', 'rejected raw writes left the device in stock');
end $$;
