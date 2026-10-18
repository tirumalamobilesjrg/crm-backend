-- 0004 suppliers and purchases. Purchases are editable while draft; receiving is done only by
-- public.receive_purchase (0007), which creates the inventory items and stock movements.

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 160),
  gstin text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  phone text,
  email text,
  address text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index suppliers_name_key on public.suppliers (lower(name));

create table public.purchases (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  supplier_invoice_no text not null check (length(btrim(supplier_invoice_no)) between 1 and 64),
  invoice_date date not null default current_date,
  status public.purchase_status not null default 'draft',
  subtotal public.inr not null default 0,      -- sum of taxable value (excl. GST)
  tax_total public.inr not null default 0,
  total public.inr not null default 0,
  notes text,
  received_at timestamptz,
  received_by uuid,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchases_received_consistent check ((status = 'received') = (received_at is not null)),
  constraint purchases_total_consistent check (total = subtotal + tax_total)
);
create unique index purchases_supplier_invoice_key
  on public.purchases (supplier_id, lower(supplier_invoice_no));
create index purchases_status_idx on public.purchases (status);

create table public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.purchases (id) on delete cascade,
  variant_id uuid not null references public.product_variants (id) on delete restrict,
  quantity integer not null check (quantity between 1 and 500),
  unit_cost public.inr not null,                       -- excluding GST
  gst_rate public.gst_rate not null default 18,
  taxable_value numeric(14, 2) generated always as (round(quantity * unit_cost, 2)) stored,
  tax_amount numeric(14, 2) generated always as (round(quantity * unit_cost * gst_rate / 100, 2)) stored,
  created_at timestamptz not null default now()
);
create index purchase_items_purchase_idx on public.purchase_items (purchase_id);
create index purchase_items_variant_idx on public.purchase_items (variant_id);

-- Header totals follow the lines.
create function app.recalc_purchase_totals() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := case when tg_op = 'DELETE' then old.purchase_id else new.purchase_id end;
begin
  update public.purchases p
     set subtotal = coalesce(s.taxable, 0),
         tax_total = coalesce(s.tax, 0),
         total = coalesce(s.taxable, 0) + coalesce(s.tax, 0)
    from (select sum(taxable_value) as taxable, sum(tax_amount) as tax
            from public.purchase_items where purchase_id = v_id) s
   where p.id = v_id;
  return null;
end $$;

-- Lines can only change while the purchase is a draft.
create function app.guard_purchase_items() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := case when tg_op = 'DELETE' then old.purchase_id else new.purchase_id end;
  v_status public.purchase_status;
begin
  select status into v_status from public.purchases where id = v_id;
  if v_status is distinct from 'draft' then
    raise exception 'purchase lines can only be changed while the purchase is a draft' using errcode = 'TM007';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

-- Received/cancelled purchases are frozen; draft -> received only via receive_purchase().
create function app.guard_purchases() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then
      raise exception 'only draft purchases can be deleted' using errcode = 'TM007';
    end if;
    return old;
  end if;
  if old.status <> 'draft' then
    raise exception 'a % purchase cannot be modified', old.status using errcode = 'TM007';
  end if;
  if new.status = 'received' and current_setting('app.receiving', true) is distinct from 'on' then
    raise exception 'purchases can only be received through receive_purchase()' using errcode = 'TM007';
  end if;
  return new;
end $$;

create trigger purchase_items_guard before insert or update or delete on public.purchase_items
  for each row execute function app.guard_purchase_items();
create trigger purchase_items_totals after insert or update or delete on public.purchase_items
  for each row execute function app.recalc_purchase_totals();
create trigger purchases_guard before update or delete on public.purchases
  for each row execute function app.guard_purchases();

create trigger suppliers_updated before update on public.suppliers for each row execute function app.set_updated_at();
create trigger purchases_updated before update on public.purchases for each row execute function app.set_updated_at();

create trigger suppliers_audit after insert or update or delete on public.suppliers for each row execute function app.audit_row();
create trigger purchases_audit after insert or update or delete on public.purchases for each row execute function app.audit_row();
create trigger purchase_items_audit after insert or update or delete on public.purchase_items for each row execute function app.audit_row();
