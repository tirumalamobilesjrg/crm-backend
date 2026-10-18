-- 0020 finalize_sale rejects a unit price above the variant's MRP.
--
-- Forward-only: this redefines public.finalize_sale exactly as left by 0019 (two-role model) and adds one check
-- in the per-line validation loop. Nothing else changes: same signature, grants, idempotency, discount rules and
-- error codes. A price above MRP raises TM003 (invalid request). The MRP is read from product_variants at sale
-- time; the price is compared before discount (a discount can only lower what the customer pays). Past sales are
-- not re-checked and are immutable. Prices equal to the MRP are allowed.

create or replace function public.finalize_sale(
  p_idempotency_key text, p_customer_id uuid, p_items jsonb, p_payment jsonb,
  p_notes text default null, p_discount_reason text default null, p_discount_approval_id uuid default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role public.staff_role := app.current_staff_role();
  v_hash text;
  v_prev jsonb;
  v_settings public.shop_settings;
  v_policy public.discount_policies;
  v_appr public.discount_approvals;
  v_appr_policy public.discount_policies;
  v_customer public.customers;
  v_sale_id uuid := gen_random_uuid();
  v_invoice_id uuid := gen_random_uuid();
  v_sale_item_id uuid;
  v_line record;
  v_mrp numeric;
  v_on_hand int;
  v_subtotal numeric; v_discount numeric; v_total numeric;
  v_basis text := 'none';
  v_authorizer uuid;
  v_method public.payment_method;
  v_amount numeric;
  v_fy text; v_seq int; v_number text;
  v_response jsonb;
begin
  if v_actor is null or v_role is null or v_role not in ('admin', 'manager') then
    raise exception 'insufficient privilege to finalize a sale' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 50 then
    raise exception 'items must be an array of 1-50 lines' using errcode = 'TM003';
  end if;
  if jsonb_typeof(p_payment) is distinct from 'object' then
    raise exception 'payment must be one JSON object {method, amount, reference?}; split payments are not supported'
      using errcode = 'TM003';
  end if;
  if exists (select 1 from jsonb_object_keys(p_payment) k where k not in ('method', 'amount', 'reference')) then
    raise exception 'payment accepts only method, amount and reference' using errcode = 'TM003';
  end if;

  v_hash := encode(sha256(convert_to(jsonb_build_object(
              'customer', p_customer_id, 'items', p_items, 'payment', p_payment, 'notes', p_notes,
              'discount_reason', p_discount_reason, 'approval', p_discount_approval_id)::text, 'UTF8')), 'hex');
  v_prev := app.idem_begin('finalize_sale', p_idempotency_key, v_hash);
  if v_prev is not null then
    return v_prev || jsonb_build_object('replayed', true);
  end if;

  select * into v_settings from public.shop_settings;
  select * into v_policy from public.discount_policies where role = v_role;

  -- Lock every serialized device and every quantity SKU balance, in a stable order (no deadlocks, no double allocation).
  perform 1 from public.inventory_items ii
   where ii.id in (select (e ->> 'inventory_item_id')::uuid from jsonb_array_elements(p_items) e where e ? 'inventory_item_id')
   order by ii.id for update;
  perform 1 from public.stock_levels sl
   where sl.variant_id in (select (e ->> 'variant_id')::uuid from jsonb_array_elements(p_items) e where e ? 'variant_id')
   order by sl.variant_id for update;

  if exists (select 1 from app.sale_lines(p_items) where kind = 'serialized' group by inventory_item_id having count(*) > 1)
     or exists (select 1 from app.sale_lines(p_items) where kind = 'quantity' group by variant_id having count(*) > 1) then
    raise exception 'the same device or SKU appears twice in the request' using errcode = 'TM003';
  end if;

  for v_line in select * from app.sale_lines(p_items) order by ord loop
    if v_line.kind is null then
      raise exception 'line % needs exactly one of inventory_item_id or variant_id', v_line.ord using errcode = 'TM003';
    end if;
    if v_line.tracking_mode is null then
      raise exception 'line % refers to an unknown device or SKU', v_line.ord using errcode = 'TM003';
    end if;
    if not v_line.variant_active then
      raise exception 'line % refers to an inactive SKU', v_line.ord using errcode = 'TM003';
    end if;
    if v_line.kind = 'serialized' then
      if v_line.qty_raw is not null and v_line.qty_raw <> 1 then
        raise exception 'line %: a serialized device is sold with quantity 1', v_line.ord using errcode = 'TM003';
      end if;
      if v_line.item_status <> 'in_stock' then
        raise exception 'inventory item % is not available (status: %)', v_line.inventory_item_id, v_line.item_status
          using errcode = 'TM004';
      end if;
    else
      if v_line.tracking_mode <> 'quantity' then
        raise exception 'line %: this SKU is serialized; sell individual devices', v_line.ord using errcode = 'TM013';
      end if;
      if v_line.qty_raw is null or v_line.qty_raw not between 1 and 1000 then
        raise exception 'line %: quantity must be between 1 and 1000', v_line.ord using errcode = 'TM003';
      end if;
      select on_hand into v_on_hand from public.stock_levels where variant_id = v_line.variant_id;
      if coalesce(v_on_hand, 0) < v_line.quantity then
        raise exception 'insufficient stock for SKU % (available %, requested %)',
          v_line.sku, coalesce(v_on_hand, 0), v_line.quantity using errcode = 'TM004';
      end if;
    end if;
    if v_line.unit_price is null or v_line.unit_price <= 0 or v_line.unit_price <> round(v_line.unit_price, 2)
       or v_line.discount_amount < 0 or v_line.discount_amount <> round(v_line.discount_amount, 2)
       or v_line.discount_amount > v_line.gross then
      raise exception 'line % has an invalid price or discount', v_line.ord using errcode = 'TM003';
    end if;
    -- 0020: a unit price may not exceed the variant's MRP (the legal maximum retail price). Discounts only lower it.
    select pv.mrp into v_mrp from public.product_variants pv where pv.id = v_line.variant_id;
    if v_line.unit_price > v_mrp then
      raise exception 'line %: unit price % is above the MRP % for SKU %', v_line.ord, v_line.unit_price, v_mrp, v_line.sku
        using errcode = 'TM003';
    end if;
  end loop;

  select coalesce(sum(gross), 0), coalesce(sum(discount_amount), 0), coalesce(sum(line_total), 0)
    into v_subtotal, v_discount, v_total from app.sale_lines(p_items);

  -- Discount authority (all server-side; limits come from discount_policies, approvals from discount_approvals).
  if v_discount > 0 then
    if p_discount_reason is null or length(btrim(p_discount_reason)) < 3 then
      raise exception 'a discount reason is required' using errcode = 'TM003';
    end if;
    if p_discount_approval_id is not null then
      select * into v_appr from public.discount_approvals where id = p_discount_approval_id for update;
      if not found or v_appr.requested_for <> v_actor then
        raise exception 'discount approval not found for this user' using errcode = 'TM005';
      end if;
      if v_appr.used_at is not null then
        raise exception 'discount approval was already used' using errcode = 'TM005';
      end if;
      if v_appr.expires_at <= now() then
        raise exception 'discount approval has expired' using errcode = 'TM005';
      end if;
      if v_discount > v_appr.max_amount then
        raise exception 'discount % exceeds the approved amount %', v_discount, v_appr.max_amount using errcode = 'TM005';
      end if;
      select dp.* into v_appr_policy from public.discount_policies dp
        join public.staff_profiles sp on sp.role = dp.role
       where sp.user_id = v_appr.approved_by and sp.is_active;
      if not found or not v_appr_policy.can_approve
         or exists (select 1 from app.sale_lines(p_items) l
                     where l.discount_amount > round(l.gross * v_appr_policy.max_percent / 100, 2))
         or (v_appr_policy.max_amount is not null and v_discount > v_appr_policy.max_amount) then
        raise exception 'the approver is not (or no longer) authorised for this discount' using errcode = 'TM005';
      end if;
      v_basis := 'manager_approval';
      v_authorizer := v_appr.approved_by;
    else
      if not v_policy.can_discount
         or exists (select 1 from app.sale_lines(p_items) l
                     where l.discount_amount > round(l.gross * v_policy.max_percent / 100, 2))
         or (v_policy.max_amount is not null and v_discount > v_policy.max_amount) then
        raise exception 'discount exceeds your limit (% %% per line%); ask an approver for a discount approval',
          v_policy.max_percent, case when v_policy.max_amount is not null then ', max ' || v_policy.max_amount || ' per sale' else '' end
          using errcode = 'TM005';
      end if;
      v_basis := 'role_limit';
      v_authorizer := v_actor;
    end if;
  elsif p_discount_approval_id is not null then
    raise exception 'a discount approval was supplied but the sale has no discount' using errcode = 'TM003';
  end if;

  -- Single payment, recorded manually, must equal the final total.
  v_amount := (p_payment ->> 'amount')::numeric;
  v_method := (p_payment ->> 'method')::public.payment_method;
  if v_method is null then
    raise exception 'payment method is required (cash, upi, card, bank_transfer or cheque)' using errcode = 'TM003';
  end if;
  if v_amount is null or v_amount <= 0 or v_amount <> round(v_amount, 2) then
    raise exception 'payment amount must be positive with at most 2 decimals' using errcode = 'TM003';
  end if;
  if v_amount <> v_total then
    raise exception 'payment (%) must equal the sale total (%)', v_amount, v_total using errcode = 'TM006';
  end if;

  if p_customer_id is not null then
    select * into v_customer from public.customers where id = p_customer_id;
    if not found then
      raise exception 'customer does not exist' using errcode = 'TM003';
    end if;
  end if;

  insert into public.sales (id, customer_id, sold_by, subtotal, discount_total, total, notes,
                            discount_basis, discount_authorized_by, discount_approval_id, discount_reason)
  values (v_sale_id, p_customer_id, v_actor, v_subtotal, v_discount, v_total, p_notes,
          v_basis, v_authorizer, v_appr.id, case when v_discount > 0 then btrim(p_discount_reason) end);
  if v_appr.id is not null then
    update public.discount_approvals set used_at = now(), used_in_sale_id = v_sale_id where id = v_appr.id;
  end if;

  v_fy := app.fiscal_year(now());
  insert into public.invoice_sequences (fiscal_year, last_number) values (v_fy, 1)
  on conflict (fiscal_year) do update set last_number = public.invoice_sequences.last_number + 1
  returning last_number into v_seq;
  v_number := v_settings.invoice_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 6, '0');

  insert into public.invoices (id, sale_id, invoice_number, fiscal_year, sequence_number,
      shop_name, shop_address, customer_id, customer_name, customer_phone, customer_address,
      subtotal, discount_total, grand_total)
  values (v_invoice_id, v_sale_id, v_number, v_fy, v_seq,
      v_settings.shop_name, v_settings.address, p_customer_id, coalesce(v_customer.name, 'Walk-in customer'),
      v_customer.phone, v_customer.address, v_subtotal, v_discount, v_total);

  -- Lines and movements; quantity SKUs in variant order so concurrent sales take balance locks consistently.
  for v_line in select * from app.sale_lines(p_items) order by (kind = 'quantity'), variant_id, ord loop
    v_sale_item_id := gen_random_uuid();
    insert into public.sale_items (id, sale_id, inventory_item_id, variant_id, quantity, unit_price, discount_amount, line_total)
    values (v_sale_item_id, v_sale_id, v_line.inventory_item_id, v_line.variant_id, v_line.quantity,
            v_line.unit_price, v_line.discount_amount, v_line.line_total);
    insert into public.invoice_items (invoice_id, sale_item_id, line_no, description, sku, imei1, imei2, serial_number,
                                      quantity, unit_price, discount_amount, line_total)
    values (v_invoice_id, v_sale_item_id, v_line.ord, v_line.description, v_line.sku, v_line.imei1, v_line.imei2,
            v_line.serial_number, v_line.quantity, v_line.unit_price, v_line.discount_amount, v_line.line_total);
    if v_line.kind = 'serialized' then
      insert into public.stock_movements (inventory_item_id, movement_type, from_status, to_status, sale_id, created_by)
      values (v_line.inventory_item_id, 'sale', 'in_stock', 'sold', v_sale_id, v_actor);
    else
      insert into public.stock_movements (variant_id, movement_type, quantity_delta, sale_id, created_by)
      values (v_line.variant_id, 'sale', -v_line.quantity, v_sale_id, v_actor);
    end if;
  end loop;

  insert into public.payments (sale_id, invoice_id, method, amount, reference, received_by)
  values (v_sale_id, v_invoice_id, v_method, v_amount, nullif(btrim(p_payment ->> 'reference'), ''), v_actor);

  insert into public.audit_logs (actor_id, actor_role, action, table_name, record_id, detail)
  values (v_actor, v_role, 'sale.finalized', 'sales', v_sale_id::text,
          jsonb_build_object('invoice_number', v_number, 'total', v_total, 'discount_total', v_discount,
                             'discount_basis', v_basis, 'discount_authorized_by', v_authorizer,
                             'payment_method', v_method, 'lines', (select count(*) from app.sale_lines(p_items))));

  v_response := jsonb_build_object('sale_id', v_sale_id, 'invoice_id', v_invoice_id, 'invoice_number', v_number,
                                   'total', v_total, 'discount_total', v_discount, 'replayed', false);
  perform app.idem_complete('finalize_sale', p_idempotency_key, v_response);
  return v_response;
end $$;
