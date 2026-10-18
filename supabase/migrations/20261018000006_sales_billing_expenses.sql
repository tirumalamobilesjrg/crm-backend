-- 0006 customers, sales, invoices, payments, expenses.
-- Prices are GST-inclusive (retail MRP convention). tax_amount = line_total * rate / (100 + rate).
-- Sales, invoices and payments are immutable once written; corrections need a dedicated
-- return/void workflow (not part of this foundation).

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 160),
  phone text check (phone is null or phone ~ '^\+?[0-9]{7,15}$'),
  email text,
  address text,
  gstin text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index customers_phone_key on public.customers (phone) where phone is not null;
create index customers_name_idx on public.customers (lower(name));
create trigger customers_updated before update on public.customers for each row execute function app.set_updated_at();

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customers (id) on delete restrict,   -- NULL = walk-in
  sold_by uuid not null references public.staff_profiles (user_id) on delete restrict,
  sold_at timestamptz not null default now(),
  status text not null default 'completed' check (status = 'completed'),
  subtotal public.inr not null,           -- sum of list prices
  discount_total public.inr not null,
  tax_total public.inr not null,          -- GST included in total
  total public.inr not null,
  notes text,
  created_at timestamptz not null default now(),
  constraint sales_total_consistent check (total = subtotal - discount_total),
  constraint sales_total_positive check (total > 0)
);
create index sales_sold_by_idx on public.sales (sold_by, sold_at desc);
create index sales_sold_at_idx on public.sales (sold_at desc);
create index sales_customer_idx on public.sales (customer_id) where customer_id is not null;

alter table public.stock_movements
  add constraint stock_movements_sale_fk foreign key (sale_id) references public.sales (id) on delete restrict;

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id) on delete restrict,
  inventory_item_id uuid not null references public.inventory_items (id) on delete restrict,
  variant_id uuid not null references public.product_variants (id) on delete restrict,
  unit_price public.inr not null,
  discount_amount public.inr not null default 0,
  line_total public.inr not null,
  gst_rate public.gst_rate not null,
  taxable_value public.inr not null,
  tax_amount public.inr not null,
  unique (sale_id, inventory_item_id),
  constraint sale_items_discount_le_price check (discount_amount <= unit_price),
  constraint sale_items_line_total check (line_total = unit_price - discount_amount),
  constraint sale_items_tax_split check (taxable_value + tax_amount = line_total)
);
create index sale_items_item_idx on public.sale_items (inventory_item_id);

-- Gapless numbering per financial year; the row lock serialises concurrent invoices (fine for one shop).
create table public.invoice_sequences (
  fiscal_year text primary key check (fiscal_year ~ '^[0-9]{2}-[0-9]{2}$'),
  last_number integer not null check (last_number > 0)
);

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null unique references public.sales (id) on delete restrict,
  invoice_number text not null unique
    check (invoice_number ~ '^[A-Z0-9]{1,3}/[0-9]{2}-[0-9]{2}/[0-9]{6}$' and length(invoice_number) <= 16),
  fiscal_year text not null,
  sequence_number integer not null,
  issued_at timestamptz not null default now(),
  status text not null default 'issued' check (status = 'issued'),
  -- snapshots: an invoice must not change when shop/customer details later do
  shop_name text not null,
  shop_gstin text,
  shop_address text,
  shop_state_code text,
  customer_id uuid references public.customers (id) on delete restrict,
  customer_name text not null,
  customer_phone text,
  customer_gstin text,
  customer_address text,
  subtotal public.inr not null,
  discount_total public.inr not null,
  taxable_total public.inr not null,
  tax_total public.inr not null,
  grand_total public.inr not null,
  unique (fiscal_year, sequence_number),
  constraint invoices_totals check (grand_total = subtotal - discount_total
                                    and taxable_total + tax_total = grand_total)
);

create table public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices (id) on delete restrict,
  sale_item_id uuid not null unique references public.sale_items (id) on delete restrict,
  line_no smallint not null check (line_no > 0),
  description text not null,
  hsn_code text not null,
  imei1 text,
  imei2 text,
  serial_number text,
  quantity smallint not null default 1 check (quantity = 1),   -- one physical device per line
  unit_price public.inr not null,
  discount_amount public.inr not null,
  taxable_value public.inr not null,
  gst_rate public.gst_rate not null,
  tax_amount public.inr not null,
  line_total public.inr not null,
  unique (invoice_id, line_no)
);

