-- 0015 Task 1B: controlled, audited IMEI/serial corrections that keep history.
--
-- inventory_identifiers becomes a history ledger: a value is "active" until it is retired by a correction.
-- Uniqueness applies to ACTIVE values only (across IMEI-1, IMEI-2 and serial), so a mistyped value that is
-- corrected away can legitimately belong to another device later, while nothing is ever deleted.

alter table public.inventory_identifiers drop constraint inventory_identifiers_pkey;
alter table public.inventory_identifiers
  add column id bigint generated always as identity primary key,
  add column kind text check (kind in ('imei1', 'imei2', 'serial_number')),
  add column created_at timestamptz not null default now(),
  add column retired_at timestamptz,
  add column retired_by uuid;

alter table public.inventory_identifiers disable trigger inventory_identifiers_immutable;
update public.inventory_identifiers r set kind = case
    when i.imei1 = r.value then 'imei1' when i.imei2 = r.value then 'imei2' else 'serial_number' end
  from public.inventory_items i where i.id = r.inventory_item_id;
alter table public.inventory_identifiers enable trigger inventory_identifiers_immutable;
alter table public.inventory_identifiers alter column kind set not null;
drop trigger inventory_identifiers_immutable on public.inventory_identifiers;

create unique index inventory_identifiers_active_key on public.inventory_identifiers (value) where retired_at is null;
create index inventory_identifiers_item_idx on public.inventory_identifiers (inventory_item_id);
alter table public.inventory_identifiers
  add constraint identifiers_retired_consistent check ((retired_at is null) = (retired_by is null));

-- Rows are never deleted; the only update is retiring an active row, and only inside a correction.
create function app.guard_inventory_identifiers() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'identifier history cannot be deleted' using errcode = 'TM010';
  end if;
  if current_setting('app.identifier_correction', true) is distinct from 'on'
     or old.retired_at is not null
     or (new.id, new.value, new.kind, new.inventory_item_id, new.created_at)
        is distinct from (old.id, old.value, old.kind, old.inventory_item_id, old.created_at) then
    raise exception 'identifier history changes only through correct_item_identifiers()' using errcode = 'TM010';
  end if;
  return new;
end $$;
create trigger inventory_identifiers_guard before update or delete on public.inventory_identifiers
  for each row execute function app.guard_inventory_identifiers();

create or replace function app.register_identifiers() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.imei1 is not null then
    insert into public.inventory_identifiers (value, kind, inventory_item_id) values (new.imei1, 'imei1', new.id);
  end if;
  if new.imei2 is not null then
    insert into public.inventory_identifiers (value, kind, inventory_item_id) values (new.imei2, 'imei2', new.id);
  end if;
  if new.serial_number is not null then
    insert into public.inventory_identifiers (value, kind, inventory_item_id) values (new.serial_number, 'serial_number', new.id);
  end if;
  return null;
end $$;

-- Identity columns may change only inside correct_item_identifiers().
create or replace function app.guard_inventory_items() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'inventory items cannot be deleted' using errcode = 'TM010';
  end if;
  if new.id <> old.id or new.variant_id <> old.variant_id or new.purchase_item_id <> old.purchase_item_id
     or new.received_at <> old.received_at then
    raise exception 'inventory item identity is immutable' using errcode = 'TM010';
  end if;
  if (new.imei1 is distinct from old.imei1 or new.imei2 is distinct from old.imei2
      or new.serial_number is distinct from old.serial_number)
     and current_setting('app.identifier_correction', true) is distinct from 'on' then
    raise exception 'IMEI/serial can only be changed through correct_item_identifiers()' using errcode = 'TM010';
  end if;
  if new.status <> old.status and current_setting('app.stock_apply', true) is distinct from 'on' then
    raise exception 'inventory status changes only through stock_movements' using errcode = 'TM010';
  end if;
  return new;
end $$;

create table public.inventory_identifier_corrections (
  id uuid primary key default gen_random_uuid(),
  inventory_item_id uuid not null references public.inventory_items (id) on delete restrict,
  old_imei1 text, old_imei2 text, old_serial_number text,
  new_imei1 text, new_imei2 text, new_serial_number text,
  reason text not null check (length(btrim(reason)) >= 10),
  corrected_by uuid not null,
  created_at timestamptz not null default now(),
  constraint correction_changes_something check (
    (old_imei1, old_imei2, old_serial_number) is distinct from (new_imei1, new_imei2, new_serial_number))
);
create index identifier_corrections_item_idx on public.inventory_identifier_corrections (inventory_item_id, created_at);
create trigger identifier_corrections_immutable before update or delete on public.inventory_identifier_corrections
  for each row execute function app.forbid_mutation();
create trigger identifier_corrections_audit after insert on public.inventory_identifier_corrections
  for each row execute function app.audit_row();
