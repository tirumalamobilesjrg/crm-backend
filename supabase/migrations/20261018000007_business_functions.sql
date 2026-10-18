-- 0007 transactional business operations. These are the ONLY write path for purchasing receipt,
-- stock adjustments and sales. Each is a single database transaction: any error rolls back every
-- row it wrote (items, movements, sale, invoice, payments, audit, idempotency key, invoice number).
--
-- Error codes (SQLSTATE):
--   42501 role not permitted        TM002 idempotency key reused with a different request
--   TM003 invalid request           TM004 item unavailable / invalid stock transition
--   TM005 discount above role limit TM006 payments do not equal the invoice total
--   TM007 purchase state error
-- Bad UUID/enum/number input surfaces as 22P02 / 22003.

-- Parses and prices the lines of a sale request. Not callable by API roles.
create function app.sale_lines(p_items jsonb) returns table (
  ord int, inventory_item_id uuid, unit_price numeric, discount_amount numeric,
  item_status public.inventory_status, variant_id uuid, gst_rate numeric, hsn_code text,
  description text, imei1 text, imei2 text, serial_number text,
  line_total numeric, tax_amount numeric, taxable_value numeric)
language sql stable set search_path = '' as $$
  select e.ord::int, x.id, x.price, x.disc, ii.status, ii.variant_id, pv.gst_rate, pv.hsn_code,
         concat_ws(' ', b.name, pr.name, pv.color, pv.storage_gb::text || 'GB'),
         ii.imei1, ii.imei2, ii.serial_number,
         x.price - x.disc, t.tax, (x.price - x.disc) - t.tax
    from jsonb_array_elements(p_items) with ordinality as e(elem, ord)
   cross join lateral (select (e.elem ->> 'inventory_item_id')::uuid as id,
                              (e.elem ->> 'unit_price')::numeric as price,
                              coalesce((e.elem ->> 'discount_amount')::numeric, 0) as disc) x
    left join public.inventory_items ii on ii.id = x.id
    left join public.product_variants pv on pv.id = ii.variant_id
    left join public.products pr on pr.id = pv.product_id
    left join public.brands b on b.id = pr.brand_id
   cross join lateral (select round((x.price - x.disc) * coalesce(pv.gst_rate, 0) / (100 + coalesce(pv.gst_rate, 0)), 2) as tax) t
$$;

