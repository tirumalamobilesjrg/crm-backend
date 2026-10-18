-- IMEI / serial uniqueness and device identity rules.
do $$
declare
  inv uuid := 'a0000000-0000-0000-0000-000000000002';
  sup uuid := t.fx('supplier');
  v1 uuid := t.fx('v_published');
  v2 uuid := t.fx('v_hidden');
  pur uuid; pi uuid; r jsonb;
  existing_imei text := t.imei(1);
  existing_imei2 text := t.imei(101);
  n_before bigint;
begin
  select count(*) into n_before from public.inventory_items;
  perform t.ok(app.is_valid_imei(t.imei(1)) and app.is_valid_imei('490154203237518'), 'Luhn validator accepts valid IMEIs');
  perform t.ok(not app.is_valid_imei('490154203237519') and not app.is_valid_imei('1234') and not app.is_valid_imei(null),
               'Luhn validator rejects bad check digit, short and null values');

  perform t.as_user(inv);
  -- a fresh draft purchase to receive into
  insert into public.purchases (supplier_id, supplier_invoice_no) values (sup, 'INV-2001') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 2, 49000) returning id into pi;

  -- duplicate of an existing IMEI-1
  perform t.throws(format($q$select public.receive_purchase('imei-dup-key-1', %L, %L::jsonb)$q$, pur,
      jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', existing_imei),
                        jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(201)))::text), '23505',
      'duplicate IMEI-1 is rejected');
  -- IMEI-2 colliding with another device's IMEI-1 (cross-column)
  perform t.throws(format($q$select public.receive_purchase('imei-dup-key-2', %L, %L::jsonb)$q$, pur,
      jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(202), 'imei2', existing_imei),
                        jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(203)))::text), '23505',
      'IMEI-2 equal to another device IMEI-1 is rejected');
  -- IMEI-1 colliding with another device's IMEI-2
  perform t.throws(format($q$select public.receive_purchase('imei-dup-key-3', %L, %L::jsonb)$q$, pur,
      jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', existing_imei2),
                        jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(204)))::text), '23505',
      'IMEI-1 equal to another device IMEI-2 is rejected');
  -- duplicate inside the same request
  perform t.throws(format($q$select public.receive_purchase('imei-dup-key-4', %L, %L::jsonb)$q$, pur,
      jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(205)),
                        jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(205)))::text), '23505',
      'the same IMEI twice in one request is rejected');
  -- invalid check digit / format / missing identifier / same IMEI in both slots
  perform t.throws(format($q$select public.receive_purchase('imei-bad-key-1', %L, %L::jsonb)$q$, pur,
      jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', '490154203237519'),
                        jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(206)))::text), '23514', 'IMEI with a bad check digit is rejected');
  perform t.throws(format($q$select public.receive_purchase('imei-bad-key-2', %L, %L::jsonb)$q$, pur,
      jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'condition', 'new'),
                        jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(207)))::text), '23514', 'a device with no IMEI or serial is rejected');
  perform t.throws(format($q$select public.receive_purchase('imei-bad-key-3', %L, %L::jsonb)$q$, pur,
      jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(208), 'imei2', t.imei(208)),
                        jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(209)))::text), '23514', 'IMEI-1 equal to IMEI-2 on one device is rejected');
  -- serial numbers are normalised to upper case and unique case-insensitively
  perform t.throws(format($q$select public.receive_purchase('serial-dup-key', %L, %L::jsonb)$q$, pur,
      jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'serial_number', 'SN-HID-0001'),
                        jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(210)))::text), '23505', 'duplicate serial (different case) is rejected');

  perform t.reset();
  perform t.eq((select count(*) from public.inventory_items), n_before, 'rejected receipts left no inventory rows behind');
  perform t.eq((select status::text from public.purchases where id = pur), 'draft', 'rejected receipts left the purchase as a draft');
  perform t.eq((select count(*) from public.idempotency_keys where idem_key like 'imei-%'), 0::bigint, 'rejected receipts stored no idempotency keys');

  -- identity is immutable even for the database owner
  perform t.throws(format($q$update public.inventory_items set imei1 = %L where imei1 = %L$q$, t.imei(300), existing_imei), 'correct_item_identifiers', 'IMEI cannot be edited directly (only via the audited correction function)');
  perform t.throws(format($q$update public.inventory_items set variant_id = %L where imei1 = %L$q$, v2, existing_imei), 'immutable', 'variant of a device cannot be changed');
  perform t.throws(format($q$delete from public.inventory_items where imei1 = %L$q$, existing_imei), 'cannot be deleted', 'inventory items cannot be deleted');
  perform t.throws(format($q$update public.inventory_items set status = 'damaged' where imei1 = %L$q$, existing_imei), 'only through stock_movements', 'status cannot be changed without a stock movement');
  perform t.throws($q$delete from public.inventory_identifiers$q$, 'cannot be deleted', 'identifier registry rows cannot be removed');
  perform t.throws($q$update public.inventory_identifiers set value = 'x'$q$, 'correct_item_identifiers', 'identifier registry rows cannot be edited outside a correction');
  perform t.eq((select count(*) from public.inventory_identifiers where retired_at is null), (select count(*) filter (where imei1 is not null) + count(*) filter (where imei2 is not null) + count(*) filter (where serial_number is not null) from public.inventory_items),
               'active identifier registry rows match the inventory');
  perform t.throws(format($q$insert into public.inventory_items (variant_id, purchase_item_id, imei1) values (%L, %L, %L)$q$, t.fx('v_case'), pi, t.imei(399)),
                   'serialized SKUs', 'a device cannot be created for a quantity-tracked SKU');

  -- a device row inserted without its receipt movement fails at commit
  set constraints all immediate;
  perform t.throws(format($q$insert into public.inventory_items (variant_id, purchase_item_id, imei1) values (%L, %L, %L)$q$, v1, pi, t.imei(400)),
                   'no purchase_receipt movement', 'inventory item without a receipt movement fails the commit check');
  set constraints all deferred;
end $$;
