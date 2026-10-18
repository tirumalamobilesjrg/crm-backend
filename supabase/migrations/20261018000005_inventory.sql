-- 0005 inventory: one row per physical device, costs kept apart, append-only stock ledger.

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.product_variants (id) on delete restrict,
  purchase_item_id uuid not null references public.purchase_items (id) on delete restrict,
  imei1 text,
  imei2 text,
  serial_number text,
  status public.inventory_status not null default 'in_stock',
  condition public.item_condition not null default 'new',
  shelf_location text,
  received_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint inventory_has_identifier check (num_nonnulls(imei1, serial_number) >= 1),
  constraint inventory_imei1_valid check (imei1 is null or app.is_valid_imei(imei1)),
  constraint inventory_imei2_valid check (imei2 is null or app.is_valid_imei(imei2)),
  constraint inventory_imei2_needs_imei1 check (imei2 is null or imei1 is not null),
  constraint inventory_imeis_differ check (imei2 is null or imei2 <> imei1),
  constraint inventory_serial_valid check (serial_number is null or serial_number ~ '^[A-Z0-9][A-Z0-9-]{3,39}$')
);
create unique index inventory_items_imei1_key on public.inventory_items (imei1) where imei1 is not null;
create unique index inventory_items_imei2_key on public.inventory_items (imei2) where imei2 is not null;
create unique index inventory_items_serial_key on public.inventory_items (serial_number) where serial_number is not null;
create index inventory_items_available_idx on public.inventory_items (variant_id) where status = 'in_stock';
create index inventory_items_status_idx on public.inventory_items (status);
create index inventory_items_purchase_item_idx on public.inventory_items (purchase_item_id);

-- Registry of every identifier value across all columns. The per-column unique indexes above do
-- not stop one device's IMEI-2 equalling another device's IMEI-1; this table's primary key does.
create table public.inventory_identifiers (
  value text primary key,
  inventory_item_id uuid not null references public.inventory_items (id) on delete restrict
);
create function app.register_identifiers() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v text;
begin
  foreach v in array array_remove(array[new.imei1, new.imei2, new.serial_number], null) loop
    insert into public.inventory_identifiers (value, inventory_item_id) values (v, new.id);
  end loop;
  return null;
end $$;
create trigger inventory_identifiers_immutable before update or delete on public.inventory_identifiers
  for each row execute function app.forbid_mutation();
create trigger inventory_items_register after insert on public.inventory_items
  for each row execute function app.register_identifiers();

-- Acquisition cost is a separate table so it can have stricter RLS than the item itself.
create table public.inventory_item_costs (
  inventory_item_id uuid primary key references public.inventory_items (id) on delete restrict,
  cost_price public.inr not null,       -- excluding GST
  created_at timestamptz not null default now()
);
create trigger inventory_item_costs_immutable before update or delete on public.inventory_item_costs
  for each row execute function app.forbid_mutation();

create table public.stock_adjustments (
  id uuid primary key default gen_random_uuid(),
  inventory_item_id uuid not null references public.inventory_items (id) on delete restrict,
  reason public.adjustment_reason not null,
  from_status public.inventory_status not null,
  to_status public.inventory_status not null,
  notes text not null check (length(btrim(notes)) >= 3),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  check (from_status <> to_status)
);
create index stock_adjustments_item_idx on public.stock_adjustments (inventory_item_id);
create trigger stock_adjustments_immutable before update or delete on public.stock_adjustments
  for each row execute function app.forbid_mutation();

-- Append-only ledger. Every status change of an inventory item is exactly one row here.
create table public.stock_movements (
  id bigint generated always as identity primary key,
  inventory_item_id uuid not null references public.inventory_items (id) on delete restrict,
  movement_type public.movement_type not null,
  from_status public.inventory_status,
  to_status public.inventory_status not null,
  purchase_item_id uuid references public.purchase_items (id) on delete restrict,
  sale_id uuid,                                   -- FK added in 0006
  adjustment_id uuid references public.stock_adjustments (id) on delete restrict,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint stock_movements_source check (
    (movement_type = 'purchase_receipt' and purchase_item_id is not null and sale_id is null
       and adjustment_id is null and from_status is null and to_status = 'in_stock')
    or (movement_type = 'sale' and sale_id is not null and purchase_item_id is null
       and adjustment_id is null and from_status = 'in_stock' and to_status = 'sold')
    or (movement_type = 'adjustment' and adjustment_id is not null and purchase_item_id is null
       and sale_id is null and from_status is not null)
  )
);
create index stock_movements_item_idx on public.stock_movements (inventory_item_id, id);
create index stock_movements_sale_idx on public.stock_movements (sale_id) where sale_id is not null;
create unique index stock_movements_one_receipt on public.stock_movements (inventory_item_id)
  where movement_type = 'purchase_receipt';