create function public.finalize_sale(
  p_idempotency_key text, p_customer_id uuid, p_items jsonb, p_payments jsonb, p_notes text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role public.staff_role := app.current_staff_role();
  v_hash text;
  v_prev jsonb;
  v_settings public.shop_settings;
  v_customer public.customers;
  v_sale_id uuid := gen_random_uuid();
  v_invoice_id uuid := gen_random_uuid();
  v_sale_item_id uuid;
  v_item_count int;
  v_distinct int;
  v_line record;
  v_pay record;
  v_subtotal numeric; v_discount numeric; v_total numeric; v_tax numeric; v_taxable numeric;
  v_pay_total numeric;
  v_fy text; v_seq int; v_number text;
  v_response jsonb;
begin
  if v_actor is null or v_role is null or v_role not in ('owner', 'manager', 'sales_executive') then
    raise exception 'insufficient privilege to finalize a sale' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 50 then
    raise exception 'items must be an array of 1-50 lines' using errcode = 'TM003';
  end if;
  if jsonb_typeof(p_payments) is distinct from 'array' or jsonb_array_length(p_payments) not between 1 and 10 then
    raise exception 'payments must be an array of 1-10 entries' using errcode = 'TM003';
  end if;

  v_hash := encode(sha256(convert_to(jsonb_build_object(
              'customer', p_customer_id, 'items', p_items, 'payments', p_payments, 'notes', p_notes)::text, 'UTF8')), 'hex');
  v_prev := app.idem_begin('finalize_sale', p_idempotency_key, v_hash);
  if v_prev is not null then
    return v_prev || jsonb_build_object('replayed', true);
  end if;

  select * into v_settings from public.shop_settings;

  -- Lock every requested device in a stable order (prevents deadlocks and double-selling).
  perform 1 from public.inventory_items ii
   where ii.id in (select (e ->> 'inventory_item_id')::uuid from jsonb_array_elements(p_items) e)
   order by ii.id for update;

  select count(*), count(distinct l.inventory_item_id) into v_item_count, v_distinct
    from app.sale_lines(p_items) l;
  if v_item_count <> v_distinct then
    raise exception 'the same inventory item appears twice in the request' using errcode = 'TM003';
  end if;

  for v_line in select * from app.sale_lines(p_items) order by ord loop
    if v_line.item_status is null then
      raise exception 'inventory item % does not exist', v_line.inventory_item_id using errcode = 'TM003';
    end if;
    if v_line.item_status <> 'in_stock' then
      raise exception 'inventory item % is not available (status: %)', v_line.inventory_item_id, v_line.item_status
        using errcode = 'TM004';
    end if;
    if v_line.unit_price is null or v_line.unit_price <= 0 or v_line.unit_price <> round(v_line.unit_price, 2)
       or v_line.discount_amount < 0 or v_line.discount_amount <> round(v_line.discount_amount, 2)
       or v_line.discount_amount > v_line.unit_price then
      raise exception 'line % has an invalid price or discount', v_line.ord using errcode = 'TM003';
    end if;
    if v_role = 'sales_executive'
       and v_line.discount_amount > round(v_line.unit_price * v_settings.max_sales_exec_discount_pct / 100, 2) then
      raise exception 'line % discount exceeds the % %% limit for sales executives',
        v_line.ord, v_settings.max_sales_exec_discount_pct using errcode = 'TM005';
    end if;
  end loop;

  select sum(unit_price), sum(discount_amount), sum(line_total), sum(tax_amount), sum(taxable_value)
    into v_subtotal, v_discount, v_total, v_tax, v_taxable
    from app.sale_lines(p_items);

  select coalesce(sum(p.amount), 0) into v_pay_total
    from jsonb_to_recordset(p_payments) as p(method text, amount numeric, reference text);
  for v_pay in select * from jsonb_to_recordset(p_payments) as p(method text, amount numeric, reference text) loop
    if v_pay.method is null or v_pay.amount is null or v_pay.amount <= 0 or v_pay.amount <> round(v_pay.amount, 2) then
      raise exception 'each payment needs a method and a positive amount with at most 2 decimals' using errcode = 'TM003';
    end if;
    perform v_pay.method::public.payment_method;
  end loop;
  if v_pay_total <> v_total then
    raise exception 'payments (%) must equal the invoice total (%)', v_pay_total, v_total using errcode = 'TM006';
  end if;

  if p_customer_id is not null then
    select * into v_customer from public.customers where id = p_customer_id;
    if not found then
      raise exception 'customer does not exist' using errcode = 'TM003';
    end if;
  end if;

  insert into public.sales (id, customer_id, sold_by, subtotal, discount_total, tax_total, total, notes)
  values (v_sale_id, p_customer_id, v_actor, v_subtotal, v_discount, v_tax, v_total, p_notes);

  v_fy := app.fiscal_year(now());
  insert into public.invoice_sequences (fiscal_year, last_number) values (v_fy, 1)
  on conflict (fiscal_year) do update set last_number = public.invoice_sequences.last_number + 1
  returning last_number into v_seq;
  v_number := v_settings.invoice_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 6, '0');

  insert into public.invoices (id, sale_id, invoice_number, fiscal_year, sequence_number,
      shop_name, shop_gstin, shop_address, shop_state_code,
      customer_id, customer_name, customer_phone, customer_gstin, customer_address,
      subtotal, discount_total, taxable_total, tax_total, grand_total)
  values (v_invoice_id, v_sale_id, v_number, v_fy, v_seq,
      v_settings.shop_name, v_settings.gstin, v_settings.address, v_settings.state_code,
      p_customer_id, coalesce(v_customer.name, 'Walk-in customer'), v_customer.phone, v_customer.gstin, v_customer.address,
      v_subtotal, v_discount, v_taxable, v_tax, v_total);

  for v_line in select * from app.sale_lines(p_items) order by ord loop
    v_sale_item_id := gen_random_uuid();
    insert into public.sale_items (id, sale_id, inventory_item_id, variant_id, unit_price, discount_amount,
                                   line_total, gst_rate, taxable_value, tax_amount)
    values (v_sale_item_id, v_sale_id, v_line.inventory_item_id, v_line.variant_id, v_line.unit_price,
            v_line.discount_amount, v_line.line_total, v_line.gst_rate, v_line.taxable_value, v_line.tax_amount);

    insert into public.invoice_items (invoice_id, sale_item_id, line_no, description, hsn_code, imei1, imei2,
                                      serial_number, unit_price, discount_amount, taxable_value, gst_rate,
                                      tax_amount, line_total)
    values (v_invoice_id, v_sale_item_id, v_line.ord, v_line.description, v_line.hsn_code, v_line.imei1,
            v_line.imei2, v_line.serial_number, v_line.unit_price, v_line.discount_amount, v_line.taxable_value,
            v_line.gst_rate, v_line.tax_amount, v_line.line_total);

    insert into public.stock_movements (inventory_item_id, movement_type, from_status, to_status, sale_id, created_by)
    values (v_line.inventory_item_id, 'sale', 'in_stock', 'sold', v_sale_id, v_actor);
  end loop;

  insert into public.payments (sale_id, invoice_id, method, amount, reference, received_by)
  select v_sale_id, v_invoice_id, p.method::public.payment_method, p.amount, nullif(btrim(p.reference), ''), v_actor
    from jsonb_to_recordset(p_payments) as p(method text, amount numeric, reference text);

  insert into public.audit_logs (actor_id, actor_role, action, table_name, record_id, detail)
  values (v_actor, v_role, 'sale.finalized', 'sales', v_sale_id::text,
          jsonb_build_object('invoice_number', v_number, 'total', v_total, 'lines', v_item_count));

  v_response := jsonb_build_object('sale_id', v_sale_id, 'invoice_id', v_invoice_id,
                                   'invoice_number', v_number, 'total', v_total, 'replayed', false);
  perform app.idem_complete('finalize_sale', p_idempotency_key, v_response);
  return v_response;
