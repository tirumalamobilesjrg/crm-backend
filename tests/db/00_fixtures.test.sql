-- Builds a small shop through the public RPCs / RLS (not raw inserts) so later tests start from
-- realistic state, and asserts the happy path of each operation on the way.

create table t.fixtures (k text primary key, id uuid not null);
grant select on t.fixtures to public;
create function t.fx(p_k text) returns uuid language sql stable as $$ select id from t.fixtures where k = p_k $$;
grant execute on function t.fx(text) to public;

insert into auth.users (id, email) values
  ('a0000000-0000-0000-0000-000000000001', 'owner@example.test'),
  ('a0000000-0000-0000-0000-000000000002', 'manager@example.test'),
  ('a0000000-0000-0000-0000-000000000003', 'sales@example.test'),
  ('a0000000-0000-0000-0000-000000000004', 'inventory@example.test'),
  ('a0000000-0000-0000-0000-000000000005', 'accountant@example.test'),
  ('a0000000-0000-0000-0000-000000000006', 'inactive@example.test'),
  ('a0000000-0000-0000-0000-000000000007', 'nostaff@example.test'),
  ('a0000000-0000-0000-0000-000000000008', 'sales2@example.test');

insert into public.staff_profiles (user_id, full_name, role, is_active) values
  ('a0000000-0000-0000-0000-000000000001', 'Test Owner', 'owner', true),
  ('a0000000-0000-0000-0000-000000000002', 'Test Manager', 'manager', true),
  ('a0000000-0000-0000-0000-000000000003', 'Test Sales', 'sales_executive', true),
  ('a0000000-0000-0000-0000-000000000004', 'Test Inventory', 'inventory_executive', true),
  ('a0000000-0000-0000-0000-000000000005', 'Test Accountant', 'accountant', true),
  ('a0000000-0000-0000-0000-000000000006', 'Test Inactive', 'sales_executive', false),
  ('a0000000-0000-0000-0000-000000000008', 'Test Sales Two', 'sales_executive', true);

do $$
declare
  owner_ uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  sales uuid := 'a0000000-0000-0000-0000-000000000003';
  inv uuid := 'a0000000-0000-0000-0000-000000000004';
  brand uuid; cat uuid; p1 uuid; p2 uuid; v1 uuid; v2 uuid; sup uuid; pur uuid; pi1 uuid; pi2 uuid;
  cust uuid; r jsonb; items uuid[]; s1 jsonb; s2 jsonb; hidden_item uuid; p3 uuid; v3 uuid; pur2 uuid; pi3 uuid;
