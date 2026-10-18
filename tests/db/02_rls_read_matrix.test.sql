-- Who can read which table. Pattern letters per identity, in the order below:
--   T = sees every row, F = sees none, O = sees only own rows (exactly one row in the fixtures).
-- Identities: admin manager manager2 inactive-manager no-profile
do $$
declare
  roles text[] := array['admin', 'manager', 'manager2', 'inactive', 'nostaff'];
  uids uuid[] := array['a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002',
                       'a0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000006',
                       'a0000000-0000-0000-0000-000000000007']::uuid[];
  matrix text[][] := array[
    ['shop_settings',          'TTTFF'],
    ['staff_profiles',         'TTTFF'],
    ['audit_logs',             'TFFFF'],
    ['brands',                 'TTTFF'],
    ['categories',             'TTTFF'],
    ['products',               'TTTFF'],
    ['product_variants',       'TTTFF'],
    ['product_specifications', 'TTTFF'],
    ['product_images',         'TTTFF'],
    ['suppliers',              'TTTFF'],
    ['purchases',              'TTTFF'],
    ['purchase_items',         'TTTFF'],
    ['inventory_items',        'TTTFF'],
    ['inventory_item_costs',   'TTTFF'],
    ['stock_adjustments',      'TTTFF'],
    ['stock_movements',        'TTTFF'],
    ['customers',              'TTTFF'],
    ['sales',                  'TTTFF'],
    ['sale_items',             'TTTFF'],
    ['invoices',               'TTTFF'],
    ['invoice_items',          'TTTFF'],
    ['payments',               'TTTFF'],
    ['expenses',               'TTTFF'],
    ['stock_levels',           'TTTFF'],
    ['discount_policies',      'TTTFF'],
    ['discount_approvals',     'TFOFF'],
    ['inventory_identifier_corrections', 'TTTFF']];
  i int; j int; tbl text; pat text; total bigint; got bigint; want bigint; ch text;
begin
  for i in 1 .. array_length(matrix, 1) loop
    tbl := matrix[i][1];
    pat := matrix[i][2];
    perform t.reset();
    total := t.count_rows(tbl);
    perform t.ok(total > 0, format('fixture has rows in %s', tbl));

    for j in 1 .. 5 loop
      ch := substr(pat, j, 1);
      want := case ch when 'T' then total when 'F' then 0 else 1 end;
      perform t.as_user(uids[j]);
      got := t.count_rows(tbl);
      perform t.reset();
      perform t.eq(got, want, format('%s reads %s: %s', roles[j], tbl, case ch when 'T' then 'all rows' when 'F' then 'no rows' else 'own rows only' end));
    end loop;

    perform t.as_anon();
    perform t.throws(format('select count(*) from public.%I', tbl), '42501', format('anon is denied on %s', tbl));
    perform t.reset();
  end loop;
end $$;

-- Internal tables are not readable by any signed-in user, whatever their role.
do $$
declare tbl text;
begin
  foreach tbl in array array['idempotency_keys', 'inventory_identifiers', 'invoice_sequences'] loop
    perform t.as_user('a0000000-0000-0000-0000-000000000001');
    perform t.throws(format('select count(*) from public.%I', tbl), '42501', format('admin cannot read internal table %s', tbl));
    perform t.reset();
  end loop;
end $$;
