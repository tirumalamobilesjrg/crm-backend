-- Stock adjustments: allowed transitions only, always paired with a movement and audit record.
do $$
declare
  inv uuid := 'a0000000-0000-0000-0000-000000000004';
  sales uuid := 'a0000000-0000-0000-0000-000000000003';
  hidden uuid := t.fx('item_hidden');   -- damaged in the fixtures
  sold1 uuid := t.fx('item_sold_1');
  stock uuid := t.fx('item_stock');
  r jsonb; r2 jsonb; mv bigint; adj bigint; aud bigint;
begin
  perform t.reset();
  perform t.eq((select status::text from public.inventory_items where id = hidden), 'damaged', 'fixture adjustment moved the device to damaged');
  perform t.eq((select count(*) from public.stock_movements where inventory_item_id = hidden), 2::bigint, 'damaged device has receipt + adjustment movements');

  perform t.as_user(inv);
  perform t.throws(format($q$select public.adjust_stock('adj-corr-key-001', %L, 'correction', 'quantity-only reason')$q$, stock), 'quantity SKUs', '"correction" is not valid for a serialized device');
  perform t.throws(format($q$select public.adjust_stock('adj-sold-key-01', %L, 'lost', 'sold device cannot be lost')$q$, sold1), 'TM004', 'a sold device cannot be adjusted');
  perform t.throws(format($q$select public.adjust_stock('adj-found-key-1', %L, 'found', 'was never lost')$q$, stock), 'TM004', '"found" only applies to lost devices');
  perform t.throws(format($q$select public.adjust_stock('adj-notes-key-1', %L, 'damaged', ' ')$q$, stock), 'TM003', 'notes are mandatory');
  perform t.throws(format($q$select public.adjust_stock('adj-repair-key1', %L, 'repaired', 'not damaged')$q$, stock), 'TM004', '"repaired" only applies to damaged devices');

  perform t.reset();
  select count(*) into mv from public.stock_movements;
  select count(*) into adj from public.stock_adjustments;
  select count(*) into aud from public.audit_logs where action = 'stock.adjusted';
  perform t.as_user(inv);
  r := public.adjust_stock('adj-repair-ok-01', hidden, 'repaired', 'Screen replaced by service centre');
  r2 := public.adjust_stock('adj-repair-ok-01', hidden, 'repaired', 'Screen replaced by service centre');
  perform t.reset();
  perform t.eq((select status::text from public.inventory_items where id = hidden), 'in_stock', 'repaired device returns to stock');
  perform t.eq((select count(*) from public.stock_movements), mv + 1, 'one movement for the adjustment (replay added none)');
  perform t.eq((select count(*) from public.stock_adjustments), adj + 1, 'one adjustment record (replay added none)');
  perform t.eq((select count(*) from public.audit_logs where action = 'stock.adjusted'), aud + 1, 'one audit record (replay added none)');
  perform t.ok((r2 ->> 'replayed')::boolean, 'replayed adjustment is flagged');

  -- lost -> found cycle, and terminal state
  perform t.as_user(inv);
  perform public.adjust_stock('adj-lost-key-01', hidden, 'lost', 'Missing after stock take');
  perform public.adjust_stock('adj-found-key-2', hidden, 'found', 'Found behind the counter');
  perform public.adjust_stock('adj-rts-key-001', hidden, 'returned_to_supplier', 'Defective batch return');
  perform t.throws(format($q$select public.adjust_stock('adj-after-rts-01', %L, 'found', 'try to resurrect')$q$, hidden), 'TM004', 'returned_to_supplier is terminal');
  perform t.reset();
  perform t.eq((select string_agg(coalesce(from_status::text, '-') || '>' || to_status::text, ' ' order by id) from public.stock_movements where inventory_item_id = hidden),
               '->in_stock in_stock>damaged damaged>in_stock in_stock>lost lost>in_stock in_stock>returned_to_supplier',
               'the ledger reconstructs the device history exactly');
  perform t.eq((select status::text from public.inventory_items i where i.id = hidden),
               (select to_status::text from public.stock_movements where inventory_item_id = hidden order by id desc limit 1), 'item status equals the last ledger movement');

  -- raw movement paths are closed
  perform t.throws(format($q$insert into public.stock_movements (inventory_item_id, movement_type, from_status, to_status, adjustment_id)
                              values (%L, 'adjustment', 'sold', 'in_stock', (select id from public.stock_adjustments limit 1))$q$, sold1),
                   'invalid stock transition', 'a sold device cannot be returned to stock through a raw movement');
  perform t.throws(format($q$insert into public.stock_movements (inventory_item_id, movement_type, from_status, to_status, adjustment_id)
                              values (%L, 'adjustment', 'damaged', 'in_stock', (select id from public.stock_adjustments limit 1))$q$, stock),
                   'is not in status', 'a stale from_status is rejected');
end $$;
