-- Who can read which table. Pattern letters per role, in the order below:
--   T = sees every row, F = sees none, O = sees only own rows (exactly one row in the fixtures).
-- Roles: owner manager sales inventory accountant inactive nostaff sales2
do $$
declare
  roles text[] := array['owner', 'manager', 'sales', 'inventory', 'accountant', 'inactive', 'nostaff', 'sales2'];
  uids uuid[] := array['a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002',
                       'a0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000004',
                       'a0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000006',
                       'a0000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-000000000008']::uuid[];
  matrix text[][] := array[
    ['shop_settings',          'TTTTTFFT'],
    ['staff_profiles',         'TTOOOFFO'],
    ['audit_logs',             'TTFFFFFF'],
    ['brands',                 'TTTTTFFT'],
    ['categories',             'TTTTTFFT'],
    ['products',               'TTTTTFFT'],
    ['product_variants',       'TTTTTFFT'],
    ['product_specifications', 'TTTTTFFT'],
    ['product_images',         'TTTTTFFT'],
    ['suppliers',              'TTFTTFFF'],
    ['purchases',              'TTFTTFFF'],
    ['purchase_items',         'TTFTTFFF'],
    ['inventory_items',        'TTTTTFFT'],
    ['inventory_item_costs',   'TTFTTFFF'],
    ['stock_adjustments',      'TTFTTFFF'],
    ['stock_movements',        'TTFTTFFF'],
    ['customers',              'TTTFTFFT'],
    ['sales',                  'TTOFTFFF'],
    ['sale_items',             'TTOFTFFF'],
    ['invoices',               'TTOFTFFF'],
    ['invoice_items',          'TTOFTFFF'],
    ['payments',               'TTOFTFFF'],
    ['expenses',               'TTFFTFFF']];
  i int; j int; tbl text; pat text; total bigint; got bigint; want bigint; ch text;
begin
  for i in 1 .. array_length(matrix, 1) loop
    tbl := matrix[i][1];
    pat := matrix[i][2];
    perform t.reset();
    total := t.count_rows(tbl);
    perform t.ok(total > 0, format('fixture has rows in %s', tbl));

    for j in 1 .. 8 loop
      ch := substr(pat, j, 1);
      want := case ch when 'T' then total when 'F' then 0 else 1 end;
      if roles[j] = 'sales2' and ch = 'O' then want := 1; end if;
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
    perform t.throws(format('select count(*) from public.%I', tbl), '42501', format('owner cannot read internal table %s', tbl));
    perform t.reset();
  end loop;
end $$;