-- Physical payments only (cash / UPI / card / bank transfer / cheque). No gateway integration.
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id) on delete restrict,
  invoice_id uuid not null references public.invoices (id) on delete restrict,
  method public.payment_method not null,
  amount public.inr not null check (amount > 0),
  reference text,
  received_at timestamptz not null default now(),
  received_by uuid not null
);
create index payments_sale_idx on public.payments (sale_id);
create index payments_received_idx on public.payments (received_at desc);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  expense_date date not null default current_date,
  category text not null check (length(btrim(category)) between 1 and 80),
  description text,
  amount public.inr not null check (amount > 0),
  paid_via public.payment_method not null default 'cash',
  receipt_path text check (receipt_path is null or (receipt_path !~ '(^/|\.\.)' and length(receipt_path) <= 300)),
  recorded_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index expenses_date_idx on public.expenses (expense_date desc);
create trigger expenses_updated before update on public.expenses for each row execute function app.set_updated_at();

create trigger sales_immutable before update or delete on public.sales for each row execute function app.forbid_mutation();
create trigger sale_items_immutable before update or delete on public.sale_items for each row execute function app.forbid_mutation();
create trigger invoices_immutable before update or delete on public.invoices for each row execute function app.forbid_mutation();
create trigger invoice_items_immutable before update or delete on public.invoice_items for each row execute function app.forbid_mutation();
create trigger payments_immutable before update or delete on public.payments for each row execute function app.forbid_mutation();

create trigger customers_audit after insert or update or delete on public.customers for each row execute function app.audit_row();
create trigger sales_audit after insert on public.sales for each row execute function app.audit_row();
create trigger invoices_audit after insert on public.invoices for each row execute function app.audit_row();
create trigger payments_audit after insert on public.payments for each row execute function app.audit_row();
create trigger expenses_audit after insert or update or delete on public.expenses for each row execute function app.audit_row();

-- A sale is only valid if, at commit, it has a matching invoice, payments that equal the total,
-- one 'sale' stock movement per line, and its audit record. This guards against any code path
-- (including a buggy future function or a service-role script) that writes half a sale.
create function app.assert_sale_complete() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_items int;
begin
  select count(*) into v_items from public.sale_items where sale_id = new.id;
  if v_items = 0 then
    raise exception 'sale % has no lines', new.id using errcode = 'TM012';
  end if;
  if (select coalesce(sum(line_total), 0) from public.sale_items where sale_id = new.id) <> new.total then
    raise exception 'sale % lines do not add up to the total', new.id using errcode = 'TM012';
  end if;
  if not exists (select 1 from public.invoices where sale_id = new.id and grand_total = new.total) then
    raise exception 'sale % has no matching invoice', new.id using errcode = 'TM012';
  end if;
  if (select count(*) from public.invoice_items ii join public.invoices i on i.id = ii.invoice_id
       where i.sale_id = new.id) <> v_items then
    raise exception 'sale % invoice lines do not match sale lines', new.id using errcode = 'TM012';
  end if;
  if (select coalesce(sum(amount), 0) from public.payments where sale_id = new.id) <> new.total then
    raise exception 'sale % payments do not equal the total', new.id using errcode = 'TM012';
  end if;
  if exists (select 1 from public.sale_items si
              where si.sale_id = new.id
                and not exists (select 1 from public.stock_movements m
                                 where m.sale_id = new.id and m.inventory_item_id = si.inventory_item_id
                                   and m.movement_type = 'sale')) then
    raise exception 'sale % has lines without a stock movement', new.id using errcode = 'TM012';
  end if;
  if not exists (select 1 from public.audit_logs
                  where action = 'sale.finalized' and table_name = 'sales' and record_id = new.id::text) then
    raise exception 'sale % has no audit record', new.id using errcode = 'TM012';
  end if;
  return null;
end $$;
create constraint trigger sales_must_be_complete after insert on public.sales
  deferrable initially deferred for each row execute function app.assert_sale_complete();

-- Conversely, a 'sale' stock movement must belong to a real sale line.
create function app.assert_sale_movement_has_line() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.movement_type = 'sale' and not exists (
       select 1 from public.sale_items where sale_id = new.sale_id and inventory_item_id = new.inventory_item_id) then
    raise exception 'sale movement for item % has no sale line', new.inventory_item_id using errcode = 'TM012';
  end if;
  return null;
end $$;
create constraint trigger stock_movements_sale_line after insert on public.stock_movements
  deferrable initially deferred for each row execute function app.assert_sale_movement_has_line();