begin
  -- catalogue, created by the inventory executive (cannot publish)
  perform t.as_user(inv);
  insert into public.brands (name, slug) values ('TestBrand', 'testbrand') returning id into brand;
  insert into public.categories (name, slug) values ('Smartphones', 'smartphones') returning id into cat;
  insert into public.products (brand_id, category_id, name, slug, description)
    values (brand, cat, 'Nova X1', 'nova-x1', 'Published test phone') returning id into p1;
  insert into public.products (brand_id, category_id, name, slug, description)
    values (brand, cat, 'Hidden Y2', 'hidden-y2', 'Never published') returning id into p2;
  insert into public.product_variants (product_id, sku, color, ram_gb, storage_gb, mrp, selling_price)
    values (p1, 'NOVA-X1-8-128-BLK', 'Black', 8, 128, 72000, 70000) returning id into v1;
  insert into public.product_variants (product_id, sku, color, ram_gb, storage_gb, mrp, selling_price)
    values (p2, 'HID-Y2-4-64-BLU', 'Blue', 4, 64, 25000, 24000) returning id into v2;
  insert into public.product_specifications (product_id, spec_key, spec_value) values (p1, 'Display', '6.5 inch AMOLED');
  insert into public.product_images (product_id, storage_path, alt_text, is_primary)
    values (p1, 'products/nova-x1/front.webp', 'Nova X1 front', true);
  insert into public.suppliers (name) values ('Test Distributor') returning id into sup;
  insert into public.purchases (supplier_id, supplier_invoice_no) values (sup, 'INV-1001') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost)
    values (pur, v1, 3, 50000) returning id into pi1;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost)
    values (pur, v2, 1, 20000) returning id into pi2;

  perform t.ok((select total = 170000 from public.purchases where id = pur),
               'draft purchase total follows the lines (no tax columns)');

  -- an accessory: quantity-tracked SKU, 50 pieces received without any unit list
  insert into public.products (brand_id, category_id, name, slug, description)
    values (brand, cat, 'Nova Case', 'nova-case', 'Accessory, unpublished at first') returning id into p3;
  insert into public.product_variants (product_id, sku, color, mrp, selling_price, tracking_mode)
    values (p3, 'NOVA-CASE-BLK', 'Black', 999, 799, 'quantity') returning id into v3;
  insert into public.purchases (supplier_id, supplier_invoice_no) values (sup, 'INV-1002') returning id into pur2;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur2, v3, 50, 300) returning id into pi3;

  -- receipt
  r := public.receive_purchase('fixture-receive-1', pur, jsonb_build_array(
    jsonb_build_object('purchase_item_id', pi1, 'imei1', t.imei(1), 'imei2', t.imei(101)),
    jsonb_build_object('purchase_item_id', pi1, 'imei1', t.imei(2)),
    jsonb_build_object('purchase_item_id', pi1, 'imei1', t.imei(3)),
    jsonb_build_object('purchase_item_id', pi2, 'serial_number', 'sn-hid-0001')));
  perform t.eq((r ->> 'units_received')::int, 4, 'receive_purchase creates one item per serialized unit');
  r := public.receive_purchase('fixture-receive-2', pur2, '[]');
  perform t.eq((r ->> 'quantity_units_received')::int, 50, 'receive_purchase adds the ordered quantity of an accessory SKU');

  -- publication by manager
  perform t.as_user(mgr);
  update public.products set is_published = true where id = p1;
  update public.product_variants set public_price = 69999 where id = v1;

  -- customer + sales
  perform t.as_user(sales);
  insert into public.customers (name, phone) values ('Test Customer', '+919876543210') returning id into cust;

  select array_agg(id order by imei1) into items from public.inventory_items where variant_id = v1;
  r := public.finalize_sale('fixture-sale-1', cust,
    jsonb_build_array(jsonb_build_object('inventory_item_id', items[1], 'unit_price', 70000, 'discount_amount', 1000)),
    jsonb_build_object('method', 'upi', 'amount', 69000, 'reference', 'UPI-REF-1'), null, 'Regular customer');
  s1 := r;

  perform t.as_user(mgr);
  -- mixed cart: one phone + two cases; 5000 discount is 7.1% of the phone, within a manager's 20%
  r := public.finalize_sale('fixture-sale-2', null,
    jsonb_build_array(jsonb_build_object('inventory_item_id', items[2], 'unit_price', 70000, 'discount_amount', 5000),
                      jsonb_build_object('variant_id', v3, 'quantity', 2, 'unit_price', 799)),
    jsonb_build_object('method', 'cash', 'amount', 66598), null, 'Bulk buyer');
  s2 := r;

  -- a discount approval (manager -> second sales executive) and an identifier correction for the matrix tests
  perform t.as_user(mgr);
  perform public.grant_discount_approval('fixture-appr-1', 'a0000000-0000-0000-0000-000000000008', 5000, 'Loyal customer', 60);
  perform t.as_user(owner_);
  perform public.correct_item_identifiers('fixture-corr-1', items[3], jsonb_build_object('imei2', t.imei(103)),
                                          'Second IMEI was missed at goods receipt');

  -- one expense, and one damaged device (the unpublished product's unit)
  perform t.as_user('a0000000-0000-0000-0000-000000000005');
  insert into public.expenses (category, description, amount, paid_via) values ('Electricity', 'Shop bill', 4500, 'upi');
  perform t.as_user(inv);
  select id into hidden_item from public.inventory_items where variant_id = v2;
  perform public.adjust_stock('fixture-adjust-1', hidden_item, 'damaged', 'Screen cracked on receipt');

  perform t.reset();
  insert into t.fixtures values
    ('item_hidden', hidden_item), ('p_case', p3), ('v_case', v3),
    ('sale_by_sales', (s1 ->> 'sale_id')::uuid), ('invoice_by_sales', (s1 ->> 'invoice_id')::uuid),
    ('sale_by_manager', (s2 ->> 'sale_id')::uuid), ('invoice_by_manager', (s2 ->> 'invoice_id')::uuid),
    ('brand', brand), ('category', cat), ('p_published', p1), ('p_hidden', p2), ('v_published', v1), ('v_hidden', v2),
    ('supplier', sup), ('purchase', pur), ('pi1', pi1), ('pi2', pi2), ('customer', cust),
    ('item_sold_1', items[1]), ('item_sold_2', items[2]), ('item_stock', items[3]);
end $$;

select t.ok((select count(*) = 2 from public.sales), 'fixture: two sales exist');
select t.ok((select count(*) = 4 from public.inventory_items), 'fixture: four devices exist');
select t.eq((select on_hand from public.stock_levels where variant_id = t.fx('v_case')), 48, 'fixture: 50 cases received, 2 sold, 48 on hand');
select t.eq((select status::text from public.inventory_items where id = t.fx('item_stock')), 'in_stock', 'fixture: unsold device is in stock');
