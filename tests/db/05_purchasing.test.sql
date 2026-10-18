-- Purchase receipt: happy path, replay, rollback, and frozen state.
do $$
declare
  inv uuid := 'a0000000-0000-0000-0000-000000000004';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  sup uuid := t.fx('supplier');
  v1 uuid := t.fx('v_published');
  pur uuid; pi uuid; r jsonb; r2 jsonb; item uuid;
  items_before bigint; mv_before bigint;
  units jsonb;
begin
  -- the fixture receipt already happened; verify what it wrote
  perform t.reset();
  perform t.eq((select count(*) from public.stock_movements where movement_type = 'purchase_receipt' and inventory_item_id is not null), 4::bigint, 'one receipt movement per received device');
  perform t.eq((select count(*) from public.stock_movements where movement_type = 'purchase_receipt' and inventory_item_id is null and quantity_delta = 50 and balance_after = 50),
               1::bigint, 'accessory receipt is one signed movement with the resulting balance');
  perform t.eq((select count(*) from public.inventory_item_costs where cost_price = 50000), 3::bigint, 'acquisition cost recorded per device');
  perform t.eq((select status::text from public.purchases where id = t.fx('purchase')), 'received', 'purchase is marked received');
  perform t.ok((select received_at is not null and received_by = 'a0000000-0000-0000-0000-000000000004' from public.purchases where id = t.fx('purchase')),
               'receipt time and actor recorded');

  -- draft rules
  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (sup, 'INV-3001') returning id into pur;
  perform t.throws(format($q$insert into public.purchases (supplier_id, supplier_invoice_no) values (%L, 'inv-3001')$q$, sup), '23505',
                   'supplier invoice number is unique per supplier (case-insensitive)');
  perform t.throws(format($q$insert into public.purchases (supplier_id, supplier_invoice_no, status) values (%L, 'INV-3002', 'received')$q$, sup),
                   '42501', 'a purchase cannot be created as already received');
  perform t.throws(format($q$update public.purchases set status = 'received', received_at = now() where id = %L$q$, pur),
                   'TM007', 'a purchase cannot be marked received by a direct update (trigger fires before RLS check)');
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 2, 48000) returning id into pi;
  perform t.throws(format($q$insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (%L, %L, 0, 1)$q$, pur, v1),
                   '23514', 'purchase quantity must be positive');
  perform t.throws(format($q$insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (%L, %L, 1, -5)$q$, pur, v1),
                   '23514', 'unit cost cannot be negative');

  -- wrong unit count rolls everything back
  select count(*) into items_before from public.inventory_items;
  select count(*) into mv_before from public.stock_movements;
  perform t.throws(format($q$select public.receive_purchase('recv-wrong-count', %L, %L::jsonb)$q$, pur,
                          jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(501)))::text),
                   'expects 2 units', 'receiving fewer units than ordered is rejected');
  perform t.throws(format($q$select public.receive_purchase('recv-foreign-line', %L, %L::jsonb)$q$, pur,
                          jsonb_build_array(jsonb_build_object('purchase_item_id', t.fx('pi1'), 'imei1', t.imei(502)),
                                            jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(503)),
                                            jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(504)))::text),
                   'not part of this purchase', 'units for another purchase line are rejected');
  perform t.reset();
  perform t.eq((select count(*) from public.inventory_items), items_before, 'failed receipt wrote no devices');
  perform t.eq((select count(*) from public.stock_movements), mv_before, 'failed receipt wrote no stock movements');

  -- success + idempotent replay
  perform t.as_user(inv);
  units := jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(511), 'condition', 'new', 'shelf_location', 'A1'),
                             jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(512)));
  r := public.receive_purchase('recv-good-key-1', pur, units);
  perform t.eq((r ->> 'units_received')::int, 2, 'receipt of a valid purchase succeeds');
  perform t.eq((r ->> 'replayed')::boolean, false, 'first call is not a replay');
  r2 := public.receive_purchase('recv-good-key-1', pur, units);
  perform t.ok((r2 ->> 'replayed')::boolean and r2 -> 'units_received' = r -> 'units_received', 'repeating the same key returns the stored result');
  perform t.reset();
  perform t.eq((select count(*) from public.inventory_items), items_before + 2, 'replay did not create devices twice');
  perform t.eq((select count(*) from public.idempotency_keys where idem_key = 'recv-good-key-1'), 1::bigint, 'exactly one idempotency record');

  -- same key with a different payload is refused
  perform t.as_user(inv);
  perform t.throws(format($q$select public.receive_purchase('recv-good-key-1', %L, %L::jsonb)$q$, pur,
                          jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(521)))::text),
                   'TM002', 'reusing an idempotency key for a different request is refused');
  -- receiving again with a new key
  perform t.throws(format($q$select public.receive_purchase('recv-good-key-2', %L, %L::jsonb)$q$, pur, units::text),
                   'TM007', 'a received purchase cannot be received again');
  perform t.throws('select public.receive_purchase(''short'', gen_random_uuid(), ''[{}]'')', 'TM003', 'idempotency keys shorter than 8 characters are refused');

  -- frozen afterwards
  perform t.eq(t.affected(format($q$update public.purchases set notes = 'edit' where id = %L$q$, pur)), 0::bigint, 'RLS hides received purchases from edits');
  perform t.eq(t.affected(format($q$delete from public.purchase_items where purchase_id = %L$q$, pur)), 0::bigint, 'RLS blocks deleting lines of a received purchase');
  perform t.reset();
  perform t.throws(format($q$update public.purchases set notes = 'edit' where id = %L$q$, pur), 'cannot be modified', 'database trigger freezes received purchases (even for service roles)');
  perform t.throws(format($q$insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (%L, %L, 1, 1)$q$, pur, v1),
                   'draft', 'lines cannot be added to a received purchase');
  perform t.throws(format($q$delete from public.purchases where id = %L$q$, pur), 'only draft', 'received purchases cannot be deleted');

  -- stock movement ledger details
  select id into item from public.inventory_items where imei1 = t.imei(511);
  perform t.ok((select from_status is null and to_status = 'in_stock' and created_by = inv from public.stock_movements where inventory_item_id = item),
               'receipt movement records null -> in_stock and the actor');
  perform t.ok((select shelf_location = 'A1' and status = 'in_stock' from public.inventory_items where id = item), 'device stored with shelf and in_stock status');

  -- role scope: manager can receive, sales cannot see costs
  perform t.as_user(mgr);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (sup, 'INV-3003') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 1, 47000) returning id into pi;
  perform t.lives(format($q$select public.receive_purchase('mgr-recv-key-01', %L, %L::jsonb)$q$, pur,
                  jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(531)))::text), 'manager can receive purchases');
  perform t.reset();
end $$;
