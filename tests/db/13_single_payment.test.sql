-- One manually recorded payment per sale, reconciled with the total. No split, credit, EMI or gateway semantics.
do $$
declare
  sales uuid := 'a0000000-0000-0000-0000-000000000003';
  inv uuid := 'a0000000-0000-0000-0000-000000000002';
  item uuid; items jsonb; pur uuid; pi uuid;
begin
  -- a fresh device to try (and fail) to sell
  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-8001') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, t.fx('v_published'), 1, 40000) returning id into pi;
  perform public.receive_purchase('pay-stock-recv-1', pur, jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(4001))));
  perform t.reset();
  select id into item from public.inventory_items where imei1 = t.imei(4001);
  items := jsonb_build_array(jsonb_build_object('inventory_item_id', item, 'unit_price', 50000));

  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('pay-split-000001', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '[{"method":"cash","amount":20000},{"method":"upi","amount":30000}]'), 'split payments are not supported', 'split payments (array) are rejected');
  perform t.throws(format($q$select public.finalize_sale('pay-extra-000001', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '{"method":"upi","amount":50000,"provider":"somegateway","verified":true}'), 'only method, amount and reference', 'gateway-style fields in a payment are rejected');
  perform t.throws(format($q$select public.finalize_sale('pay-part-0000001', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '{"method":"cash","amount":40000}'), 'TM006', 'part payment / credit sale is rejected');
  perform t.throws(format($q$select public.finalize_sale('pay-over-0000001', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '{"method":"cash","amount":50000.01}'), 'TM006', 'overpayment is rejected');
  perform t.throws(format($q$select public.finalize_sale('pay-nomethod-01', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '{"amount":50000}'), 'payment method is required', 'a missing method is rejected');
  perform t.throws(format($q$select public.finalize_sale('pay-noamount-01', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '{"method":"cash"}'), 'TM003', 'a missing amount is rejected');
  perform t.throws(format($q$select public.finalize_sale('pay-negative-01', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '{"method":"cash","amount":-50000}'), 'TM003', 'a negative amount is rejected');
  perform t.throws(format($q$select public.finalize_sale('pay-decimal-001', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '{"method":"cash","amount":50000.001}'), 'TM003', 'more than two decimals is rejected');
  perform t.throws(format($q$select public.finalize_sale('pay-string-0001', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '"cash"'), 'one JSON object', 'a non-object payment is rejected');
  perform t.reset();
  perform t.eq((select status::text from public.inventory_items where id = item), 'in_stock', 'no rejected payment shape sold the device');

  -- every payment method is a manual record
  perform t.as_user(sales);
  perform t.lives(format($q$select public.finalize_sale('pay-card-0000001', null, %L::jsonb, %L::jsonb)$q$, items::text,
       '{"method":"card","amount":50000,"reference":"POS terminal slip 0042"}'), 'a card payment can be recorded as a manual entry (no processing happens)');
  perform t.reset();
  perform t.ok((select method = 'card' and reference = 'POS terminal slip 0042' and entry_source = 'manual' and received_by = sales
                  from public.payments order by received_at desc, id limit 1), 'the payment stores method, free-text reference, manual source and the recording user');

  -- database-level guarantees
  perform t.throws($q$insert into public.payments (sale_id, invoice_id, method, amount, received_by)
                      select sale_id, invoice_id, 'cash', 1, received_by from public.payments limit 1$q$, '23505', 'a second payment for the same sale violates the unique constraint');
  perform t.throws($q$insert into public.payments (sale_id, invoice_id, method, amount, received_by, entry_source)
                      values (gen_random_uuid(), gen_random_uuid(), 'upi', 1, gen_random_uuid(), 'gateway')$q$, '23514', 'a payment cannot claim any source other than manual entry');
  perform t.ok(not exists (select 1 from information_schema.columns where table_schema = 'public'
                            and column_name ~* '(gateway|provider|razorpay|stripe|paytm|phonepe|verified|settlement|emi|instalment|installment|balance_due)'),
               'no gateway, verification, EMI or credit columns exist');
  perform t.eq((select count(*) from public.sales s where (select count(*) from public.payments p where p.sale_id = s.id) <> 1), 0::bigint, 'every sale has exactly one payment');
  perform t.eq((select count(*) from public.sales s join public.payments p on p.sale_id = s.id where p.amount <> s.total), 0::bigint, 'every payment equals its sale total');
  perform t.eq((select count(*) from public.invoices i join public.payments p on p.invoice_id = i.id where p.amount <> i.grand_total), 0::bigint, 'every payment equals its invoice total');
  perform t.ok((select coalesce(sum(p.amount), 0) = coalesce(sum(s.total), 0) from public.sales s join public.payments p on p.sale_id = s.id), 'sum of payments reconciles with the sum of sales');

  -- the completeness trigger blocks a sale whose payment is missing or wrong
  set constraints all immediate;
  perform t.throws(format($q$with s as (insert into public.sales (id, sold_by, subtotal, discount_total, total) values (gen_random_uuid(), %L, 100, 0, 100) returning id)
                             select 1 from s$q$, sales), 'no lines', 'a sale cannot be committed without lines (and therefore without payment)');
  set constraints all deferred;
end $$;