end $$;

-- p_units: one element per physical device:
--   [{"purchase_item_id": uuid, "imei1": "...", "imei2": "...", "serial_number": "...",
--     "condition": "new|refurbished|used", "shelf_location": "..."}]
create function public.receive_purchase(p_idempotency_key text, p_purchase_id uuid, p_units jsonb)
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
  v_received int := 0;
  v_response jsonb;
begin
  if v_actor is null or v_role is null or v_role not in ('owner', 'manager', 'inventory_executive') then
    raise exception 'insufficient privilege to receive a purchase' using errcode = '42501';
  end if;
  if jsonb_typeof(p_units) is distinct from 'array' or jsonb_array_length(p_units) not between 1 and 1000 then
    raise exception 'units must be an array of 1-1000 devices' using errcode = 'TM003';
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

  -- Each purchase line must receive exactly its quantity, and nothing else.
  if exists (select 1 from jsonb_array_elements(p_units) u
              where not exists (select 1 from public.purchase_items pi
                                 where pi.id = (u ->> 'purchase_item_id')::uuid and pi.purchase_id = p_purchase_id)) then
    raise exception 'a unit refers to a purchase line that is not part of this purchase' using errcode = 'TM003';
  end if;
  for v_pi in select pi.id, pi.quantity,
                     (select count(*) from jsonb_array_elements(p_units) u where (u ->> 'purchase_item_id')::uuid = pi.id) as got
                from public.purchase_items pi where pi.purchase_id = p_purchase_id loop
    if v_pi.got <> v_pi.quantity then
      raise exception 'purchase line % expects % units but % were supplied', v_pi.id, v_pi.quantity, v_pi.got
        using errcode = 'TM003';
    end if;
  end loop;
  if not exists (select 1 from public.purchase_items where purchase_id = p_purchase_id) then
    raise exception 'purchase has no lines' using errcode = 'TM007';
  end if;

  perform set_config('app.receiving', 'on', true);
  update public.purchases set status = 'received', received_at = now(), received_by = v_actor
   where id = p_purchase_id;
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
    v_received := v_received + 1;
  end loop;

  insert into public.audit_logs (actor_id, actor_role, action, table_name, record_id, detail)
  values (v_actor, v_role, 'purchase.received', 'purchases', p_purchase_id::text,
          jsonb_build_object('units', v_received, 'total', v_purchase.total));

  v_response := jsonb_build_object('purchase_id', p_purchase_id, 'units_received', v_received, 'replayed', false);
  perform app.idem_complete('receive_purchase', p_idempotency_key, v_response);
  return v_response;
end $$;

create function public.adjust_stock(
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
