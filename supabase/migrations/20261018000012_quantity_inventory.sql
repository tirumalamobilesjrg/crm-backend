-- 0012 Task 1B: SKU-level quantity inventory for accessories next to serialized (IMEI/serial) phones.
--   serialized variant : one inventory_items row per device; movements carry statuses.
--   quantity variant   : stock_levels.on_hand per SKU; movements carry a signed quantity_delta and the
--                        resulting balance_after. on_hand can never go below zero (check + guarded update).

alter table public.product_variants
  add column tracking_mode public.tracking_mode not null default 'serialized';

-- The mode of a SKU cannot change once stock history exists.
create function app.guard_variant_tracking() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.tracking_mode <> old.tracking_mode and (
       exists (select 1 from public.purchase_items where variant_id = old.id)
    or exists (select 1 from public.inventory_items where variant_id = old.id)
    or exists (select 1 from public.sale_items where variant_id = old.id)) then
    raise exception 'tracking mode cannot change after the SKU has purchase, stock or sale history' using errcode = 'TM013';
  end if;
  return new;
end $$;
create trigger variants_guard_tracking before update on public.product_variants
  for each row execute function app.guard_variant_tracking();

-- Serialized devices can only be created for serialized SKUs.
create function app.guard_item_variant_mode() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.product_variants where id = new.variant_id and tracking_mode = 'serialized') then
    raise exception 'inventory items (IMEI/serial devices) can only be created for serialized SKUs' using errcode = 'TM013';
  end if;
  return new;
end $$;
create trigger inventory_items_mode before insert on public.inventory_items
  for each row execute function app.guard_item_variant_mode();

create table public.stock_levels (
  variant_id uuid primary key references public.product_variants (id) on delete restrict,
  on_hand integer not null check (on_hand >= 0),
  updated_at timestamptz not null default now()
);
-- Written only while a stock movement is being applied.
create function app.guard_stock_levels() returns trigger
language plpgsql as $$
begin
  if current_setting('app.stock_apply', true) is distinct from 'on' then
    raise exception 'stock_levels changes only through stock_movements' using errcode = 'TM010';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger stock_levels_guard before insert or update or delete on public.stock_levels
  for each row execute function app.guard_stock_levels();

-- Adjustments: either one device (statuses) or a quantity SKU (signed delta).
alter table public.stock_adjustments
  alter column inventory_item_id drop not null,
  alter column from_status drop not null,
  alter column to_status drop not null,
  add column variant_id uuid references public.product_variants (id) on delete restrict,
  add column quantity_delta integer;
alter table public.stock_adjustments drop constraint stock_adjustments_check;
alter table public.stock_adjustments add constraint stock_adjustments_kind check (
  (inventory_item_id is not null and from_status is not null and to_status is not null and from_status <> to_status
     and variant_id is null and quantity_delta is null)
  or
  (inventory_item_id is null and variant_id is not null and quantity_delta is not null and quantity_delta <> 0
     and from_status is null and to_status is null));

-- Ledger: add the per-SKU shape.
alter table public.stock_movements
  alter column inventory_item_id drop not null,
  alter column to_status drop not null,
  add column variant_id uuid references public.product_variants (id) on delete restrict,
  add column quantity_delta integer,
  add column balance_after integer;

alter table public.stock_movements disable trigger stock_movements_immutable;
update public.stock_movements m set variant_id = i.variant_id
  from public.inventory_items i where i.id = m.inventory_item_id;
alter table public.stock_movements enable trigger stock_movements_immutable;
alter table public.stock_movements alter column variant_id set not null;

