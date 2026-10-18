-- 0016 Task 1B transactional operations (replace the Task 1 versions where noted).
--
-- Error codes (SQLSTATE):
--   42501 role not permitted         TM002 idempotency key reused with a different request
--   TM003 invalid request            TM004 unavailable item / insufficient stock / invalid transition
--   TM005 discount not authorised    TM006 payment does not equal the sale total
--   TM007 purchase state error       TM013 wrong SKU tracking mode
-- Malformed UUID/enum/number input surfaces as 22P02 / 22003.

-- Parses and prices the lines of a sale request. Internal; not callable by API roles.
--   serialized line : {"inventory_item_id": uuid, "unit_price": n, "discount_amount": n}
--   quantity line   : {"variant_id": uuid, "quantity": n, "unit_price": n, "discount_amount": n}
-- discount_amount is the discount for the whole line.
create function app.sale_lines(p_items jsonb) returns table (
  ord int, kind text, inventory_item_id uuid, variant_id uuid, quantity int, qty_raw int,
  unit_price numeric, discount_amount numeric, gross numeric, line_total numeric,
  item_status public.inventory_status, tracking_mode public.tracking_mode, variant_active boolean,
  sku text, description text, imei1 text, imei2 text, serial_number text)
language sql stable set search_path = '' as $$
  select e.ord::int,
         case when x.item_id is not null and x.vid is null then 'serialized'
              when x.item_id is null and x.vid is not null then 'quantity' end,
         x.item_id, pv.id, q.eff, x.qty, x.price, x.disc, x.price * q.eff, x.price * q.eff - x.disc,
         ii.status, pv.tracking_mode, pv.is_active, pv.sku,
         concat_ws(' ', b.name, pr.name, pv.color,
                   case when pv.storage_gb is not null then pv.storage_gb::text || 'GB' end),
         ii.imei1, ii.imei2, ii.serial_number
    from jsonb_array_elements(p_items) with ordinality as e(elem, ord)
   cross join lateral (select (e.elem ->> 'inventory_item_id')::uuid as item_id,
                              (e.elem ->> 'variant_id')::uuid as vid,
                              (e.elem ->> 'quantity')::int as qty,
                              (e.elem ->> 'unit_price')::numeric as price,
                              coalesce((e.elem ->> 'discount_amount')::numeric, 0) as disc) x
   cross join lateral (select case when x.item_id is not null then 1 else coalesce(x.qty, 0) end as eff) q
    left join public.inventory_items ii on ii.id = x.item_id
    left join public.product_variants pv on pv.id = coalesce(ii.variant_id, x.vid)
    left join public.products pr on pr.id = pv.product_id
    left join public.brands b on b.id = pr.brand_id
$$;

