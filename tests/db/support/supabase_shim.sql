-- Minimal emulation of the Supabase pieces the migrations depend on, for plain PostgreSQL.
-- NOT a migration: it is only applied by scripts/test-db.sh (TEST_MODE=shim). Against a real
-- Supabase stack (TEST_MODE=supabase) none of this is used. Differences: docs/TESTING.md.

do $$
begin
  if not exists (select from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
end $$;

grant anon, authenticated, service_role to authenticator;
-- Supabase's `postgres` role may SET ROLE to the API roles; mirror that for the connecting role.
do $$ begin execute format('grant anon, authenticated, service_role to %I', current_user); end $$;

create schema if not exists auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  created_at timestamptz not null default now()
);

create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid
$$;
create function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))::text
$$;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''),
                  nullif(current_setting('request.jwt.claims', true), ''))::jsonb
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.role(), auth.jwt() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

-- Supabase's default privileges: every new public object is open to the API roles. The migrations
-- must revoke these explicitly, and the tests verify they did.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

-- Supabase Storage emulation (the real service creates these tables, with more columns). Migration 0021 needs the
-- bucket and object tables to exist; the policies on storage.objects are the thing under test.
create schema if not exists storage;
create table storage.buckets (
  id text primary key,
  name text not null unique,
  owner uuid,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text,
  owner uuid,
  metadata jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (bucket_id, name)
);
alter table storage.buckets enable row level security;
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
-- Like Supabase, the API roles hold table privileges and row-level security decides what they can touch.
grant all on storage.buckets, storage.objects to anon, authenticated, service_role;
