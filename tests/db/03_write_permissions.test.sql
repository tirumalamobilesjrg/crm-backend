-- Unauthorized operations: direct writes, role limits, and RPC access by role.
do $$
declare
  owner_ uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  sales uuid := 'a0000000-0000-0000-0000-000000000003';
  inv uuid := 'a0000000-0000-0000-0000-000000000004';
  acct uuid := 'a0000000-0000-0000-0000-000000000005';
  inactive uuid := 'a0000000-0000-0000-0000-000000000006';
  nostaff uuid := 'a0000000-0000-0000-0000-000000000007';
  item uuid := t.fx('item_stock');
  p1 uuid := t.fx('p_published');
  v1 uuid := t.fx('v_published');
  empty_items jsonb := '[]';
  one_sale jsonb;
  pay jsonb := '[{"method":"cash","amount":1}]';
begin
  one_sale := jsonb_build_array(jsonb_build_object('inventory_item_id', item, 'unit_price', 1000));

  -- catalogue writes
  perform t.as_user(sales);
  perform t.throws($q$insert into public.brands (name, slug) values ('X', 'x')$q$, '42501', 'sales executive cannot create brands');
  perform t.eq(coalesce((select count(*) from (select 1 from public.products limit 1) s), 0), 1::bigint, 'sales executive can read products');
  perform t.as_user(acct);
  perform t.throws($q$insert into public.brands (name, slug) values ('Y', 'y')$q$, '42501', 'accountant cannot create brands');
  perform t.as_user(inv);
  perform t.lives($q$insert into public.brands (name, slug) values ('Inv Brand', 'inv-brand')$q$, 'inventory executive can create brands');

  -- publication is owner/manager only
  perform t.throws(format($q$update public.products set is_published = false where id = %L$q$, p1), '42501',
                   'inventory executive cannot unpublish a product');
  perform t.throws(format($q$update public.product_variants set public_price = 1 where id = %L$q$, v1), '42501',
                   'inventory executive cannot change the public price');
  perform t.throws(format($q$insert into public.products (brand_id, category_id, name, slug, is_published)
                              values (%L, %L, 'Sneaky', 'sneaky', true)$q$, t.fx('brand'), t.fx('category')), '42501',
                   'inventory executive cannot create an already-published product');
  perform t.as_user(mgr);
  perform t.lives(format($q$update public.product_variants set public_price = 69999 where id = %L$q$, v1), 'manager can set the public price');

  -- customers
  perform t.as_user(inv);
  perform t.throws($q$insert into public.customers (name) values ('Nope')$q$, '42501', 'inventory executive cannot create customers');
  perform t.as_user(sales);
  perform t.lives($q$insert into public.customers (name, phone) values ('Walk Buyer', '9000000001')$q$, 'sales executive can create customers');
  perform t.throws($q$insert into public.customers (name, phone) values ('Dup Phone', '9000000001')$q$, '23505', 'customer phone is unique');
  perform t.eq(t.affected($q$delete from public.customers where phone = '9000000001'$q$), 0::bigint,
               'sales executive delete of a customer affects no rows');

  -- expenses
  perform t.as_user(sales);
  perform t.throws($q$insert into public.expenses (category, amount) values ('Tea', 100)$q$, '42501', 'sales executive cannot record expenses');
  perform t.as_user(acct);
  perform t.lives($q$insert into public.expenses (category, amount) values ('Tea', 100)$q$, 'accountant can record expenses');
  perform t.throws($q$insert into public.expenses (category, amount) values ('Free', 0)$q$, '23514', 'expense amount must be positive');

  -- staff management is owner only
  perform t.as_user(mgr);
  perform t.throws($q$insert into public.staff_profiles (user_id, full_name, role) values ('a0000000-0000-0000-0000-000000000007', 'X', 'owner')$q$,
                   '42501', 'manager cannot create staff profiles (no self-service privilege escalation)');
  perform t.eq(t.affected(format($q$update public.staff_profiles set role = 'owner' where user_id = %L$q$, mgr)), 0::bigint,
               'manager cannot promote themselves');
  perform t.as_user(sales);
  perform t.eq(t.affected(format($q$update public.staff_profiles set role = 'owner' where user_id = %L$q$, sales)), 0::bigint,
               'sales executive cannot promote themselves');
  perform t.as_user(owner_);
  perform t.throws($q$update public.staff_profiles set is_active = false where role = 'owner'$q$, 'last active owner',
                   'the last active owner cannot be deactivated');
  perform t.eq(t.affected($q$update public.shop_settings set shop_name = 'Tirumala Mobiles'$q$), 1::bigint,
               'owner can update shop settings');
  perform t.as_user(mgr);
  perform t.eq(t.affected($q$update public.shop_settings set shop_name = 'Hijack'$q$), 0::bigint,
               'manager cannot update shop settings');

  -- nobody writes ledger tables directly, not even the owner
  perform t.as_user(owner_);
  perform t.throws(format($q$update public.inventory_items set status = 'sold' where id = %L$q$, item), '42501', 'owner cannot update inventory_items directly');
  perform t.throws(format($q$insert into public.inventory_items (variant_id, purchase_item_id, imei1) values (%L, %L, %L)$q$, v1, t.fx('pi1'), t.imei(777)),
                   '42501', 'owner cannot insert inventory_items directly');
  perform t.throws($q$insert into public.stock_movements (inventory_item_id, movement_type, to_status) values (gen_random_uuid(), 'sale', 'sold')$q$,
                   '42501', 'owner cannot insert stock_movements directly');
  perform t.throws($q$insert into public.payments (sale_id, invoice_id, method, amount, received_by) values (gen_random_uuid(), gen_random_uuid(), 'cash', 1, gen_random_uuid())$q$,
                   '42501', 'owner cannot insert payments directly');
  perform t.throws($q$delete from public.audit_logs$q$, '42501', 'owner cannot delete audit logs');
  perform t.throws($q$update public.audit_logs set action = 'x'$q$, '42501', 'owner cannot edit audit logs');
  perform t.throws($q$insert into public.audit_logs (action) values ('forged')$q$, '42501', 'owner cannot forge audit logs');
  perform t.throws($q$select * from public.idempotency_keys$q$, '42501', 'owner cannot read idempotency keys');
  perform t.throws($q$truncate public.sales$q$, '42501', 'owner cannot truncate sales');

  -- RPC access by role
  perform t.as_anon();
  perform t.throws(format('select public.finalize_sale(%L, null, %L::jsonb, %L::jsonb)', 'anon-key-0001', one_sale, pay), '42501', 'anon cannot call finalize_sale');
  perform t.throws(format('select public.receive_purchase(%L, gen_random_uuid(), %L::jsonb)', 'anon-key-0002', '[]'), '42501', 'anon cannot call receive_purchase');
  perform t.throws(format('select public.adjust_stock(%L, %L, %L, %L)', 'anon-key-0003', item, 'damaged', 'anon attempt'), '42501', 'anon cannot call adjust_stock');
  perform t.as_user(nostaff);
  perform t.throws(format('select public.finalize_sale(%L, null, %L::jsonb, %L::jsonb)', 'nostaff-key-01', one_sale, pay), '42501', 'user without a staff profile cannot sell');
  perform t.as_user(inactive);
  perform t.throws(format('select public.finalize_sale(%L, null, %L::jsonb, %L::jsonb)', 'inactive-key-01', one_sale, pay), '42501', 'deactivated staff cannot sell');
  perform t.as_user(acct);
  perform t.throws(format('select public.finalize_sale(%L, null, %L::jsonb, %L::jsonb)', 'acct-key-00001', one_sale, pay), '42501', 'accountant cannot sell');
  perform t.throws(format('select public.adjust_stock(%L, %L, %L, %L)', 'acct-key-00002', item, 'damaged', 'accountant attempt'), '42501', 'accountant cannot adjust stock');
  perform t.as_user(inv);
  perform t.throws(format('select public.finalize_sale(%L, null, %L::jsonb, %L::jsonb)', 'inv-key-000001', one_sale, pay), '42501', 'inventory executive cannot sell');
  perform t.as_user(sales);
  perform t.throws(format('select public.receive_purchase(%L, %L, %L::jsonb)', 'sales-key-00001', t.fx('purchase'), '[{}]'), '42501', 'sales executive cannot receive purchases');
  perform t.throws(format('select public.adjust_stock(%L, %L, %L, %L)', 'sales-key-00002', item, 'damaged', 'sales attempt'), '42501', 'sales executive cannot adjust stock');
  perform t.reset();
  perform t.eq((select status::text from public.inventory_items where id = item), 'in_stock', 'no unauthorized call changed the stock');
end $$;
