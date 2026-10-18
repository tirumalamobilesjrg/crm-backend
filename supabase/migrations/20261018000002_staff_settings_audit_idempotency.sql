-- 0002 shop settings, staff profiles/roles, audit log, idempotency keys.

create table public.shop_settings (
  id boolean primary key default true check (id),            -- singleton row
  shop_name text not null check (length(btrim(shop_name)) between 1 and 120),
  legal_name text,
  gstin text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  address text,
  state_code text check (state_code is null or state_code ~ '^[0-9]{2}$'),
  phone text,
  email text,
  -- GST rule 46 limits invoice numbers to 16 characters: PREFIX(<=3)/YY-YY/NNNNNN
  invoice_prefix text not null default 'TM' check (invoice_prefix ~ '^[A-Z0-9]{1,3}$'),
  max_sales_exec_discount_pct numeric(5, 2) not null default 5
    check (max_sales_exec_discount_pct between 0 and 100),
  currency text not null default 'INR' check (currency = 'INR'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
insert into public.shop_settings (shop_name) values ('Tirumala Mobiles');
create trigger shop_settings_updated before update on public.shop_settings
  for each row execute function app.set_updated_at();
create trigger shop_settings_no_delete before delete on public.shop_settings
  for each row execute function app.forbid_delete();

create table public.staff_profiles (
  user_id uuid primary key references auth.users (id) on delete restrict,
  full_name text not null check (length(btrim(full_name)) between 1 and 120),
  role public.staff_role not null,
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger staff_profiles_updated before update on public.staff_profiles
  for each row execute function app.set_updated_at();
create trigger staff_profiles_no_delete before delete on public.staff_profiles
  for each row execute function app.forbid_delete();

-- Role helpers. SECURITY DEFINER so policies on staff_profiles cannot recurse.
create function app.current_staff_role() returns public.staff_role
language sql stable security definer set search_path = '' as $$
  select sp.role from public.staff_profiles sp where sp.user_id = auth.uid() and sp.is_active
$$;

create function app.has_any_role(variadic p_roles public.staff_role[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(app.current_staff_role() = any (p_roles), false)
$$;

create function app.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select app.current_staff_role() is not null
$$;

create function app.guard_last_owner() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.role = 'owner' and old.is_active and (new.role <> 'owner' or not new.is_active)
     and not exists (select 1 from public.staff_profiles s
                      where s.role = 'owner' and s.is_active and s.user_id <> old.user_id) then
    raise exception 'cannot demote or deactivate the last active owner' using errcode = 'TM011';
  end if;
  return new;
end $$;
create trigger staff_profiles_last_owner before update on public.staff_profiles
  for each row execute function app.guard_last_owner();

-- Audit log: append-only, written only by trigger/definer functions.
create table public.audit_logs (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  actor_id uuid,                       -- no FK on purpose: history must outlive users
  actor_role public.staff_role,
  action text not null,
  table_name text,
  record_id text,
  old_data jsonb,
  new_data jsonb,
  detail jsonb
);
create index audit_logs_record_idx on public.audit_logs (table_name, record_id);
create index audit_logs_occurred_idx on public.audit_logs (occurred_at desc);
create trigger audit_logs_immutable before update or delete on public.audit_logs
  for each row execute function app.forbid_mutation();

-- Generic row audit. Argument 0 = primary key column name (default 'id').
create function app.audit_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into public.audit_logs (actor_id, actor_role, action, table_name, record_id, old_data, new_data)
  values (auth.uid(), app.current_staff_role(), lower(tg_op), tg_table_name,
          v_row ->> coalesce(tg_argv[0], 'id'),
          case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return null;
end $$;

create trigger shop_settings_audit after insert or update or delete on public.shop_settings
  for each row execute function app.audit_row('id');
create trigger staff_profiles_audit after insert or update or delete on public.staff_profiles
  for each row execute function app.audit_row('user_id');

-- Idempotency. One row per (scope, key, actor). The row is inserted inside the same transaction as
-- the business operation, so it exists only if the operation committed; a concurrent duplicate
-- blocks on the unique index until the first transaction finishes.
create table public.idempotency_keys (
  scope text not null,
  idem_key text not null check (length(idem_key) between 8 and 128),
  actor_id uuid not null,
  request_hash text not null,
  response jsonb,                      -- null only while the owning transaction is open
  created_at timestamptz not null default now(),
  primary key (scope, idem_key, actor_id)
);
create index idempotency_keys_created_idx on public.idempotency_keys (created_at);

-- Returns NULL when the caller should proceed, or the stored response when this is a replay.
create function app.idem_begin(p_scope text, p_key text, p_hash text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_rows int;
  v_row public.idempotency_keys;
begin
  if p_key is null or length(p_key) not between 8 and 128 then
    raise exception 'idempotency key must be 8-128 characters' using errcode = 'TM003';
  end if;
  insert into public.idempotency_keys (scope, idem_key, actor_id, request_hash)
  values (p_scope, p_key, auth.uid(), p_hash)
  on conflict do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 1 then
    return null;
  end if;
  select * into v_row from public.idempotency_keys
   where scope = p_scope and idem_key = p_key and actor_id = auth.uid();
  if v_row.request_hash <> p_hash then
    raise exception 'idempotency key was already used with a different request' using errcode = 'TM002';
  end if;
  return v_row.response;
end $$;

create function app.idem_complete(p_scope text, p_key text, p_response jsonb) returns void
language sql security definer set search_path = '' as $$
  update public.idempotency_keys set response = p_response
   where scope = p_scope and idem_key = p_key and actor_id = auth.uid()
$$;
