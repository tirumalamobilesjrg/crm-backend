-- Unauthorized operations: direct writes, role limits, and RPC access. Two roles only: Admin and Manager.
-- Identities: a1 Admin, a2 Manager, a3 Manager B, a4/a5 former holders of removed roles (no profile),
--             a6 deactivated Manager, a7 user without a profile.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  mgr2 uuid := 'a0000000-0000-0000-0000-000000000003';
  former uuid := 'a0000000-0000-0000-0000-000000000004';
  former2 uuid := 'a0000000-0000-0000-0000-000000000005';
  inactive uuid := 'a0000000-0000-0000-0000-000000000006';
  nostaff uuid := 'a0000000-0000-0000-0000-000000000007';
  item uuid := t.fx('item_stock');
  p1 uuid := t.fx('p_published');
  v1 uuid := t.fx('v_published');
  one_sale jsonb;
  pay jsonb := '{"method":"cash","amount":1000}';
  who uuid; lbl text;
begin
  one_sale := jsonb_build_array(jsonb_build_object('inventory_item_id', item, 'unit_price', 1000));

  -- ===== nobody writes ledger / financial tables directly, not even the Admin
  perform t.as_user(adm);
  perform t.throws(format($q$update public.inventory_items set status = 'sold' where id = %L$q$, item), '42501', 'admin cannot update inventory_items directly');
  perform t.throws(format($q$insert into public.inventory_items (variant_id, purchase_item_id, imei1) values (%L, %L, %L)$q$, v1, t.fx('pi1'), t.imei(777)),
                   '42501', 'admin cannot insert inventory_items directly');
  perform t.throws($q$insert into public.stock_movements (inventory_item_id, movement_type, to_status) values (gen_random_uuid(), 'sale', 'sold')$q$,
                   '42501', 'admin cannot insert stock_movements directly');
  perform t.throws($q$insert into public.payments (sale_id, invoice_id, method, amount, received_by) values (gen_random_uuid(), gen_random_uuid(), 'cash', 1, gen_random_uuid())$q$,
                   '42501', 'admin cannot insert payments directly');
  perform t.throws($q$insert into public.stock_levels (variant_id, on_hand) values (gen_random_uuid(), 5)$q$, '42501', 'admin cannot write stock_levels directly');
  perform t.throws($q$update public.discount_approvals set max_amount = 999999$q$, '42501', 'admin cannot edit discount approvals directly');
  perform t.throws($q$insert into public.inventory_identifier_corrections (inventory_item_id, reason, corrected_by) values (gen_random_uuid(), 'forged correction', gen_random_uuid())$q$,
                   '42501', 'admin cannot insert identifier corrections directly');
  perform t.throws($q$delete from public.audit_logs$q$, '42501', 'admin cannot delete audit logs');
  perform t.throws($q$update public.audit_logs set action = 'x'$q$, '42501', 'admin cannot edit audit logs');
  perform t.throws($q$insert into public.audit_logs (action) values ('forged')$q$, '42501', 'admin cannot forge audit logs');
  perform t.throws($q$select * from public.idempotency_keys$q$, '42501', 'admin cannot read idempotency keys');
  perform t.throws($q$truncate public.sales$q$, '42501', 'admin cannot truncate sales');
  perform t.throws($q$delete from public.discount_policies$q$, '42501', 'nobody can delete discount policies');
  perform t.as_user(mgr);
  perform t.throws(format($q$update public.inventory_items set status = 'sold' where id = %L$q$, item), '42501', 'manager cannot update inventory_items directly');
  perform t.throws($q$insert into public.payments (sale_id, invoice_id, method, amount, received_by) values (gen_random_uuid(), gen_random_uuid(), 'cash', 1, gen_random_uuid())$q$,
                   '42501', 'manager cannot insert payments directly');
  perform t.throws($q$insert into public.stock_levels (variant_id, on_hand) values (gen_random_uuid(), 5)$q$, '42501', 'manager cannot write stock_levels directly');
  perform t.reset();
  perform t.throws($q$update public.stock_levels set on_hand = 1000$q$, 'only through stock_movements', 'even the database owner cannot edit stock_levels outside a movement');
  perform t.throws($q$update public.discount_policies set can_approve = true, can_discount = false where role = 'admin'$q$, '23514', 'inconsistent discount policy is rejected');
  perform t.throws($q$update public.discount_policies set can_approve = true where role = 'manager'$q$, '23514', 'a Manager can never be given the right to approve discounts');

  -- ===== catalogue and publication: allowed to both roles
  perform t.as_user(mgr);
  perform t.lives($q$insert into public.brands (name, slug) values ('Mgr Brand', 'mgr-brand')$q$, 'manager can create brands');
  perform t.lives(format($q$update public.products set is_published = false where id = %L$q$, p1), 'manager can unpublish a product');
  perform t.lives(format($q$update public.products set is_published = true where id = %L$q$, p1), 'manager can publish a product');
  perform t.throws(format($q$update public.product_variants set public_price = 12345 where id = %L$q$, v1), '42501', 'manager cannot set the public price (0024: prices are Admin-only)');
  perform t.throws(format($q$insert into public.product_variants (product_id, sku, mrp, selling_price) values (%L, 'MGR-SKU', 100, 90)$q$, p1), '42501', 'manager cannot create a variant with prices (0024)');
  perform t.as_user(adm);
  perform t.lives($q$insert into public.brands (name, slug) values ('Admin Brand', 'admin-brand')$q$, 'admin can create brands');

  -- ===== customers and expenses: both roles record, only the Admin deletes
  perform t.as_user(mgr2);
  perform t.lives($q$insert into public.customers (name, phone) values ('Walk Buyer', '9000000001')$q$, 'manager can create customers');
  perform t.lives($q$update public.customers set notes = 'prefers UPI' where phone = '9000000001'$q$, 'manager can update customers');
  perform t.throws($q$insert into public.customers (name, phone) values ('Dup Phone', '9000000001')$q$, '23505', 'customer phone is unique');
  perform t.eq(t.affected($q$delete from public.customers where phone = '9000000001'$q$), 0::bigint, 'manager cannot delete customers');
  perform t.lives($q$insert into public.expenses (category, amount) values ('Tea', 100)$q$, 'manager can record expenses');
  perform t.throws($q$insert into public.expenses (category, amount) values ('Free', 0)$q$, '23514', 'expense amount must be positive');
  perform t.eq(t.affected($q$delete from public.expenses where category = 'Tea'$q$), 0::bigint, 'manager cannot delete expenses');
  perform t.as_user(adm);
  perform t.eq(t.affected($q$delete from public.expenses where category = 'Tea'$q$), 1::bigint, 'admin can delete expenses');
  perform t.eq(t.affected($q$delete from public.customers where phone = '9000000001'$q$), 1::bigint, 'admin can delete customers');

  -- ===== RPC access: only an active Admin or Manager; nobody else, whatever they used to be
  for who, lbl in select * from (values (former, 'former inventory-role account without a profile'), (former2, 'former accountant-role account without a profile'),
                                         (nostaff, 'user without a profile'), (inactive, 'deactivated manager')) v(a, b) loop
    perform t.as_user(who);
    perform t.throws(format('select public.finalize_sale(%L, null, %L::jsonb, %L::jsonb)', 'noaccess-key-01', one_sale, pay), '42501', lbl || ' cannot sell');
    perform t.throws(format('select public.receive_purchase(%L, gen_random_uuid(), %L::jsonb)', 'noaccess-key-02', '[]'), '42501', lbl || ' cannot receive purchases');
    perform t.throws(format('select public.adjust_stock(%L, %L, %L, %L)', 'noaccess-key-03', item, 'damaged', 'no access attempt'), '42501', lbl || ' cannot adjust stock');
    perform t.throws(format('select public.adjust_quantity_stock(%L, %L, -1, %L, %L)', 'noaccess-key-04', t.fx('v_case'), 'damaged', 'no access attempt'), '42501', lbl || ' cannot adjust quantity stock');
    perform t.throws(format('select public.correct_item_identifiers(%L, %L, %L::jsonb, %L)', 'noaccess-key-05', item, '{"imei2":null}', 'attempt without any role'), '42501', lbl || ' cannot correct identifiers');
    perform t.throws(format('select public.grant_discount_approval(%L, %L, 100, %L)', 'noaccess-key-06', mgr, 'attempt without any role'), '42501', lbl || ' cannot grant approvals');
  end loop;
  perform t.as_anon();
  perform t.throws(format('select public.finalize_sale(%L, null, %L::jsonb, %L::jsonb)', 'anon-key-0001', one_sale, pay), '42501', 'anon cannot call finalize_sale');
  perform t.throws(format('select public.receive_purchase(%L, gen_random_uuid(), %L::jsonb)', 'anon-key-0002', '[]'), '42501', 'anon cannot call receive_purchase');
  perform t.throws(format('select public.adjust_stock(%L, %L, %L, %L)', 'anon-key-0003', item, 'damaged', 'anon attempt'), '42501', 'anon cannot call adjust_stock');
  perform t.throws(format('select public.adjust_quantity_stock(%L, gen_random_uuid(), -1, %L, %L)', 'anon-key-0004', 'damaged', 'anon attempt'), '42501', 'anon cannot call adjust_quantity_stock');
  perform t.throws(format('select public.correct_item_identifiers(%L, %L, %L::jsonb, %L)', 'anon-key-0005', item, '{"imei2":null}', 'anon attempt at correction'), '42501', 'anon cannot call correct_item_identifiers');
  perform t.throws(format('select public.grant_discount_approval(%L, %L, 100, %L)', 'anon-key-0006', mgr, 'anon attempt'), '42501', 'anon cannot call grant_discount_approval');

  -- Manager-only limits on the RPC surface: approvals are an Admin power
  perform t.as_user(mgr);
  perform t.throws(format('select public.grant_discount_approval(%L, %L, 100, %L)', 'mgr-key-000001', mgr2, 'manager self-service approval'), '42501', 'manager cannot grant discount approvals');

  perform t.reset();
  perform t.eq((select status::text from public.inventory_items where id = item), 'in_stock', 'no unauthorized call changed the stock');
  perform t.eq((select on_hand from public.stock_levels where variant_id = t.fx('v_case')), 48, 'no unauthorized call changed accessory stock');
end $$;
