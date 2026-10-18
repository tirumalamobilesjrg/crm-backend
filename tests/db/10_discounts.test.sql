-- Admin-managed discount policy, Manager limits, approvals, authorisation record and audit trail.
-- All checks are server-side. Fixtures leave the Manager policy at 10 % per line, no per-sale cap.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  mgr2 uuid := 'a0000000-0000-0000-0000-000000000003';
  inactive uuid := 'a0000000-0000-0000-0000-000000000006';
  nostaff uuid := 'a0000000-0000-0000-0000-000000000007';
  adm2 uuid := 'a0000000-0000-0000-0000-00000000000a';
  v1 uuid := t.fx('v_published');
  pur uuid; pi uuid; d uuid[]; a jsonb; a2 jsonb; r jsonb; sale_row public.sales; appr_id uuid;
begin
  -- 14 devices, price 10000 each, to spend on discount scenarios
  perform t.as_user(mgr);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-5001') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 14, 50000) returning id into pi;
  perform public.receive_purchase('disc-stock-recv', pur,
    (select jsonb_agg(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(1000 + g))) from generate_series(1, 14) g));
  perform t.reset();
  select array_agg(id order by imei1) into d from public.inventory_items where imei1 between t.imei(1001) and t.imei(1014);

  -- policy rows are data
  perform t.eq((select max_percent from public.discount_policies where role = 'manager'), 10.00, 'Manager limit is a row in discount_policies (set by the Admin in the fixtures)');
  perform t.ok((select can_discount and not can_approve and max_amount is null and configured_by = adm from public.discount_policies where role = 'manager'),
               'Manager policy: may discount, may not approve, no cap, configured by the Admin');
  perform t.eq((select count(*) from public.discount_policies), 2::bigint, 'only Admin and Manager policies exist (no per-role rows for removed roles)');

  -- ===== Manager within the configured limit
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-nr-key-001', null, %L::jsonb, '{"method":"cash","amount":9000}'::jsonb)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[1], 'unit_price', 10000, 'discount_amount', 1000))::text),
       'discount reason is required', 'a discount without a reason is rejected');
  perform t.throws(format($q$select public.finalize_sale('disc-over-key-1', null, %L::jsonb, '{"method":"cash","amount":8999}'::jsonb, null, 'Haggling')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[1], 'unit_price', 10000, 'discount_amount', 1001))::text),
       'TM005', 'a Manager discount above the configured 10 % is rejected');
  r := public.finalize_sale('disc-ok-key-001', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[1], 'unit_price', 10000, 'discount_amount', 1000)),
       '{"method":"cash","amount":9000}', null, 'Repeat customer');
  perform t.reset();
  select * into sale_row from public.sales where id = (r ->> 'sale_id')::uuid;
  perform t.ok(sale_row.discount_total = 1000 and sale_row.discount_basis = 'role_limit' and sale_row.discount_authorized_by = mgr
               and sale_row.discount_reason = 'Repeat customer' and sale_row.discount_approval_id is null, 'discount within the limit records amount, basis, authoriser and reason');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'sale.finalized' and record_id = sale_row.id::text and actor_role = 'manager'
                        and (detail ->> 'discount_total')::numeric = 1000 and detail ->> 'discount_basis' = 'role_limit'
                        and (detail ->> 'discount_authorized_by')::uuid = mgr), 'discount authorisation is in the audit log');
  perform t.eq((select discount_amount::numeric from public.sale_items where sale_id = sale_row.id), 1000.00, 'line discount amount is stored on the sale line');
  perform t.eq((select discount_amount::numeric from public.invoice_items where invoice_id = (r ->> 'invoice_id')::uuid), 1000.00, 'and on the invoice line');

  -- ===== the limits are Admin-managed configuration: change them and behaviour follows
  perform t.as_user(adm);
  update public.discount_policies set max_percent = 15 where role = 'manager';
  perform t.as_user(mgr);
  r := public.finalize_sale('disc-cfg-key-001', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[2], 'unit_price', 10000, 'discount_amount', 1400)),
       '{"method":"cash","amount":8600}', null, 'Admin raised the limit');
  perform t.ok(r ->> 'invoice_number' is not null, 'after the Admin raises the limit to 15 %, a 14 % discount is accepted (no hardcoded percentage)');
  perform t.as_user(adm);
  update public.discount_policies set max_percent = 10, max_amount = 300 where role = 'manager';
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-cap-key-001', null, %L::jsonb, '{"method":"cash","amount":9600}'::jsonb, null, 'Cap test')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[3], 'unit_price', 10000, 'discount_amount', 400))::text),
       'TM005', 'a per-sale amount cap (300) rejects a 400 discount even though 4 % is within 10 %');
  r := public.finalize_sale('disc-cap-key-002', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[3], 'unit_price', 10000, 'discount_amount', 300)),
       '{"method":"cash","amount":9700}', null, 'Cap test');
  perform t.ok(r ->> 'invoice_number' is not null, 'a discount equal to the amount cap is accepted');
  perform t.as_user(adm);
  update public.discount_policies set can_discount = false, max_percent = 0, max_amount = null where role = 'manager';
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-off-key-001', null, %L::jsonb, '{"method":"cash","amount":9999}'::jsonb, null, 'Not allowed')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[4], 'unit_price', 10000, 'discount_amount', 1))::text),
       'TM005', 'with discounting switched off for Managers, even 1 rupee is rejected');
  r := public.finalize_sale('disc-off-key-002', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[4], 'unit_price', 10000)), '{"method":"cash","amount":10000}');
  perform t.ok(r ->> 'invoice_number' is not null, 'and the same Manager can still sell at full price');
  perform t.as_user(adm);
  update public.discount_policies set can_discount = true, max_percent = 10, max_amount = null where role = 'manager';
  perform t.reset();
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'discount_policies' and record_id = 'manager' and action = 'update'
                        and actor_id = adm and actor_role = 'admin' and (old_data ->> 'max_percent')::numeric = 10 and (new_data ->> 'max_percent')::numeric = 15),
               'limit changes are audited with actor, role, old and new values');

  -- ===== quantity line discount is judged on the whole line
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-qty-key-001', null, %L::jsonb, '{"method":"cash","amount":7190}'::jsonb, null, 'Bulk')$q$,
       jsonb_build_array(jsonb_build_object('variant_id', t.fx('v_case'), 'quantity', 10, 'unit_price', 799, 'discount_amount', 800))::text),
       'TM005', 'discount of 800 on a 7,990 accessory line (10.01 %) is rejected');
  r := public.finalize_sale('disc-qty-key-002', null,
       jsonb_build_array(jsonb_build_object('variant_id', t.fx('v_case'), 'quantity', 10, 'unit_price', 799, 'discount_amount', 799)),
       '{"method":"cash","amount":7191}', null, 'Bulk');
  perform t.ok(r ->> 'invoice_number' is not null, 'discount of 799 on the same line (exactly 10 %) is accepted');

  -- ===== Admin sells with their own policy (100 % by default; configurable like everything else)
  perform t.as_user(adm);
  r := public.finalize_sale('disc-adm-key-001', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[5], 'unit_price', 10000, 'discount_amount', 9000)),
       '{"method":"cash","amount":1000}', null, 'Admin clearance');
  perform t.ok((select discount_authorized_by = adm and discount_basis = 'role_limit' from public.sales where id = (r ->> 'sale_id')::uuid), 'Admin discount is recorded against the Admin');
  update public.discount_policies set max_percent = 20 where role = 'admin';
  perform t.throws(format($q$select public.finalize_sale('disc-adm-key-002', null, %L::jsonb, '{"method":"cash","amount":7500}'::jsonb, null, 'Over the Admin limit')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[6], 'unit_price', 10000, 'discount_amount', 2500))::text),
       'TM005', 'the Admin policy is configurable too: at 20 % a 25 % discount is refused');
  update public.discount_policies set max_percent = 100 where role = 'admin';

  -- ===== approvals (Admin-only)
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-01', null, %L::jsonb, '{"method":"cash","amount":8500}'::jsonb, null, 'Needs approval')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[7], 'unit_price', 10000, 'discount_amount', 1500))::text),
       'TM005', '15 % by a Manager (limit 10 %) is rejected without an approval');
  perform t.throws(format('select public.grant_discount_approval(%L, %L, 2000, %L)', 'grant-mgr-00001', mgr2, 'a Manager cannot approve'), '42501', 'a Manager cannot grant an approval');
  perform t.as_user(adm);
  a := public.grant_discount_approval('grant-appr-0001', mgr, 2000, 'Customer buying two phones', 30);
  appr_id := (a ->> 'approval_id')::uuid;
  perform t.ok((public.grant_discount_approval('grant-appr-0001', mgr, 2000, 'Customer buying two phones', 30) ->> 'replayed')::boolean, 'granting is idempotent');
  perform t.reset();
  perform t.eq((select count(*) from public.discount_approvals where requested_for = mgr and approved_by = adm and reason = 'Customer buying two phones'), 1::bigint, 'one approval row despite the replay');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'discount.approval_granted' and actor_id = adm and actor_role = 'admin'), 'approval grant is audited');

  perform t.as_user(mgr2);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-02', null, %L::jsonb, '{"method":"cash","amount":8500}'::jsonb, null, 'Borrowed approval', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[7], 'unit_price', 10000, 'discount_amount', 1500))::text, appr_id),
       'TM005', 'another Manager cannot use someone else''s approval');
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-03', null, %L::jsonb, '{"method":"cash","amount":7900}'::jsonb, null, 'Over the approval', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[7], 'unit_price', 10000, 'discount_amount', 2100))::text, appr_id),
       'TM005', 'a discount above the approved amount is rejected');
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-04', null, %L::jsonb, '{"method":"cash","amount":10000}'::jsonb, null, null, %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[7], 'unit_price', 10000))::text, appr_id),
       'TM003', 'an approval id on a sale without discount is rejected');
  r := public.finalize_sale('disc-appr-key-05', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[7], 'unit_price', 10000, 'discount_amount', 1500)),
       '{"method":"upi","amount":8500}', null, 'Customer buying two phones', appr_id);
  perform t.reset();
  select * into sale_row from public.sales where id = (r ->> 'sale_id')::uuid;
  perform t.ok(sale_row.discount_basis = 'manager_approval' and sale_row.discount_authorized_by = adm and sale_row.discount_approval_id = appr_id and sale_row.sold_by = mgr,
               'approved discount records the Admin as authoriser, the approval id, and the seller separately');
  perform t.ok((select used_at is not null and used_in_sale_id = sale_row.id from public.discount_approvals where id = appr_id), 'approval is marked used by that sale');
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-06', null, %L::jsonb, '{"method":"cash","amount":9000}'::jsonb, null, 'Reuse attempt', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[8], 'unit_price', 10000, 'discount_amount', 1000))::text, appr_id),
       'already used', 'an approval cannot be used twice');
  perform t.reset();
  perform t.throws(format($q$update public.discount_approvals set max_amount = 99999 where id = %L$q$, appr_id), 'single-use', 'approvals are immutable once used');
  perform t.throws(format($q$delete from public.discount_approvals where id = %L$q$, appr_id), 'cannot be deleted', 'approvals cannot be deleted');

  -- an approval can exceed a Manager's own allowance even when that allowance is switched off entirely
  perform t.as_user(adm);
  update public.discount_policies set can_discount = false, max_percent = 0 where role = 'manager';
  a := public.grant_discount_approval('grant-appr-0002', mgr, 1000, 'Manager has no own allowance', 30);
  perform t.as_user(mgr);
  r := public.finalize_sale('disc-appr-key-07', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[8], 'unit_price', 10000, 'discount_amount', 500)),
       '{"method":"cash","amount":9500}', null, 'Approved despite no own allowance', (a ->> 'approval_id')::uuid);
  perform t.ok(r ->> 'invoice_number' is not null, 'with no Manager allowance configured, an Admin approval still lets that single discount through');
  perform t.as_user(adm);
  update public.discount_policies set can_discount = true, max_percent = 10 where role = 'manager';

  -- approval beyond the approver's own authority, expiry, ineligible targets, caps
  a := public.grant_discount_approval('grant-appr-0003', mgr, 5000, 'Big deal', 30);
  update public.discount_policies set max_percent = 20 where role = 'admin';
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-08', null, %L::jsonb, '{"method":"cash","amount":7500}'::jsonb, null, 'Beyond Admin authority', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[9], 'unit_price', 10000, 'discount_amount', 2500))::text, (a ->> 'approval_id')::uuid),
       'not (or no longer) authorised', 'an approval cannot exceed the approver''s own current per-line limit');
  perform t.as_user(adm);
  update public.discount_policies set max_percent = 100 where role = 'admin';
  perform t.reset();
  insert into public.discount_approvals (requested_for, approved_by, max_amount, reason, expires_at, created_at)
    values (mgr, adm, 1000, 'Old approval', now() - interval '1 hour', now() - interval '2 hours') returning id into appr_id;
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-09', null, %L::jsonb, '{"method":"cash","amount":9500}'::jsonb, null, 'Expired', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[9], 'unit_price', 10000, 'discount_amount', 500))::text, appr_id),
       'expired', 'an expired approval is rejected');
  perform t.as_user(adm);
  perform t.throws(format($q$select public.grant_discount_approval('grant-self-0001', %L, 100, 'self', 10)$q$, adm), 'TM005', 'nobody can approve their own discount');
  perform t.throws(format($q$select public.grant_discount_approval('grant-nostaff-01', %L, 100, 'no profile', 10)$q$, nostaff), 'TM005', 'approval cannot be granted to someone without a staff profile');
  perform t.throws(format($q$select public.grant_discount_approval('grant-inact-001', %L, 100, 'inactive user', 10)$q$, inactive), 'TM005', 'approval cannot be granted to deactivated staff');
  perform t.throws(format($q$select public.grant_discount_approval('grant-long-0001', %L, 100, 'too long', 500)$q$, mgr), 'TM003', 'approval validity is capped at 120 minutes');
  update public.discount_policies set max_amount = 1000 where role = 'admin';
  perform t.throws(format($q$select public.grant_discount_approval('grant-cap-00001', %L, 1500, 'above my cap', 10)$q$, mgr), 'TM005', 'an Admin cannot grant more than their own per-sale cap');
  update public.discount_policies set max_amount = null where role = 'admin';

  -- approver demoted or deactivated after granting -> the approval dies (needs a second Admin to exist temporarily)
  perform t.reset();
  insert into auth.users (id, email) values (adm2, 'second-admin@example.test');
  insert into public.staff_profiles (user_id, full_name, role) values (adm2, 'Second Admin', 'admin');
  perform t.as_user(adm2);
  a := public.grant_discount_approval('grant-appr-0004', mgr, 1000, 'Will be demoted', 30);
  a2 := public.grant_discount_approval('grant-appr-0005', mgr, 1000, 'Will be deactivated', 30);
  perform t.as_user(adm);
  update public.staff_profiles set role = 'manager' where user_id = adm2;
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-10', null, %L::jsonb, '{"method":"cash","amount":9500}'::jsonb, null, 'Approver demoted', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[9], 'unit_price', 10000, 'discount_amount', 500))::text, (a ->> 'approval_id')::uuid),
       'not (or no longer) authorised', 'an approval stops working when its approver is demoted to Manager');
  perform t.as_user(adm);
  update public.staff_profiles set is_active = false where user_id = adm2;
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-11', null, %L::jsonb, '{"method":"cash","amount":9500}'::jsonb, null, 'Approver left', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[9], 'unit_price', 10000, 'discount_amount', 500))::text, (a2 ->> 'approval_id')::uuid),
       'not (or no longer) authorised', 'an approval stops working when its approver is deactivated');

  -- ===== database-level backstop and invariants
  perform t.reset();
  perform t.throws(format($q$insert into public.sales (sold_by, subtotal, discount_total, total) values (%L, 1000, 100, 900)$q$, mgr),
                   '23514', 'a sale with a discount but no authoriser/reason cannot be stored');
  perform t.eq((select count(*) from public.sales where discount_total > 0 and discount_basis <> 'legacy_unrecorded' and (discount_authorized_by is null or discount_reason is null)), 0::bigint,
               'every discounted sale has an authoriser and a reason');
  perform t.eq((select count(*) from public.sales s where discount_total <> (select coalesce(sum(discount_amount), 0) from public.sale_items where sale_id = s.id)), 0::bigint,
               'sale discount totals equal the sum of line discounts');
  perform t.eq((select count(*) from public.sales where (discount_basis = 'manager_approval') <> (discount_approval_id is not null)), 0::bigint,
               'approval id is present exactly when the basis is manager_approval');
  perform t.eq((select count(*) from public.sales where discount_total > 0 and discount_basis = 'legacy_unrecorded'), 0::bigint, 'no legacy_unrecorded sale exists in a database built from scratch');
end $$;