create trigger stock_movements_immutable before update or delete on public.stock_movements
  for each row execute function app.forbid_mutation();

-- Allowed status transitions per movement type.
create function app.valid_transition(p_type public.movement_type, p_from public.inventory_status,
                                     p_to public.inventory_status) returns boolean
language sql immutable as $$
  select case p_type
    when 'purchase_receipt' then p_from is null and p_to = 'in_stock'
    when 'sale' then p_from = 'in_stock' and p_to = 'sold'
    when 'adjustment' then
         (p_from = 'in_stock' and p_to in ('damaged', 'lost', 'returned_to_supplier'))
      or (p_from = 'damaged' and p_to in ('in_stock', 'returned_to_supplier'))
      or (p_from = 'lost' and p_to = 'in_stock')
  end
$$;

-- Applying a movement is the only way an item's status changes.
create function app.apply_stock_movement() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_rows int;
begin
  if not app.valid_transition(new.movement_type, new.from_status, new.to_status) then
    raise exception 'invalid stock transition % -> % for %', new.from_status, new.to_status, new.movement_type
      using errcode = 'TM004';
  end if;
  if new.from_status is null then
    if not exists (select 1 from public.inventory_items where id = new.inventory_item_id and status = new.to_status) then
      raise exception 'receipt movement does not match the inventory item' using errcode = 'TM004';
    end if;
  else
    perform set_config('app.stock_apply', 'on', true);
    update public.inventory_items set status = new.to_status
     where id = new.inventory_item_id and status = new.from_status;
    get diagnostics v_rows = row_count;
    perform set_config('app.stock_apply', 'off', true);
    if v_rows <> 1 then
      raise exception 'inventory item % is not in status %', new.inventory_item_id, new.from_status
        using errcode = 'TM004';
    end if;
  end if;
  return new;
end $$;
create trigger stock_movements_apply before insert on public.stock_movements
  for each row execute function app.apply_stock_movement();

-- Items are immutable except status (via stock_movements), shelf_location and condition.
create function app.guard_inventory_items() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'inventory items cannot be deleted' using errcode = 'TM010';
  end if;
  if new.id <> old.id or new.variant_id <> old.variant_id or new.purchase_item_id <> old.purchase_item_id
     or new.imei1 is distinct from old.imei1 or new.imei2 is distinct from old.imei2
     or new.serial_number is distinct from old.serial_number or new.received_at <> old.received_at then
    raise exception 'inventory item identity is immutable' using errcode = 'TM010';
  end if;
  if new.status <> old.status and current_setting('app.stock_apply', true) is distinct from 'on' then
    raise exception 'inventory status changes only through stock_movements' using errcode = 'TM010';
  end if;
  return new;
end $$;
create trigger inventory_items_guard before update or delete on public.inventory_items
  for each row execute function app.guard_inventory_items();
create trigger inventory_items_updated before update on public.inventory_items
  for each row execute function app.set_updated_at();

-- Every inventory item must have its receipt movement by commit time.
create function app.assert_item_has_receipt() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.stock_movements
                  where inventory_item_id = new.id and movement_type = 'purchase_receipt') then
    raise exception 'inventory item % has no purchase_receipt movement', new.id using errcode = 'TM012';
  end if;
  return null;
end $$;
create constraint trigger inventory_items_need_receipt after insert on public.inventory_items
  deferrable initially deferred for each row execute function app.assert_item_has_receipt();

create trigger inventory_items_audit after insert or update on public.inventory_items
  for each row execute function app.audit_row();
create trigger inventory_item_costs_audit after insert on public.inventory_item_costs
  for each row execute function app.audit_row('inventory_item_id');
create trigger stock_adjustments_audit after insert on public.stock_adjustments
  for each row execute function app.audit_row();
