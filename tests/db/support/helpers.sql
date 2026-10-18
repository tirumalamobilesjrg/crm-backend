-- Tiny assertion library (no pgTAP dependency) plus Supabase-style request-context helpers.
-- Results accumulate in t.results across psql sessions; scripts/test-db.sh reports and fails on any `ok = false`.

drop schema if exists t cascade;
create schema t;
grant usage on schema t to public;

create table t.results (
  id serial primary key,
  file text,
  name text not null,
  ok boolean not null,
  detail text
);

create function t._record(p_name text, p_ok boolean, p_detail text default null) returns void
language sql security definer set search_path = pg_catalog, t as $$
  insert into t.results (file, name, ok, detail)
  values (nullif(current_setting('t.file', true), ''), p_name, p_ok, p_detail)
$$;

create function t.ok(p_cond boolean, p_name text, p_detail text default null) returns void
language plpgsql as $$
begin
  perform t._record(p_name, coalesce(p_cond, false), p_detail);
end $$;

create function t.eq(p_actual anyelement, p_expected anyelement, p_name text) returns void
language plpgsql as $$
begin
  perform t._record(p_name, p_actual is not distinct from p_expected,
                    format('expected %L, got %L', p_expected, p_actual));
end $$;

-- p_expected is a 5-character SQLSTATE or a case-insensitive message fragment.
create function t.throws(p_sql text, p_expected text, p_name text) returns void
language plpgsql as $$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    perform t._record(p_name, v_state = p_expected or v_msg ilike '%' || p_expected || '%',
                      format('raised %s: %s', v_state, v_msg));
    return;
  end;
  perform t._record(p_name, false, 'no error was raised');
end $$;

create function t.lives(p_sql text, p_name text) returns void
language plpgsql as $$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    perform t._record(p_name, false, format('raised %s: %s', v_state, v_msg));
    return;
  end;
  perform t._record(p_name, true);
end $$;

-- Simulate a PostgREST request: JWT claims + the `authenticated` / `anon` database role.
create function t.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  set role authenticated;
end $$;
create function t.as_anon() returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, false);
  set role anon;
end $$;
create function t.as_service() returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, false);
  set role service_role;
end $$;
create function t.reset() returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', '', false);
end $$;

-- A valid 15-digit IMEI (Luhn) derived from an integer, for fixtures.
create function t.imei(p_n bigint) returns text language sql immutable as $$
  select b || ((10 - (sum(case when (15 - i) % 2 = 1 then (d * 2) / 10 + (d * 2) % 10 else d end) % 10)) % 10)::text
    from (select lpad(p_n::text, 14, '0') as b) x,
         lateral (select i, substr(b, i, 1)::int as d from generate_series(1, 14) i) s
   group by b
$$;

-- Rows affected by a DML statement (data-modifying CTEs are not allowed inside scalar subqueries).
create function t.affected(p_sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

create function t.count_rows(p_table text) returns bigint language plpgsql as $$
declare n bigint;
begin
  execute format('select count(*) from public.%I', p_table) into n;
  return n;
end $$;
grant execute on all functions in schema t to public;
