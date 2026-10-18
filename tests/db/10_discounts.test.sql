-- Configurable discount limits, approvals, authorisation record and audit trail. All checks are server-side.
do $$
declare
  owner_ uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  sales uuid := 'a0000000-0000-0000-0000-000000000003';
  inv uuid := 'a0000000-0000-0000-0000-000000000004';
  acct uuid := 'a0000000-0000-0000-0000-000000000005';
  inactive uuid := 'a0000000-0000-0000-0000-000000000006';
  sales2 uuid := 'a0000000-0000-0000-0000-000000000008';
  v1 uuid := t.fx('v_published');
  pur uuid; pi uuid; d uuid[]; a jsonb; r jsonb; sale_row public.sales; appr_id uuid; n bigint;
  line text;
begin
  -- 12 devices, price 10000 each, to spend on discount scenarios
  perform t.as_user(inv);
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-5001') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, v1, 14, 50000) returning id into pi;
  perform public.receive_purchase('disc-stock-recv', pur,
    (select jsonb_agg(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(1000 + g))) from generate_series(1, 14) g));
  perform t.reset();
  select array_agg(id order by imei1) into d from public.inventory_items where imei1 between t.imei(1001) and t.imei(1014);

  -- seeded limits are data, not code
  perform t.eq((select max_percent from public.discount_policies where role = 'sales_executive'), 5.00, 'seed: sales executive limit is a row in discount_policies');
  perform t.ok((select can_approve and max_percent = 100 from public.discount_policies where role = 'owner'), 'seed: owner may approve and discount up to 100%');
  perform t.ok((select not can_discount and max_percent = 0 from public.discount_policies where role = 'accountant'), 'seed: accountant cannot discount');

  -- ===== role limit
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('disc-nr-key-001', null, %L::jsonb, '{"method":"cash","amount":9500}'::jsonb)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[1], 'unit_price', 10000, 'discount_amount', 500))::text),
       'discount reason is required', 'a discount without a reason is rejected');
  perform t.throws(format($q$select public.finalize_sale('disc-over-key-1', null, %L::jsonb, '{"method":"cash","amount":9499}'::jsonb, null, 'Haggling')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[1], 'unit_price', 10000, 'discount_amount', 501))::text),
       'TM005', 'discount above the role limit (5.01%) is rejected');
  r := public.finalize_sale('disc-ok-key-001', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[1], 'unit_price', 10000, 'discount_amount', 500)),
       '{"method":"cash","amount":9500}', null, 'Repeat customer');
  perform t.reset();
  select * into sale_row from public.sales where id = (r ->> 'sale_id')::uuid;
  perform t.ok(sale_row.discount_total = 500 and sale_row.discount_basis = 'role_limit' and sale_row.discount_authorized_by = sales
               and sale_row.discount_reason = 'Repeat customer' and sale_row.discount_approval_id is null, 'discount within the limit records amount, basis, authoriser and reason');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'sale.finalized' and record_id = sale_row.id::text
                        and (detail ->> 'discount_total')::numeric = 500 and detail ->> 'discount_basis' = 'role_limit'
                        and (detail ->> 'discount_authorized_by')::uuid = sales), 'discount authorisation is in the audit log');
  perform t.eq((select discount_amount::numeric from public.sale_items where sale_id = sale_row.id), 500.00, 'line discount amount is stored on the sale line');
  perform t.eq((select discount_amount::numeric from public.invoice_items where invoice_id = (r ->> 'invoice_id')::uuid), 500.00, 'and on the invoice line');

  -- ===== limits are configuration: change them and behaviour follows
  perform t.as_user(owner_);
  update public.discount_policies set max_percent = 10 where role = 'sales_executive';
  perform t.as_user(sales);
  r := public.finalize_sale('disc-cfg-key-001', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[2], 'unit_price', 10000, 'discount_amount', 900)),
       '{"method":"cash","amount":9100}', null, 'Owner raised the limit');
  perform t.ok(r ->> 'invoice_number' is not null, 'after the owner raises the limit to 10%, a 9% discount is accepted (no hardcoded 5%)');
  perform t.as_user(owner_);
  update public.discount_policies set max_percent = 5, max_amount = 300 where role = 'sales_executive';
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('disc-cap-key-001', null, %L::jsonb, '{"method":"cash","amount":9600}'::jsonb, null, 'Cap test')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[3], 'unit_price', 10000, 'discount_amount', 400))::text),
       'TM005', 'a per-sale amount cap (300) rejects a 400 discount even though 4% is within 5%');
  r := public.finalize_sale('disc-cap-key-002', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[3], 'unit_price', 10000, 'discount_amount', 300)),
       '{"method":"cash","amount":9700}', null, 'Cap test');
  perform t.ok(r ->> 'invoice_number' is not null, 'a discount equal to the amount cap is accepted');
  perform t.as_user(owner_);
  update public.discount_policies set can_discount = false, max_percent = 0, max_amount = null where role = 'sales_executive';
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('disc-off-key-001', null, %L::jsonb, '{"method":"cash","amount":9999}'::jsonb, null, 'Not allowed')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[4], 'unit_price', 10000, 'discount_amount', 1))::text),
       'TM005', 'with discounting switched off for the role, even 1 rupee is rejected');
  r := public.finalize_sale('disc-off-key-002', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[4], 'unit_price', 10000)), '{"method":"cash","amount":10000}');
  perform t.ok(r ->> 'invoice_number' is not null, 'and the same user can still sell at full price');
  perform t.as_user(owner_);
  update public.discount_policies set can_discount = true, max_percent = 5, max_amount = null where role = 'sales_executive';
  perform t.reset();
  perform t.ok(exists (select 1 from public.audit_logs where table_name = 'discount_policies' and record_id = 'sales_executive' and action = 'update'
                        and actor_id = owner_ and actor_role = 'owner' and (old_data ->> 'max_percent')::numeric = 5 and (new_data ->> 'max_percent')::numeric = 10),
               'limit changes are audited with actor, old and new values');

  -- ===== quantity line discount is judged on the whole line
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('disc-qty-key-001', null, %L::jsonb, '{"method":"cash","amount":7590}'::jsonb, null, 'Bulk')$q$,
       jsonb_build_array(jsonb_build_object('variant_id', t.fx('v_case'), 'quantity', 10, 'unit_price', 799, 'discount_amount', 400))::text),
       'TM005', 'discount of 400 on a 7,990 accessory line (5.006%) is rejected');
  r := public.finalize_sale('disc-qty-key-002', null,
       jsonb_build_array(jsonb_build_object('variant_id', t.fx('v_case'), 'quantity', 10, 'unit_price', 799, 'discount_amount', 399.50)),
       '{"method":"cash","amount":7590.50}', null, 'Bulk');
  perform t.ok(r ->> 'invoice_number' is not null, 'discount of 399.50 on the same line (exactly 5%) is accepted');

  -- ===== manager: own limit 20%
  perform t.as_user(mgr);
  r := public.finalize_sale('disc-mgr-key-001', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[5], 'unit_price', 10000, 'discount_amount', 2000)),
       '{"method":"cash","amount":8000}', null, 'Manager discretion');
  perform t.ok(r ->> 'invoice_number' is not null and (select discount_authorized_by = mgr from public.sales where id = (r ->> 'sale_id')::uuid) is not distinct from true,
               'manager may discount up to their own 20%, recorded against the manager');
  perform t.throws(format($q$select public.finalize_sale('disc-mgr-key-002', null, %L::jsonb, '{"method":"cash","amount":7900}'::jsonb, null, 'Too much')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[6], 'unit_price', 10000, 'discount_amount', 2100))::text),
       'TM005', 'manager discount above 20% needs an owner approval');
  perform t.as_user(owner_);
  r := public.finalize_sale('disc-own-key-001', null,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[6], 'unit_price', 10000, 'discount_amount', 9000)),
       '{"method":"cash","amount":1000}', null, 'Owner clearance');
  perform t.ok(r ->> 'invoice_number' is not null, 'owner may discount 90% (limit 100%)');

  -- ===== approvals
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-01', null, %L::jsonb, '{"method":"cash","amount":8500}'::jsonb, null, 'Needs approval')$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[7], 'unit_price', 10000, 'discount_amount', 1500))::text),
       'TM005', '15% by a sales executive is rejected without an approval');
  perform t.as_user(mgr);
  a := public.grant_discount_approval('grant-appr-0001', sales, 2000, 'Customer buying two phones', 30);
  appr_id := (a ->> 'approval_id')::uuid;
  perform t.ok((public.grant_discount_approval('grant-appr-0001', sales, 2000, 'Customer buying two phones', 30) ->> 'replayed')::boolean, 'granting is idempotent');
  perform t.reset();
  perform t.eq((select count(*) from public.discount_approvals where requested_for = sales and approved_by = mgr and reason = 'Customer buying two phones'), 1::bigint, 'one approval row despite the replay');
  perform t.ok(exists (select 1 from public.audit_logs where action = 'discount.approval_granted' and actor_id = mgr), 'approval grant is audited');

  perform t.as_user(sales2);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-02', null, %L::jsonb, '{"method":"cash","amount":8500}'::jsonb, null, 'Borrowed approval', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[7], 'unit_price', 10000, 'discount_amount', 1500))::text, appr_id),
       'TM005', 'another seller cannot use someone else''s approval');
  perform t.as_user(sales);
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
  perform t.ok(sale_row.discount_basis = 'manager_approval' and sale_row.discount_authorized_by = mgr and sale_row.discount_approval_id = appr_id and sale_row.sold_by = sales,
               'approved discount records the approver as authoriser, the approval id, and the seller separately');
  perform t.ok((select used_at is not null and used_in_sale_id = sale_row.id from public.discount_approvals where id = appr_id), 'approval is marked used by that sale');
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-06', null, %L::jsonb, '{"method":"cash","amount":9000}'::jsonb, null, 'Reuse attempt', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[8], 'unit_price', 10000, 'discount_amount', 1000))::text, appr_id),
       'already used', 'an approval cannot be used twice');
  perform t.reset();
  perform t.throws(format($q$update public.discount_approvals set max_amount = 99999 where id = %L$q$, appr_id), 'single-use', 'approvals are immutable once used');
  perform t.throws(format($q$delete from public.discount_approvals where id = %L$q$, appr_id), 'cannot be deleted', 'approvals cannot be deleted');

  -- approval beyond the approver's own authority, expiry, self-approval, ineligible target
  perform t.as_user(mgr);
  a := public.grant_discount_approval('grant-appr-0002', sales, 5000, 'Big deal', 30);
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-07', null, %L::jsonb, '{"method":"cash","amount":7500}'::jsonb, null, 'Beyond manager authority', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[8], 'unit_price', 10000, 'discount_amount', 2500))::text, (a ->> 'approval_id')::uuid),
       'not (or no longer) authorised', 'an approval cannot exceed the approver''s own per-line limit (manager 20%)');
  perform t.reset();
  insert into public.discount_approvals (requested_for, approved_by, max_amount, reason, expires_at, created_at)
    values (sales, mgr, 1000, 'Old approval', now() - interval '1 hour', now() - interval '2 hours') returning id into appr_id;
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-08', null, %L::jsonb, '{"method":"cash","amount":9500}'::jsonb, null, 'Expired', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[8], 'unit_price', 10000, 'discount_amount', 500))::text, appr_id),
       'expired', 'an expired approval is rejected');
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.grant_discount_approval('grant-self-0001', %L, 100, 'self', 10)$q$, mgr), 'TM005', 'nobody can approve their own discount');
  perform t.throws(format($q$select public.grant_discount_approval('grant-acct-0001', %L, 100, 'accountant cannot sell', 10)$q$, acct), 'TM005', 'approval cannot be granted to a role that may not discount');
  perform t.throws(format($q$select public.grant_discount_approval('grant-inact-001', %L, 100, 'inactive user', 10)$q$, inactive), 'TM005', 'approval cannot be granted to deactivated staff');
  perform t.throws(format($q$select public.grant_discount_approval('grant-long-0001', %L, 100, 'too long', 500)$q$, sales), 'TM003', 'approval validity is capped at 120 minutes');
  perform t.as_user(owner_);
  update public.discount_policies set max_amount = 1000 where role = 'manager';
  perform t.as_user(mgr);
  perform t.throws(format($q$select public.grant_discount_approval('grant-cap-00001', %L, 1500, 'above my cap', 10)$q$, sales), 'TM005', 'an approver cannot grant more than their own per-sale cap');
  perform t.as_user(owner_);
  update public.discount_policies set max_amount = null where role = 'manager';

  -- approver deactivated after granting -> approval dies
  perform t.as_user(owner_);
  a := public.grant_discount_approval('grant-appr-0003', sales, 1000, 'Will be revoked', 30);
  perform t.reset();
  update public.staff_profiles set is_active = false where user_id = mgr;
  perform t.as_user(owner_);
  a := public.grant_discount_approval('grant-appr-0004', sales, 1000, 'Owner approval', 30);
  perform t.reset();
  update public.staff_profiles set is_active = true where user_id = mgr;

  -- the approver of 0003 is the owner; deactivate the *manager* who approved an earlier grant instead
  perform t.as_user(mgr);
  a := public.grant_discount_approval('grant-appr-0005', sales, 1000, 'Manager approval to revoke', 30);
  perform t.reset();
  update public.staff_profiles set is_active = false where user_id = mgr;
  perform t.as_user(sales);
  perform t.throws(format($q$select public.finalize_sale('disc-appr-key-09', null, %L::jsonb, '{"method":"cash","amount":9500}'::jsonb, null, 'Approver left', %L)$q$,
       jsonb_build_array(jsonb_build_object('inventory_item_id', d[8], 'unit_price', 10000, 'discount_amount', 500))::text, (a ->> 'approval_id')::uuid),
       'not (or no longer) authorised', 'an approval stops working when the approver is deactivated');
  perform t.reset();
  update public.staff_profiles set is_active = true where user_id = mgr;

  -- ===== database-level backstop and invariants
  perform t.throws(format($q$insert into public.sales (sold_by, subtotal, discount_total, total) values (%L, 1000, 100, 900)$q$, sales),
                   '23514', 'a sale with a discount but no authoriser/reason cannot be stored');
  perform t.eq((select count(*) from public.sales where discount_total > 0 and (discount_authorized_by is null or discount_reason is null)), 0::bigint,
               'every discounted sale has an authoriser and a reason');
  perform t.eq((select count(*) from public.sales s where discount_total <> (select coalesce(sum(discount_amount), 0) from public.sale_items where sale_id = s.id)), 0::bigint,
               'sale discount totals equal the sum of line discounts');
  perform t.eq((select count(*) from public.sales where (discount_basis = 'manager_approval') <> (discount_approval_id is not null)), 0::bigint,
               'approval id is present exactly when the basis is manager_approval');
end $$;
