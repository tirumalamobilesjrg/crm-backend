-- Structural security checks read from the catalog: RLS everywhere, no accidental grants.

-- RLS is enabled on every table in public.
select t.ok(not exists (select 1 from pg_tables where schemaname = 'public' and not rowsecurity),
            'RLS is enabled on every public table',
            (select string_agg(tablename, ', ') from pg_tables where schemaname = 'public' and not rowsecurity));

-- anon: no privilege of any kind on any table, sequence or function ...
select t.ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f')
     and c.relname not like 'public_catalogue_%'
     and has_table_privilege('anon', c.oid, 'select,insert,update,delete,truncate,references,trigger')),
  'anon has no privilege on any public table or view except the public catalogue views');
select t.ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'S'
     and case when c.relkind = 'S' then has_sequence_privilege('anon', c.oid, 'usage,select,update') end),
  'anon has no privilege on any sequence');
select t.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app') and has_function_privilege('anon', p.oid, 'execute')),
  'anon cannot execute any function in public or app');
select t.ok(not has_schema_privilege('anon', 'app', 'usage'), 'anon has no usage on the private app schema');

-- ... and exactly SELECT on the four catalogue views.
select t.eq((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind = 'v'), 4::bigint, 'public schema contains exactly four views');
select t.ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname like 'public_catalogue_%'
     and (not has_table_privilege('anon', c.oid, 'select')
          or has_table_privilege('anon', c.oid, 'insert,update,delete,truncate'))),
  'anon has SELECT only on the catalogue views');

-- authenticated: API roles cannot write ledger / financial / internal tables directly.
select t.ok(not exists (
  select 1 from unnest(array['inventory_items','inventory_item_costs','inventory_identifiers','stock_movements',
                             'stock_adjustments','sales','sale_items','invoices','invoice_items','payments',
                             'invoice_sequences','audit_logs','idempotency_keys']) tbl
   where has_table_privilege('authenticated', format('public.%I', tbl)::regclass, 'insert,update,delete,truncate')),
  'authenticated has no write privilege on ledger and financial tables');
select t.ok(not exists (
  select 1 from unnest(array['idempotency_keys','inventory_identifiers','invoice_sequences']) tbl
   where has_table_privilege('authenticated', format('public.%I', tbl)::regclass, 'select')),
  'authenticated cannot even read internal bookkeeping tables');
select t.ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and has_table_privilege('authenticated', c.oid, 'truncate,references,trigger')),
  'authenticated has no TRUNCATE/REFERENCES/TRIGGER anywhere');

-- authenticated can call exactly the three business RPCs in public.
select t.eq((select string_agg(p.proname, ',' order by p.proname)
               from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')),
            'adjust_stock,finalize_sale,receive_purchase', 'authenticated can execute only the three business RPCs');
select t.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app') and p.prosecdef and not coalesce(p.proconfig @> array['search_path=""'], false)),
  'every SECURITY DEFINER function pins an empty search_path');
select t.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('public', p.oid, 'execute')),
  'no public-schema function is executable by PUBLIC');

-- Every table readable by authenticated has at least one policy (otherwise RLS silently hides everything).
select t.ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and has_table_privilege('authenticated', c.oid, 'select')
     and not exists (select 1 from pg_policy pol where pol.polrelid = c.oid)),
  'every authenticated-readable table has a policy');
select t.ok(not exists (select 1 from pg_policy pol join pg_class c on c.oid = pol.polrelid
                         join pg_namespace n on n.oid = c.relnamespace
                        where n.nspname = 'public' and (pol.polroles = '{0}' or pol.polroles @> array[(select oid from pg_roles where rolname = 'anon')])),
            'no policy targets PUBLIC or anon');

-- The catalogue views expose an explicit column allowlist and are the only definer-rights views.
select t.eq((select string_agg(c.relname || '.' || a.attname, ',' order by c.relname, a.attnum)
               from pg_class c join pg_namespace n on n.oid = c.relnamespace
               join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
              where n.nspname = 'public' and c.relkind = 'v'),
  'public_catalogue_images.id,public_catalogue_images.product_slug,public_catalogue_images.storage_path,public_catalogue_images.alt_text,public_catalogue_images.sort_order,public_catalogue_images.is_primary,'
  'public_catalogue_products.id,public_catalogue_products.slug,public_catalogue_products.name,public_catalogue_products.brand_name,public_catalogue_products.brand_slug,public_catalogue_products.category_name,public_catalogue_products.category_slug,public_catalogue_products.description,public_catalogue_products.published_at,public_catalogue_products.updated_at,public_catalogue_products.availability,'
  'public_catalogue_specifications.id,public_catalogue_specifications.product_slug,public_catalogue_specifications.group_name,public_catalogue_specifications.spec_key,public_catalogue_specifications.spec_value,public_catalogue_specifications.sort_order,'
  'public_catalogue_variants.id,public_catalogue_variants.product_slug,public_catalogue_variants.color,public_catalogue_variants.ram_gb,public_catalogue_variants.storage_gb,public_catalogue_variants.public_price,public_catalogue_variants.availability',
  'catalogue views expose exactly the approved columns');
select t.ok(not exists (select 1 from information_schema.view_column_usage u
                         where u.view_schema = 'public' and u.table_name in
                           ('inventory_item_costs','customers','suppliers','sales','invoices','payments','staff_profiles','purchases')),
            'catalogue views read no cost, customer, supplier, sales or staff table');
