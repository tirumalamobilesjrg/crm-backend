-- The two-role model itself: what Admin may do, what Manager may not, removed roles, and audit of sensitive actions.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  mgr2 uuid := 'a0000000-0000-0000-0000-000000000003';
  former uuid := 'a0000000-0000-0000-0000-000000000004';
  nostaff uuid := 'a0000000-0000-0000-0000-000000000007';
  newuser uuid := 'a0000000-0000-0000-0000-000000000009';
  r text; n bigint; apid uuid;
begin
  -- ===== removed roles cannot be assigned or used
  foreach r in array array['owner', 'sales_executive', 'inventory_executive', 'accountant', 'superuser', 'Admin'] loop
    perform t.as_user(adm);
    perform t.throws(format($q$update public.staff_profiles set role = %L where user_id = %L$q$, r, mgr2), '22P02', format('Admin cannot assign the role %L', r));
    perform t.reset();
    perform t.throws(format($q$insert into public.staff_profiles (user_id, full_name, role) values (%L, 'X', %L)$q$, nostaff, r), '22P02', format('profile cannot be created with the role %L (database owner)', r));
    perform t.throws(format($q$insert into public.discount_policies (role, can_discount) values (%L, false)$q$, r), '22P02', format('no discount policy can be created for %L', r));
    perform t.throws(format($q$select %L::public.staff_role$q$, r), '22P02', format('%L is not a valid staff_role', r));
  end loop;
  perform t.throws($q$update public.staff_profiles set role = null$q$, '23502', 'a role is mandatory');
  perform t.eq((select count(*) from public.staff_profiles where role::text not in ('admin', 'manager')), 0::bigint, 'every staff profile is Admin or Manager');
  perform t.eq((select count(*) from public.staff_profiles where role = 'admin' and is_active), 1::bigint, 'exactly one active Admin in the fixtures');

  -- ===== Admin-only powers are denied to a Manager (RLS + trigger, not the frontend)
  perform t.as_user(mgr);
  perform t.throws(format($q$insert into public.staff_profiles (user_id, full_name, role) values (%L, 'Sneaky', 'manager')$q$, nostaff), '42501', 'manager cannot create a staff account');
  perform t.throws(format($q$insert into public.staff_profiles (user_id, full_name, role) values (%L, 'Sneaky', 'admin')$q$, nostaff), '42501', 'manager cannot create an Admin account');
  perform t.eq(t.affected(format($q$update public.staff_profiles set role = 'admin' where user_id = %L$q$, mgr)), 0::bigint, 'manager cannot promote themselves');
  perform t.eq(t.affected(format($q$update public.staff_profiles set role = 'admin' where user_id = %L$q$, mgr2)), 0::bigint, 'manager cannot promote a colleague');
  perform t.eq(t.affected($q$update public.staff_profiles set is_active = false where role = 'admin'$q$), 0::bigint, 'manager cannot deactivate the Admin');
  perform t.eq(t.affected($q$update public.staff_profiles set full_name = 'Renamed' where role = 'manager'$q$), 0::bigint, 'manager cannot edit staff records');
  perform t.eq(t.affected($q$update public.shop_settings set shop_name = 'Hijack'$q$), 0::bigint, 'manager cannot change shop settings');
  perform t.eq(t.affected($q$update public.discount_policies set max_percent = 90 where role = 'manager'$q$), 0::bigint, 'manager cannot raise their own discount limit');
  perform t.eq(t.affected($q$update public.discount_policies set max_percent = 90 where role = 'admin'$q$), 0::bigint, 'manager cannot change the Admin discount policy');
  perform t.throws($q$insert into public.discount_policies (role, can_discount) values ('manager', false)$q$, '42501', 'manager cannot insert discount policies');
  perform t.eq((select count(*) from public.audit_logs), 0::bigint, 'manager cannot read the audit log');
  perform t.throws(format('select public.grant_discount_approval(%L, %L, 100, %L)', 'two-role-key-01', mgr2, 'manager attempt'), '42501', 'manager cannot approve exceptional discounts');

  -- ===== Admin can do all of the above
  perform t.as_user(adm);
  perform t.reset();
  insert into auth.users (id, email) values (newuser, 'new-hire@example.test');
  perform t.as_user(adm);
  perform t.lives(format($q$insert into public.staff_profiles (user_id, full_name, role) values (%L, 'New Hire', 'manager')$q$, newuser), 'Admin can create a staff account');
  perform t.lives(format($q$update public.staff_profiles set role = 'admin' where user_id = %L$q$, newuser), 'Admin can promote a Manager to Admin');
  perform t.lives(format($q$update public.staff_profiles set role = 'manager' where user_id = %L$q$, newuser), 'Admin can change a role back');
  perform t.lives(format($q$update public.staff_profiles set is_active = false where user_id = %L$q$, newuser), 'Admin can deactivate a staff account');
  perform t.lives($q$update public.shop_settings set phone = '0000000000'$q$, 'Admin can change shop settings');
  perform t.lives($q$update public.discount_policies set max_amount = 5000 where role = 'manager'$q$, 'Admin can configure the Manager discount cap');
  perform t.lives($q$update public.discount_policies set max_amount = null where role = 'manager'$q$, '... and remove it again');
  apid := (public.grant_discount_approval('two-role-key-02', mgr2, 1000, 'Admin approval smoke test', 5)->>'approval_id')::uuid;
  perform t.ok(apid is not null, 'Admin can approve an exceptional discount');
  perform t.ok((select count(*) > 0 from public.audit_logs), 'Admin can read the audit log');
  perform t.throws($q$update public.staff_profiles set is_active = false, role = 'manager' where role = 'admin'$q$, 'last active Admin', 'the last active Admin cannot be demoted or deactivated');

  -- ===== Manager can do the Manager's job
  perform t.as_user(mgr);
  perform t.lives($q$insert into public.suppliers (name) values ('Manager Supplier')$q$, 'manager can create suppliers');
  perform t.ok(exists (select 1 from public.staff_profiles where role = 'admin'), 'manager can read the staff list (names for the UI)');
  perform t.ok(exists (select 1 from public.discount_policies where role = 'manager'), 'manager can read their own discount policy');
  perform t.ok(exists (select 1 from public.sales) and exists (select 1 from public.payments) and exists (select 1 from public.inventory_item_costs),
               'manager can read sales, payments and purchase costs for operational reporting');

  -- ===== audit of sensitive actions by both roles (rows were written by the actions above and by the fixtures)
  perform t.reset();
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'staff_profiles' and action = 'insert' and actor_id = adm and actor_role = 'admin'
                        and new_data ->> 'user_id' = newuser::text), 'audit: Admin creating a staff account');
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'staff_profiles' and action = 'update' and actor_id = adm and actor_role = 'admin'
                        and old_data ->> 'role' = 'manager' and new_data ->> 'role' = 'admin'), 'audit: Admin changing a role, with old and new value');
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'discount_policies' and action = 'update' and actor_id = adm and actor_role = 'admin'),
               'audit: Admin changing discount policy');
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'shop_settings' and action = 'update' and actor_id = adm and actor_role = 'admin'),
               'audit: Admin changing shop settings');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'discount.approval_granted' and actor_id = adm and actor_role = 'admin'),
               'audit: Admin granting a discount approval');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'sale.finalized' and actor_role = 'manager'), 'audit: Manager finalizing a sale');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'purchase.received' and actor_role = 'manager'), 'audit: Manager receiving a purchase');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'stock.adjusted' and actor_role = 'manager'), 'audit: Manager adjusting stock');
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'products' and action = 'update' and actor_role = 'manager'), 'audit: Manager publishing a product');
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'expenses' and action = 'insert' and actor_role = 'manager'), 'audit: Manager recording an expense');
  perform t.ok(not exists (select 1 from public.audit_logs where actor_id is not null and actor_role is null and action not like 'stamp%'
                            and actor_id in (adm, mgr, mgr2)), 'audit: every action by a current staff member carries a role');
  perform t.eq((select count(*) from public.audit_logs where actor_role is not null and actor_role not in ('admin', 'manager')), 0::bigint,
               'audit: no row written under this model names a removed role');
  perform t.reset();
end $$;