alter table public.stock_movements drop constraint stock_movements_source;
alter table public.stock_movements add constraint stock_movements_source check (
  (inventory_item_id is not null and quantity_delta is null and balance_after is null and to_status is not null and (
      (movement_type = 'purchase_receipt' and purchase_item_id is not null and sale_id is null
         and adjustment_id is null and from_status is null and to_status = 'in_stock')
   or (movement_type = 'sale' and sale_id is not null and purchase_item_id is null
         and adjustment_id is null and from_status = 'in_stock' and to_status = 'sold')
   or (movement_type = 'adjustment' and adjustment_id is not null and purchase_item_id is null
         and sale_id is null and from_status is not null)))
  or
  (inventory_item_id is null and quantity_delta is not null and quantity_delta <> 0 and balance_after is not null
     and from_status is null and to_status is null and (
      (movement_type = 'purchase_receipt' and purchase_item_id is not null and sale_id is null
         and adjustment_id is null and quantity_delta > 0)
   or (movement_type = 'sale' and sale_id is not null and purchase_item_id is null
         and adjustment_id is null and quantity_delta < 0)
   or (movement_type = 'adjustment' and adjustment_id is not null and purchase_item_id is null
         and sale_id is null))));
create index stock_movements_variant_idx on public.stock_movements (variant_id, id);

-- Apply a movement. Serialized: status transition under row check. Quantity: guarded balance update.
create or replace function app.apply_stock_movement() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_rows int;
  v_bal int;
begin
  if new.inventory_item_id is not null then
    select variant_id into new.variant_id from public.inventory_items where id = new.inventory_item_id;
    if new.variant_id is null then
      raise exception 'inventory item does not exist' using errcode = 'TM004';
    end if;
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
  else
    if not exists (select 1 from public.product_variants where id = new.variant_id and tracking_mode = 'quantity') then
      raise exception 'SKU is not quantity-tracked' using errcode = 'TM013';
    end if;
    perform set_config('app.stock_apply', 'on', true);
    if new.quantity_delta > 0 then
      insert into public.stock_levels as sl (variant_id, on_hand) values (new.variant_id, new.quantity_delta)
      on conflict (variant_id) do update set on_hand = sl.on_hand + excluded.on_hand, updated_at = now()
      returning sl.on_hand into v_bal;
    else
      update public.stock_levels set on_hand = on_hand + new.quantity_delta, updated_at = now()
       where variant_id = new.variant_id and on_hand + new.quantity_delta >= 0
      returning on_hand into v_bal;
    end if;
    perform set_config('app.stock_apply', 'off', true);
    if v_bal is null then
      raise exception 'insufficient stock for this SKU (change %)', new.quantity_delta using errcode = 'TM004';
    end if;
    new.balance_after := v_bal;
  end if;
  return new;
end $$;

-- Sale sub-checks now understand quantity lines.
create or replace function app.assert_sale_movement_has_line() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.movement_type = 'sale' and not exists (
       select 1 from public.sale_items si
        where si.sale_id = new.sale_id
          and ((new.inventory_item_id is not null and si.inventory_item_id = new.inventory_item_id)
            or (new.inventory_item_id is null and si.inventory_item_id is null
                and si.variant_id = new.variant_id and si.quantity = -new.quantity_delta))) then
    raise exception 'sale movement has no matching sale line' using errcode = 'TM012';
  end if;
  return null;
end $$;

-- Sale and invoice lines: quantity lines have no device.
alter table public.sale_items
  alter column inventory_item_id drop not null,
  add column quantity integer not null default 1 check (quantity between 1 and 1000);
alter table public.sale_items drop constraint sale_items_discount_le_price;
alter table public.sale_items drop constraint sale_items_line_total;
alter table public.sale_items
  add constraint sale_items_kind check (inventory_item_id is null or quantity = 1),
  add constraint sale_items_discount_le_gross check (discount_amount <= unit_price * quantity),
  add constraint sale_items_line_total check (line_total = unit_price * quantity - discount_amount);
create unique index sale_items_one_quantity_line on public.sale_items (sale_id, variant_id)
  where inventory_item_id is null;

alter table public.invoice_items drop constraint invoice_items_quantity_check;
alter table public.invoice_items
  alter column quantity type integer,
  add constraint invoice_items_quantity_check check (quantity between 1 and 1000),
  add column sku text;

create trigger stock_levels_audit after insert or update on public.stock_levels
  for each row execute function app.audit_row('variant_id');
