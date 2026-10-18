-- Audit trail and append-only guarantees (checked as the database owner, i.e. even trusted code cannot rewrite history).
do $$
declare
  owner_ uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  sales uuid := 'a0000000-0000-0000-0000-000000000003';
  acct uuid := 'a0000000-0000-0000-0000-000000000005';
  p1 uuid := t.fx('p_published');
begin
  perform t.reset();
  perform t.throws($q$update public.audit_logs set action = 'tampered'$q$, 'append-only', 'audit rows cannot be updated');
  perform t.throws($q$delete from public.audit_logs$q$, 'append-only', 'audit rows cannot be deleted');
  perform t.throws($q$update public.invoices set grand_total = 1$q$, 'append-only', 'invoices cannot be updated');
  perform t.throws($q$delete from public.invoices$q$, 'append-only', 'invoices cannot be deleted');
  perform t.throws($q$update public.invoice_items set unit_price = 1$q$, 'append-only', 'invoice lines cannot be updated');
  perform t.throws($q$update public.payments set amount = 1$q$, 'append-only', 'payments cannot be updated');
  perform t.throws($q$delete from public.payments$q$, 'append-only', 'payments cannot be deleted');
  perform t.throws($q$update public.sales set total = 1$q$, 'append-only', 'sales cannot be updated');
  perform t.throws($q$delete from public.sale_items$q$, 'append-only', 'sale lines cannot be deleted');
  perform t.throws($q$update public.stock_movements set to_status = 'in_stock'$q$, 'append-only', 'stock movements cannot be updated');
  perform t.throws($q$delete from public.stock_movements$q$, 'append-only', 'stock movements cannot be deleted');
  perform t.throws($q$update public.inventory_item_costs set cost_price = 1$q$, 'append-only', 'recorded acquisition costs cannot be changed');
  perform t.throws($q$delete from public.staff_profiles$q$, 'cannot be deleted', 'staff profiles cannot be deleted');
  perform t.throws($q$delete from public.shop_settings$q$, 'cannot be deleted', 'shop settings cannot be deleted');

  -- master-data changes are audited with actor and before/after images
  perform t.as_user(mgr);
  update public.products set description = 'Updated description' where id = p1;
  perform t.reset();
  perform t.ok(exists (select 1 from public.audit_logs
                        where table_name = 'products' and record_id = p1::text and action = 'update' and actor_id = mgr and actor_role = 'manager'
                          and old_data ->> 'description' = 'Published test phone' and new_data ->> 'description' = 'Updated description'),
               'product update is audited with actor, role, and before/after values');
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'staff_profiles' and action = 'insert'), 'staff profile creation is audited');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'purchase.received'), 'purchase receipt is audited');
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'expenses' and action = 'insert' and actor_id = acct), 'expense creation is audited');
  perform t.ok((select count(*) from public.audit_logs where action = 'sale.finalized') = (select count(*) from public.sales), 'every sale has exactly one finalisation audit record');

  -- audit visibility
  perform t.as_user(owner_);
  perform t.ok((select count(*) from public.audit_logs) > 0, 'owner can read the audit log');
  perform t.as_user(sales);
  perform t.eq((select count(*) from public.audit_logs), 0::bigint, 'sales executive cannot read the audit log');
  perform t.reset();
end $$;
