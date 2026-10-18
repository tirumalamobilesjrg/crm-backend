-- 0001 foundation: private schema, privilege defaults, enums, domains, shared helpers.
--
-- Supabase grants broad default privileges to anon/authenticated on new objects in `public`.
-- This project grants everything explicitly, so those defaults are removed first.

create schema if not exists app;
comment on schema app is
  'Private helpers: RLS predicates, trigger functions, idempotency. Never add app to the Data API exposed schemas.';

revoke all on schema app from public;
grant usage on schema app to authenticated, service_role;

alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
alter default privileges revoke execute on functions from public;

-- Roles for staff. A user holds exactly one role (see staff_profiles).
create type public.staff_role as enum (
  'owner', 'manager', 'sales_executive', 'inventory_executive', 'accountant'
);

-- Lifecycle of one physical device. Changes only through stock_movements.
create type public.inventory_status as enum (
  'in_stock', 'sold', 'damaged', 'lost', 'returned_to_supplier'
);
create type public.item_condition as enum ('new', 'refurbished', 'used');
create type public.movement_type as enum ('purchase_receipt', 'sale', 'adjustment');
create type public.purchase_status as enum ('draft', 'received', 'cancelled');
create type public.payment_method as enum ('cash', 'upi', 'card', 'bank_transfer', 'cheque');
create type public.adjustment_reason as enum (
  'damaged', 'lost', 'found', 'repaired', 'returned_to_supplier'
);

-- Money is numeric(12,2) in INR, never float. Domains do not enforce NOT NULL; columns do.
create domain public.inr as numeric(12, 2) check (value >= 0);
create domain public.gst_rate as numeric(5, 2) check (value >= 0 and value <= 100);

create function app.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- IMEI = 15 digits with a valid Luhn check digit.
create function app.is_valid_imei(p_value text) returns boolean
language sql immutable parallel safe as $$
  select case when p_value ~ '^[0-9]{15}$' then
    (select sum(case when (16 - i) % 2 = 0 then (d * 2) / 10 + (d * 2) % 10 else d end) % 10 = 0
       from (select i, substr(p_value, i, 1)::int as d from generate_series(1, 15) as i) s)
  else false end
$$;

-- Indian financial year (April-March) as 'YY-YY', in Asia/Kolkata time.
create function app.fiscal_year(p_ts timestamptz) returns text
language sql stable as $$
  select lpad((y % 100)::text, 2, '0') || '-' || lpad(((y + 1) % 100)::text, 2, '0')
  from (select extract(year from (p_ts at time zone 'Asia/Kolkata'))::int
               - case when extract(month from (p_ts at time zone 'Asia/Kolkata')) < 4 then 1 else 0 end as y) f
$$;

create function app.forbid_mutation() returns trigger
language plpgsql as $$
begin
  raise exception '% is append-only (% is not allowed)', tg_table_name, tg_op using errcode = 'TM010';
end $$;

create function app.forbid_delete() returns trigger
language plpgsql as $$
begin
  raise exception 'rows in % cannot be deleted; deactivate or reverse them instead', tg_table_name
    using errcode = 'TM010';
end $$;
