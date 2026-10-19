-- 0024 Prices are edited only by an Admin; sold-phone identifiers only by an Admin; invoice indexes.
--
-- 1. product_variants.mrp, selling_price and public_price can be set (insert) or changed (update) only by an Admin.
--    A Manager can still read them, create and edit products, publish/unpublish, and receive stock for existing variants.
--    Reason: the legal MRP ceiling, the selling price (the base the discount rules measure from) and the website price are owner decisions;
--    letting any staff member change them defeated the discount and MRP rules (found in the security and QA reviews).
-- 2. correct_item_identifiers: a SOLD phone's IMEI/serial can be corrected only by an Admin (it rewrites a sale's history).
-- 3. Indexes the reports, sales list and customer history actually use.

create function app.guard_variant_prices() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    return new;  -- direct database sessions (migrations, restores) are not API users
  end if;
  if (tg_op = 'INSERT' or new.mrp is distinct from old.mrp or new.selling_price is distinct from old.selling_price
      or new.public_price is distinct from old.public_price) and not app.has_any_role('admin') then
    raise exception 'only an Admin can set or change prices (MRP, selling price, website price)' using errcode = '42501';
  end if;
  return new;
end $$;
-- Fires before the other variant triggers (alphabetical order), so a Manager is refused before anything else runs.
create trigger variants_a_guard_prices before insert or update on public.product_variants
  for each row execute function app.guard_variant_prices();

create or replace function public.correct_item_identifiers(
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
  if v_actor is null or v_role is null or v_role not in ('admin', 'manager') then
    raise exception 'only an Admin or a Manager may correct identifiers' using errcode = '42501';
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

  -- 0024: once a phone has been sold, its identifier is part of the sale record: only an Admin may correct it
  if v_item.status = 'sold' and v_role <> 'admin' then
    raise exception 'only an Admin can correct the IMEI or serial number of a phone that has been sold' using errcode = '42501';
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

create index invoices_issued_at_idx on public.invoices (issued_at desc);
create index invoices_customer_idx on public.invoices (customer_id) where customer_id is not null;