create function public.finalize_sale(
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
  v_on_hand int;
  v_subtotal numeric; v_discount numeric; v_total numeric;
  v_basis text := 'none';
  v_authorizer uuid;
  v_method public.payment_method;
  v_amount numeric;
  v_fy text; v_seq int; v_number text;
  v_response jsonb;
begin
  if v_actor is null or v_role is null or v_role not in ('owner', 'manager', 'sales_executive') then
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

-- Serialized lines: p_units has one element per device
--   [{"purchase_item_id": uuid, "imei1": "...", "imei2": "...", "serial_number": "...",
--     "condition": "new|refurbished|used", "shelf_location": "..."}]
-- Quantity lines take no unit list; the full ordered quantity is received into stock_levels.
-- (Replaces the Task 1 signature-compatible function.)
create or replace function public.receive_purchase(p_idempotency_key text, p_purchase_id uuid, p_units jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role public.staff_role := app.current_staff_role();
  v_hash text;
  v_prev jsonb;
  v_purchase public.purchases;
  v_pi record;
  v_unit record;
  v_item_id uuid;
  v_devices int := 0;
  v_qty_lines int := 0;
  v_qty_units int := 0;
  v_response jsonb;
begin
  if v_actor is null or v_role is null or v_role not in ('owner', 'manager', 'inventory_executive') then
    raise exception 'insufficient privilege to receive a purchase' using errcode = '42501';
  end if;
  if jsonb_typeof(p_units) is distinct from 'array' or jsonb_array_length(p_units) > 1000 then
    raise exception 'units must be an array of at most 1000 devices (use [] for quantity-only purchases)' using errcode = 'TM003';
  end if;

  v_hash := encode(sha256(convert_to(jsonb_build_object('purchase', p_purchase_id, 'units', p_units)::text, 'UTF8')), 'hex');
  v_prev := app.idem_begin('receive_purchase', p_idempotency_key, v_hash);
  if v_prev is not null then
    return v_prev || jsonb_build_object('replayed', true);
  end if;

  select * into v_purchase from public.purchases where id = p_purchase_id for update;
  if not found then
    raise exception 'purchase does not exist' using errcode = 'TM003';
  end if;
  if v_purchase.status <> 'draft' then
    raise exception 'purchase is already %', v_purchase.status using errcode = 'TM007';
  end if;
  if not exists (select 1 from public.purchase_items where purchase_id = p_purchase_id) then
    raise exception 'purchase has no lines' using errcode = 'TM007';
  end if;

  if exists (select 1 from jsonb_array_elements(p_units) u
              where not exists (select 1 from public.purchase_items pi
                                 where pi.id = (u ->> 'purchase_item_id')::uuid and pi.purchase_id = p_purchase_id)) then
    raise exception 'a unit refers to a purchase line that is not part of this purchase' using errcode = 'TM003';
  end if;
  for v_pi in select pi.id, pi.quantity, pv.tracking_mode,
                     (select count(*) from jsonb_array_elements(p_units) u where (u ->> 'purchase_item_id')::uuid = pi.id) as got
                from public.purchase_items pi join public.product_variants pv on pv.id = pi.variant_id
               where pi.purchase_id = p_purchase_id loop
    if v_pi.tracking_mode = 'serialized' and v_pi.got <> v_pi.quantity then
      raise exception 'purchase line % expects % units but % were supplied', v_pi.id, v_pi.quantity, v_pi.got
        using errcode = 'TM003';
    elsif v_pi.tracking_mode = 'quantity' and v_pi.got <> 0 then
      raise exception 'purchase line % is a quantity SKU and takes no unit list', v_pi.id using errcode = 'TM003';
    end if;
  end loop;

  perform set_config('app.receiving', 'on', true);
  update public.purchases set status = 'received', received_at = now(), received_by = v_actor where id = p_purchase_id;
  perform set_config('app.receiving', 'off', true);

  for v_unit in
    select pi.id as purchase_item_id, pi.variant_id, pi.unit_cost,
           nullif(btrim(u ->> 'imei1'), '') as imei1,
           nullif(btrim(u ->> 'imei2'), '') as imei2,
           nullif(upper(btrim(u ->> 'serial_number')), '') as serial_number,
           coalesce(nullif(u ->> 'condition', ''), 'new')::public.item_condition as condition,
           nullif(btrim(u ->> 'shelf_location'), '') as shelf_location
      from jsonb_array_elements(p_units) u
      join public.purchase_items pi on pi.id = (u ->> 'purchase_item_id')::uuid loop
    v_item_id := gen_random_uuid();
    insert into public.inventory_items (id, variant_id, purchase_item_id, imei1, imei2, serial_number, condition, shelf_location)
    values (v_item_id, v_unit.variant_id, v_unit.purchase_item_id, v_unit.imei1, v_unit.imei2,
            v_unit.serial_number, v_unit.condition, v_unit.shelf_location);
    insert into public.inventory_item_costs (inventory_item_id, cost_price) values (v_item_id, v_unit.unit_cost);
    insert into public.stock_movements (inventory_item_id, movement_type, from_status, to_status, purchase_item_id, created_by)
    values (v_item_id, 'purchase_receipt', null, 'in_stock', v_unit.purchase_item_id, v_actor);
    v_devices := v_devices + 1;
  end loop;

  for v_pi in select pi.id, pi.variant_id, pi.quantity
                from public.purchase_items pi join public.product_variants pv on pv.id = pi.variant_id
               where pi.purchase_id = p_purchase_id and pv.tracking_mode = 'quantity'
               order by pi.variant_id, pi.id loop
    insert into public.stock_movements (variant_id, movement_type, quantity_delta, purchase_item_id, created_by)
    values (v_pi.variant_id, 'purchase_receipt', v_pi.quantity, v_pi.id, v_actor);
    v_qty_lines := v_qty_lines + 1;
    v_qty_units := v_qty_units + v_pi.quantity;
  end loop;

  insert into public.audit_logs (actor_id, actor_role, action, table_name, record_id, detail)
  values (v_actor, v_role, 'purchase.received', 'purchases', p_purchase_id::text,
          jsonb_build_object('devices', v_devices, 'quantity_lines', v_qty_lines, 'quantity_units', v_qty_units,
                             'total', v_purchase.total));

  v_response := jsonb_build_object('purchase_id', p_purchase_id, 'units_received', v_devices,
                                   'quantity_lines_received', v_qty_lines, 'quantity_units_received', v_qty_units,
                                   'replayed', false);
  perform app.idem_complete('receive_purchase', p_idempotency_key, v_response);
  return v_response;
end $$;

-- Serialized stock adjustment ('correction' applies to quantity SKUs only).
create or replace function public.adjust_stock(
  p_idempotency_key text, p_inventory_item_id uuid, p_reason public.adjustment_reason, p_notes text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role public.staff_role := app.current_staff_role();
  v_hash text;
  v_prev jsonb;
  v_from public.inventory_status;
  v_to public.inventory_status;
  v_adj_id uuid := gen_random_uuid();
  v_response jsonb;
begin
  if v_actor is null or v_role is null or v_role not in ('owner', 'manager', 'inventory_executive') then
    raise exception 'insufficient privilege to adjust stock' using errcode = '42501';
  end if;
  if p_reason = 'correction' then
    raise exception '"correction" applies to quantity SKUs; use adjust_quantity_stock' using errcode = 'TM003';
  end if;
  if p_notes is null or length(btrim(p_notes)) < 3 then
    raise exception 'notes are required for a stock adjustment' using errcode = 'TM003';
  end if;

  v_hash := encode(sha256(convert_to(jsonb_build_object('item', p_inventory_item_id, 'reason', p_reason, 'notes', p_notes)::text, 'UTF8')), 'hex');
  v_prev := app.idem_begin('adjust_stock', p_idempotency_key, v_hash);
  if v_prev is not null then
    return v_prev || jsonb_build_object('replayed', true);
  end if;

  select status into v_from from public.inventory_items where id = p_inventory_item_id for update;
  if not found then
    raise exception 'inventory item does not exist' using errcode = 'TM003';
  end if;
  v_to := case p_reason
            when 'damaged' then 'damaged' when 'lost' then 'lost'
            when 'returned_to_supplier' then 'returned_to_supplier'
            when 'found' then 'in_stock' when 'repaired' then 'in_stock' end;
  if not app.valid_transition('adjustment', v_from, v_to)
     or (p_reason = 'found' and v_from <> 'lost') or (p_reason = 'repaired' and v_from <> 'damaged') then
    raise exception 'cannot apply "%" to an item that is %', p_reason, v_from using errcode = 'TM004';
  end if;

  insert into public.stock_adjustments (id, inventory_item_id, reason, from_status, to_status, notes, created_by)
  values (v_adj_id, p_inventory_item_id, p_reason, v_from, v_to, btrim(p_notes), v_actor);
  insert into public.stock_movements (inventory_item_id, movement_type, from_status, to_status, adjustment_id, created_by)
  values (p_inventory_item_id, 'adjustment', v_from, v_to, v_adj_id, v_actor);
  insert into public.audit_logs (actor_id, actor_role, action, table_name, record_id, detail)
  values (v_actor, v_role, 'stock.adjusted', 'inventory_items', p_inventory_item_id::text,
          jsonb_build_object('reason', p_reason, 'from', v_from, 'to', v_to));

  v_response := jsonb_build_object('adjustment_id', v_adj_id, 'from_status', v_from, 'to_status', v_to, 'replayed', false);
  perform app.idem_complete('adjust_stock', p_idempotency_key, v_response);
  return v_response;
end $$;

-- Quantity SKU adjustment: a signed delta with a reason. Stock can never go below zero.
create function public.adjust_quantity_stock(
  p_idempotency_key text, p_variant_id uuid, p_quantity_delta integer,
  p_reason public.adjustment_reason, p_notes text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role public.staff_role := app.current_staff_role();
  v_hash text;
  v_prev jsonb;
  v_adj_id uuid := gen_random_uuid();
  v_balance int;
  v_response jsonb;
begin
  if v_actor is null or v_role is null or v_role not in ('owner', 'manager', 'inventory_executive') then
    raise exception 'insufficient privilege to adjust stock' using errcode = '42501';
  end if;
  if p_notes is null or length(btrim(p_notes)) < 3 then
    raise exception 'notes are required for a stock adjustment' using errcode = 'TM003';
  end if;
  if p_quantity_delta is null or p_quantity_delta = 0 or abs(p_quantity_delta) > 100000 then
    raise exception 'quantity change must be a non-zero whole number' using errcode = 'TM003';
  end if;
  if (p_reason in ('damaged', 'lost', 'returned_to_supplier') and p_quantity_delta > 0)
     or (p_reason = 'found' and p_quantity_delta < 0)
     or p_reason = 'repaired' then
    raise exception 'reason "%" does not match a change of %', p_reason, p_quantity_delta using errcode = 'TM003';
  end if;

  v_hash := encode(sha256(convert_to(jsonb_build_object('variant', p_variant_id, 'delta', p_quantity_delta,
                                                        'reason', p_reason, 'notes', p_notes)::text, 'UTF8')), 'hex');
  v_prev := app.idem_begin('adjust_quantity_stock', p_idempotency_key, v_hash);
  if v_prev is not null then
    return v_prev || jsonb_build_object('replayed', true);
  end if;

  if not exists (select 1 from public.product_variants where id = p_variant_id and tracking_mode = 'quantity') then
    raise exception 'SKU does not exist or is not quantity-tracked' using errcode = 'TM013';
  end if;

  insert into public.stock_adjustments (id, variant_id, quantity_delta, reason, notes, created_by)
  values (v_adj_id, p_variant_id, p_quantity_delta, p_reason, btrim(p_notes), v_actor);
  insert into public.stock_movements (variant_id, movement_type, quantity_delta, adjustment_id, created_by)
  values (p_variant_id, 'adjustment', p_quantity_delta, v_adj_id, v_actor)
  returning balance_after into v_balance;
  insert into public.audit_logs (actor_id, actor_role, action, table_name, record_id, detail)
  values (v_actor, v_role, 'stock.quantity_adjusted', 'product_variants', p_variant_id::text,
          jsonb_build_object('reason', p_reason, 'delta', p_quantity_delta, 'balance_after', v_balance));

  v_response := jsonb_build_object('adjustment_id', v_adj_id, 'balance_after', v_balance, 'replayed', false);
  perform app.idem_complete('adjust_quantity_stock', p_idempotency_key, v_response);
  return v_response;
end $$;

-- An approver (per discount_policies.can_approve) authorises one named seller to exceed their own limit once.
create function public.grant_discount_approval(
  p_idempotency_key text, p_requested_for uuid, p_max_amount numeric, p_reason text,
  p_valid_minutes integer default 15)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role public.staff_role := app.current_staff_role();
  v_policy public.discount_policies;
  v_target_policy public.discount_policies;
  v_hash text;
  v_prev jsonb;
  v_id uuid := gen_random_uuid();
  v_expires timestamptz;
  v_response jsonb;
begin
  if v_actor is null or v_role is null then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select * into v_policy from public.discount_policies where role = v_role;
  if not v_policy.can_approve then
    raise exception 'your role may not approve discounts' using errcode = '42501';
  end if;
  if p_requested_for is null or p_requested_for = v_actor then
    raise exception 'an approval must be granted to a different user' using errcode = 'TM005';
  end if;
  if p_max_amount is null or p_max_amount <= 0 or p_max_amount <> round(p_max_amount, 2) then
    raise exception 'approved amount must be positive with at most 2 decimals' using errcode = 'TM003';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'a reason is required' using errcode = 'TM003';
  end if;
  if p_valid_minutes is null or p_valid_minutes not between 1 and 120 then
    raise exception 'validity must be 1-120 minutes' using errcode = 'TM003';
  end if;
  if v_policy.max_amount is not null and p_max_amount > v_policy.max_amount then
    raise exception 'you may approve at most % per sale', v_policy.max_amount using errcode = 'TM005';
  end if;

  v_hash := encode(sha256(convert_to(jsonb_build_object('for', p_requested_for, 'max', p_max_amount,
                                                        'reason', p_reason, 'minutes', p_valid_minutes)::text, 'UTF8')), 'hex');
  v_prev := app.idem_begin('grant_discount_approval', p_idempotency_key, v_hash);
  if v_prev is not null then
    return v_prev || jsonb_build_object('replayed', true);
  end if;

  select dp.* into v_target_policy from public.discount_policies dp
    join public.staff_profiles sp on sp.role = dp.role
   where sp.user_id = p_requested_for and sp.is_active;
  if not found or not v_target_policy.can_discount then
    raise exception 'the named user is not an active staff member who may discount' using errcode = 'TM005';
  end if;

  v_expires := now() + make_interval(mins => p_valid_minutes);
  insert into public.discount_approvals (id, requested_for, approved_by, max_amount, reason, expires_at)
  values (v_id, p_requested_for, v_actor, p_max_amount, btrim(p_reason), v_expires);
  insert into public.audit_logs (actor_id, actor_role, action, table_name, record_id, detail)
  values (v_actor, v_role, 'discount.approval_granted', 'discount_approvals', v_id::text,
          jsonb_build_object('requested_for', p_requested_for, 'max_amount', p_max_amount, 'expires_at', v_expires));

  v_response := jsonb_build_object('approval_id', v_id, 'expires_at', v_expires, 'replayed', false);
  perform app.idem_complete('grant_discount_approval', p_idempotency_key, v_response);
  return v_response;
end $$;

-- Controlled IMEI/serial correction. p_changes lists only the identifiers to change, e.g.
--   {"imei1": "490154203237518"}   or   {"imei2": null}   (null clears the value)
-- History is kept: old values stay in inventory_identifiers (retired) and in
-- inventory_identifier_corrections; the new values are validated and checked for duplicates.
create function public.correct_item_identifiers(
  p_idempotency_key text, p_inventory_item_id uuid, p_changes jsonb, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role public.staff_role := app.current_staff_role();
  v_hash text;
  v_prev jsonb;
  v_item public.inventory_items;
  v_i1 text; v_i2 text; v_sn text;
  v_cid uuid := gen_random_uuid();
  v_response jsonb;
begin
  if v_actor is null or v_role is null or v_role not in ('owner', 'manager') then
    raise exception 'only the owner or a manager may correct identifiers' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'a reason of at least 10 characters is required' using errcode = 'TM003';
  end if;
  if jsonb_typeof(p_changes) is distinct from 'object'
     or exists (select 1 from jsonb_object_keys(p_changes) k where k not in ('imei1', 'imei2', 'serial_number')) then
    raise exception 'changes must be an object with imei1, imei2 and/or serial_number' using errcode = 'TM003';
  end if;

  v_hash := encode(sha256(convert_to(jsonb_build_object('item', p_inventory_item_id, 'changes', p_changes,
                                                        'reason', p_reason)::text, 'UTF8')), 'hex');
  v_prev := app.idem_begin('correct_item_identifiers', p_idempotency_key, v_hash);
  if v_prev is not null then
    return v_prev || jsonb_build_object('replayed', true);
  end if;

  select * into v_item from public.inventory_items where id = p_inventory_item_id for update;
  if not found then
    raise exception 'inventory item does not exist' using errcode = 'TM003';
  end if;

  v_i1 := case when p_changes ? 'imei1' then nullif(btrim(p_changes ->> 'imei1'), '') else v_item.imei1 end;
  v_i2 := case when p_changes ? 'imei2' then nullif(btrim(p_changes ->> 'imei2'), '') else v_item.imei2 end;
  v_sn := case when p_changes ? 'serial_number' then nullif(upper(btrim(p_changes ->> 'serial_number')), '') else v_item.serial_number end;
  if (v_i1, v_i2, v_sn) is not distinct from (v_item.imei1, v_item.imei2, v_item.serial_number) then
    raise exception 'the requested values are identical to the current ones' using errcode = 'TM003';
  end if;

  perform set_config('app.identifier_correction', 'on', true);
  update public.inventory_identifiers
     set retired_at = now(), retired_by = v_actor
   where inventory_item_id = p_inventory_item_id and retired_at is null
     and ((kind = 'imei1' and value is distinct from v_i1)
       or (kind = 'imei2' and value is distinct from v_i2)
       or (kind = 'serial_number' and value is distinct from v_sn));
  update public.inventory_items set imei1 = v_i1, imei2 = v_i2, serial_number = v_sn where id = p_inventory_item_id;
  if v_i1 is not null and v_i1 is distinct from v_item.imei1 then
    insert into public.inventory_identifiers (value, kind, inventory_item_id) values (v_i1, 'imei1', p_inventory_item_id);
  end if;
  if v_i2 is not null and v_i2 is distinct from v_item.imei2 then
    insert into public.inventory_identifiers (value, kind, inventory_item_id) values (v_i2, 'imei2', p_inventory_item_id);
  end if;
  if v_sn is not null and v_sn is distinct from v_item.serial_number then
    insert into public.inventory_identifiers (value, kind, inventory_item_id) values (v_sn, 'serial_number', p_inventory_item_id);
  end if;
  perform set_config('app.identifier_correction', 'off', true);

  insert into public.inventory_identifier_corrections (id, inventory_item_id, old_imei1, old_imei2, old_serial_number,
      new_imei1, new_imei2, new_serial_number, reason, corrected_by)
  values (v_cid, p_inventory_item_id, v_item.imei1, v_item.imei2, v_item.serial_number, v_i1, v_i2, v_sn,
          btrim(p_reason), v_actor);
  insert into public.audit_logs (actor_id, actor_role, action, table_name, record_id, detail)
  values (v_actor, v_role, 'identifier.corrected', 'inventory_items', p_inventory_item_id::text,
          jsonb_build_object('correction_id', v_cid, 'reason', btrim(p_reason), 'item_status', v_item.status));

  v_response := jsonb_build_object('correction_id', v_cid, 'inventory_item_id', p_inventory_item_id, 'replayed', false);
  perform app.idem_complete('correct_item_identifiers', p_idempotency_key, v_response);
  return v_response;
end $$;
