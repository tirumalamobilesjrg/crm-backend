-- Controlled IMEI/serial corrections: validation, duplicates, preserved history, audit, authority.
do $$
declare
  owner_ uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  inv uuid := 'a0000000-0000-0000-0000-000000000004';
  v1 uuid := t.fx('v_published');
  pur uuid; pi uuid; d1 uuid; d2 uuid; d3 uuid; r jsonb; n_before bigint; c public.inventory_identifier_corrections;
begin
  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-7001') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 3, 50000) returning id into pi;
  -- the first device was keyed with a typo (2001 instead of 2004)
  perform public.receive_purchase('corr-recv-00001', pur, jsonb_build_array(
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(2001)),
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(2002), 'imei2', t.imei(2102)),
    jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(2003))));
  perform t.reset();
  select id into d1 from public.inventory_items where imei1 = t.imei(2001);
  select id into d2 from public.inventory_items where imei1 = t.imei(2002);
  select id into d3 from public.inventory_items where imei1 = t.imei(2003);

  -- ===== authority and input validation
  perform t.as_user(inv);
  perform t.throws(format($q$select public.correct_item_identifiers('corr-auth-000001', %L, %L::jsonb, 'inventory exec is not allowed')$q$, d1, jsonb_build_object('imei1', t.imei(2004))::text),
                   '42501', 'inventory executive cannot correct identifiers');
  perform t.as_user(owner_);
  perform t.throws(format($q$select public.correct_item_identifiers('corr-reason-0001', %L, %L::jsonb, 'typo')$q$, d1, jsonb_build_object('imei1', t.imei(2004))::text), 'TM003', 'a short reason is rejected');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-nochange-01', %L, %L::jsonb, 'identical values supplied')$q$, d1, jsonb_build_object('imei1', t.imei(2001))::text), 'identical', 'a no-op correction is rejected');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-empty-00001', %L, '{}', 'nothing to change here')$q$, d1), 'identical', 'an empty change set is rejected');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-badkey-0001', %L, '{"status":"sold"}', 'attempt to change status')$q$, d1), 'TM003', 'only identifier fields are accepted');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-luhn-00001', %L, %L::jsonb, 'new IMEI has a bad check digit')$q$, d1, '{"imei1":"490154203237519"}'), '23514', 'a new IMEI with a bad check digit is rejected');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-noid-000001', %L, '{"imei1":null}', 'removing the only identifier')$q$, d1), '23514', 'a device cannot be left without any identifier');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-nodev-000001', gen_random_uuid(), %L::jsonb, 'device does not exist at all')$q$, jsonb_build_object('imei1', t.imei(2004))::text), 'does not exist', 'unknown device');

  -- ===== duplicates are rejected and leave no trace
  select count(*) into n_before from public.inventory_identifier_corrections;
  perform t.throws(format($q$select public.correct_item_identifiers('corr-dup-0000001', %L, %L::jsonb, 'trying to take another device IMEI')$q$, d2, jsonb_build_object('imei1', t.imei(2003))::text), '23505', 'correcting to another device IMEI-1 is rejected');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-dup-0000002', %L, %L::jsonb, 'IMEI-2 equal to another device IMEI-1')$q$, d2, jsonb_build_object('imei2', t.imei(2003))::text), '23505', 'IMEI-2 equal to another device IMEI-1 is rejected');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-dup-0000003', %L, %L::jsonb, 'IMEI-1 equal to another device IMEI-2')$q$, d3, jsonb_build_object('imei1', t.imei(2102))::text), '23505', 'IMEI-1 equal to another device IMEI-2 is rejected');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-dup-0000004', %L, %L::jsonb, 'same IMEI in both slots of one device')$q$, d3, jsonb_build_object('imei2', t.imei(2003))::text), '23514', 'IMEI-1 = IMEI-2 on one device is rejected');
  perform t.reset();
  perform t.eq((select count(*) from public.inventory_identifier_corrections), n_before, 'rejected corrections left no correction rows');
  perform t.ok((select imei1 = t.imei(2002) and imei2 = t.imei(2102) from public.inventory_items where id = d2), 'the device is unchanged after a rejected correction');
  perform t.eq((select count(*) from public.idempotency_keys where idem_key like 'corr-dup-%'), 0::bigint, 'rejected corrections stored no idempotency keys');

  -- ===== a valid correction (owner)
  perform t.as_user(owner_);
  r := public.correct_item_identifiers('corr-good-000001', d1, jsonb_build_object('imei1', t.imei(2004)), 'Typo at goods receipt: digits transposed');
  perform t.ok((public.correct_item_identifiers('corr-good-000001', d1, jsonb_build_object('imei1', t.imei(2004)), 'Typo at goods receipt: digits transposed') ->> 'replayed')::boolean,
               'repeating the same correction request is idempotent');
  perform t.reset();
  perform t.eq((select imei1 from public.inventory_items where id = d1), t.imei(2004), 'the device now carries the corrected IMEI');
  select * into c from public.inventory_identifier_corrections where inventory_item_id = d1;
  perform t.ok(c.old_imei1 = t.imei(2001) and c.new_imei1 = t.imei(2004) and c.corrected_by = owner_ and c.reason like 'Typo at goods receipt%',
               'correction record keeps old value, new value, actor and reason');
  perform t.eq((select count(*) from public.inventory_identifier_corrections where inventory_item_id = d1), 1::bigint, 'replay did not add a second correction');
  perform t.ok((select count(*) = 2 and count(*) filter (where retired_at is null) = 1 from public.inventory_identifiers where inventory_item_id = d1),
               'identifier history keeps both values, only the new one is active');
  perform t.ok((select retired_by = owner_ and value = t.imei(2001) from public.inventory_identifiers where inventory_item_id = d1 and retired_at is not null),
               'the retired value records who retired it');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'identifier.corrected' and record_id = d1::text and actor_id = owner_ and actor_role = 'owner'
                        and detail ->> 'correction_id' = c.id::text), 'correction is in the audit log');
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'inventory_items' and record_id = d1::text and action = 'update'
                        and old_data ->> 'imei1' = t.imei(2001) and new_data ->> 'imei1' = t.imei(2004)), 'row-level audit shows before and after');

  -- ===== a retired value can legitimately be used by another device; active values stay protected
  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-7002') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 2, 50000) returning id into pi;
  perform t.lives(format($q$select public.receive_purchase('corr-reuse-00001', %L, %L::jsonb)$q$, pur,
       jsonb_build_array(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(2001)), jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(2005)))::text),
       'a corrected-away IMEI can be received on another device');
  perform t.throws(format($q$select public.correct_item_identifiers('corr-back-000001', %L, %L::jsonb, 'revert to the value another device now holds')$q$, d1, jsonb_build_object('imei1', t.imei(2001))::text) , '42501', 'inventory exec cannot (authority check first)');
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.correct_item_identifiers('corr-back-000002', %L, %L::jsonb, 'revert to the value another device now holds')$q$, d1, jsonb_build_object('imei1', t.imei(2001))::text), '23505', 'but the value is protected again once another device holds it');

  -- ===== manager can correct; swap and clear
  r := public.correct_item_identifiers('corr-swap-000001', d2, jsonb_build_object('imei1', t.imei(2102), 'imei2', t.imei(2002)), 'IMEI slots were entered in the wrong order');
  perform t.reset();
  perform t.ok((select imei1 = t.imei(2102) and imei2 = t.imei(2002) from public.inventory_items where id = d2), 'IMEI-1 and IMEI-2 can be swapped');
  perform t.eq((select count(*) from public.inventory_identifiers where inventory_item_id = d2 and retired_at is null), 2::bigint, 'swap leaves exactly two active identifiers');
  perform t.as_user(mgr);
  perform public.correct_item_identifiers('corr-clear-000001', d2, '{"imei2":null}', 'Device is single SIM; second IMEI was invented');
  perform t.reset();
  perform t.ok((select imei2 is null from public.inventory_items where id = d2), 'IMEI-2 can be cleared');
  perform t.eq((select count(*) from public.inventory_identifiers where inventory_item_id = d2), 4::bigint, 'history of the swapped and cleared values is preserved (4 rows)');
  perform t.ok((select count(*) = 3 from public.inventory_identifier_corrections where inventory_item_id = d2 or inventory_item_id = d1) , 'three corrections in total across the two devices');

  -- ===== sold devices can be corrected; invoices keep what was issued
  perform t.reset();
  perform t.ok((select imei1 = t.imei(1) from public.invoice_items where invoice_id = t.fx('invoice_by_sales')), 'before: invoice shows the original IMEI');
  perform t.as_user(owner_);
  perform public.correct_item_identifiers('corr-sold-000001', t.fx('item_sold_1'), jsonb_build_object('imei2', t.imei(2201)), 'Second IMEI read from the box after sale');
  perform t.reset();
  perform t.ok((select imei1 = t.imei(1) and imei2 = t.imei(101) from public.invoice_items where invoice_id = t.fx('invoice_by_sales')), 'after: the issued invoice is unchanged (immutable snapshot)');
  perform t.eq((select status::text from public.inventory_items where id = t.fx('item_sold_1')), 'sold', 'a correction does not change stock status');
  perform t.eq((select count(*) from public.stock_movements where inventory_item_id = t.fx('item_sold_1')), 2::bigint, 'and creates no stock movement');

  -- ===== history is tamper-proof
  perform t.throws(format($q$update public.inventory_identifier_corrections set reason = 'rewritten history' where inventory_item_id = %L$q$, d1), 'append-only', 'correction records cannot be edited');
  perform t.throws(format($q$delete from public.inventory_identifier_corrections where inventory_item_id = %L$q$, d1), 'append-only', 'correction records cannot be deleted');
  perform t.throws(format($q$delete from public.inventory_identifiers where inventory_item_id = %L$q$, d1), 'cannot be deleted', 'identifier history cannot be deleted');
  perform t.throws(format($q$update public.inventory_identifiers set retired_at = null, retired_by = null where inventory_item_id = %L$q$, d1), 'correct_item_identifiers', 'retired identifiers cannot be reactivated by hand');
  perform t.throws(format($q$update public.inventory_items set imei1 = %L where id = %L$q$, t.imei(2999), d3), 'correct_item_identifiers', 'direct IMEI edits remain blocked');
  perform t.eq((select count(*) from public.inventory_items i where not exists (select 1 from public.inventory_identifiers r where r.inventory_item_id = i.id and r.value = coalesce(i.imei1, i.serial_number) and r.retired_at is null)), 0::bigint,
               'invariant: every device primary identifier has exactly its active registry row');
  perform t.eq((select count(*) from (select value from public.inventory_identifiers where retired_at is null group by value having count(*) > 1) x), 0::bigint, 'invariant: no active identifier value appears twice');
end $$;
