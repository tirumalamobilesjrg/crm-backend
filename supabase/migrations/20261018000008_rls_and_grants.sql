-- 0008 row level security and grants. Deny by default: every table has RLS enabled, API roles get
-- only the table privileges listed here, and RLS policies narrow them per staff role.
-- Roles: owner, manager, sales_executive (sales), inventory_executive (inventory), accountant.
-- Full matrix: docs/SECURITY.md.

-- Helpers used only by policies.
create function app.purchase_is_draft(p_purchase_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.purchases where id = p_purchase_id and status = 'draft')
$$;

create function app.can_view_sale(p_sale_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.has_any_role('owner', 'manager', 'accountant')
      or (app.has_any_role('sales_executive')
          and exists (select 1 from public.sales s where s.id = p_sale_id and s.sold_by = auth.uid()))
$$;

create function app.can_view_invoice(p_invoice_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.invoices i where i.id = p_invoice_id and app.can_view_sale(i.sale_id))
$$;

-- Start from nothing, then grant explicitly.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema app from public, anon, authenticated;

grant execute on function app.current_staff_role(), app.has_any_role(public.staff_role[]), app.is_staff(),
  app.purchase_is_draft(uuid), app.can_view_sale(uuid), app.can_view_invoice(uuid), app.is_valid_imei(text)
  to authenticated, service_role;
grant execute on function public.finalize_sale(text, uuid, jsonb, jsonb, text),
  public.receive_purchase(text, uuid, jsonb),
  public.adjust_stock(text, uuid, public.adjustment_reason, text)
  to authenticated;

alter table public.shop_settings enable row level security;
alter table public.staff_profiles enable row level security;
alter table public.audit_logs enable row level security;
alter table public.idempotency_keys enable row level security;
alter table public.brands enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_variants enable row level security;
alter table public.product_specifications enable row level security;
alter table public.product_images enable row level security;
alter table public.suppliers enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_items enable row level security;
alter table public.inventory_items enable row level security;
alter table public.inventory_identifiers enable row level security;
alter table public.inventory_item_costs enable row level security;
alter table public.stock_adjustments enable row level security;
alter table public.stock_movements enable row level security;
alter table public.customers enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.invoice_sequences enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments enable row level security;
alter table public.expenses enable row level security;

-- SELECT privilege (RLS filters rows). Internal tables get none: idempotency_keys,
-- inventory_identifiers, invoice_sequences are reachable only via definer functions.
grant select on public.shop_settings, public.staff_profiles, public.audit_logs,
  public.brands, public.categories, public.products, public.product_variants,
  public.product_specifications, public.product_images, public.suppliers, public.purchases,
  public.purchase_items, public.inventory_items, public.inventory_item_costs, public.stock_adjustments,
  public.stock_movements, public.customers, public.sales, public.sale_items, public.invoices,
  public.invoice_items, public.payments, public.expenses
  to authenticated;

-- Direct-write master data. Ledger/financial tables are deliberately absent: they change only
-- through finalize_sale / receive_purchase / adjust_stock.
grant insert, update, delete on public.brands, public.categories, public.products, public.product_variants,
  public.product_specifications, public.product_images, public.suppliers, public.purchases,
  public.purchase_items to authenticated;
grant insert, update, delete on public.customers, public.expenses to authenticated;
grant insert, update on public.staff_profiles to authenticated;
grant update on public.shop_settings to authenticated;

-- shop_settings
create policy shop_settings_select on public.shop_settings for select to authenticated
  using ((select app.is_staff()));
create policy shop_settings_update on public.shop_settings for update to authenticated
  using ((select app.has_any_role('owner'))) with check ((select app.has_any_role('owner')));

-- staff_profiles: own active row; owner/manager see all; only owner writes.
create policy staff_select on public.staff_profiles for select to authenticated
  using ((user_id = (select auth.uid()) and is_active) or (select app.has_any_role('owner', 'manager')));
create policy staff_insert on public.staff_profiles for insert to authenticated
  with check ((select app.has_any_role('owner')));
create policy staff_update on public.staff_profiles for update to authenticated
  using ((select app.has_any_role('owner'))) with check ((select app.has_any_role('owner')));

-- audit_logs
create policy audit_select on public.audit_logs for select to authenticated
  using ((select app.has_any_role('owner', 'manager')));

-- Catalogue: every active staff member reads; owner/manager/inventory write.
create policy brands_select on public.brands for select to authenticated using ((select app.is_staff()));
create policy brands_write on public.brands for all to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')))
  with check ((select app.has_any_role('owner', 'manager', 'inventory_executive')));
create policy categories_select on public.categories for select to authenticated using ((select app.is_staff()));
create policy categories_write on public.categories for all to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')))
  with check ((select app.has_any_role('owner', 'manager', 'inventory_executive')));
create policy products_select on public.products for select to authenticated using ((select app.is_staff()));
create policy products_write on public.products for all to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')))
  with check ((select app.has_any_role('owner', 'manager', 'inventory_executive')));
create policy variants_select on public.product_variants for select to authenticated using ((select app.is_staff()));
create policy variants_write on public.product_variants for all to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')))
  with check ((select app.has_any_role('owner', 'manager', 'inventory_executive')));
create policy specs_select on public.product_specifications for select to authenticated using ((select app.is_staff()));
create policy specs_write on public.product_specifications for all to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')))
  with check ((select app.has_any_role('owner', 'manager', 'inventory_executive')));
create policy images_select on public.product_images for select to authenticated using ((select app.is_staff()));
create policy images_write on public.product_images for all to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')))
  with check ((select app.has_any_role('owner', 'manager', 'inventory_executive')));

-- Purchasing: costs are sensitive, so sales executives have no access.
create policy suppliers_select on public.suppliers for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive', 'accountant')));
create policy suppliers_write on public.suppliers for all to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')))
  with check ((select app.has_any_role('owner', 'manager', 'inventory_executive')));

create policy purchases_select on public.purchases for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive', 'accountant')));
create policy purchases_insert on public.purchases for insert to authenticated
  with check ((select app.has_any_role('owner', 'manager', 'inventory_executive')) and status = 'draft');
create policy purchases_update on public.purchases for update to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')) and status = 'draft')
  with check (status in ('draft', 'cancelled'));
create policy purchases_delete on public.purchases for delete to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')) and status = 'draft');

create policy purchase_items_select on public.purchase_items for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive', 'accountant')));
create policy purchase_items_write on public.purchase_items for all to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive')) and app.purchase_is_draft(purchase_id))
  with check ((select app.has_any_role('owner', 'manager', 'inventory_executive')) and app.purchase_is_draft(purchase_id));

-- Inventory: all staff see devices and status; cost and ledger are restricted.
create policy inventory_items_select on public.inventory_items for select to authenticated
  using ((select app.is_staff()));
create policy inventory_costs_select on public.inventory_item_costs for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive', 'accountant')));
create policy stock_adjustments_select on public.stock_adjustments for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive', 'accountant')));
create policy stock_movements_select on public.stock_movements for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive', 'accountant')));

-- Customers
create policy customers_select on public.customers for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'sales_executive', 'accountant')));
create policy customers_insert on public.customers for insert to authenticated
  with check ((select app.has_any_role('owner', 'manager', 'sales_executive')));
create policy customers_update on public.customers for update to authenticated
  using ((select app.has_any_role('owner', 'manager', 'sales_executive')))
  with check ((select app.has_any_role('owner', 'manager', 'sales_executive')));
create policy customers_delete on public.customers for delete to authenticated
  using ((select app.has_any_role('owner')));

-- Sales documents: owner/manager/accountant see all; a sales executive sees only their own sales.
create policy sales_select on public.sales for select to authenticated using (app.can_view_sale(id));
create policy sale_items_select on public.sale_items for select to authenticated using (app.can_view_sale(sale_id));
create policy invoices_select on public.invoices for select to authenticated using (app.can_view_sale(sale_id));
create policy invoice_items_select on public.invoice_items for select to authenticated using (app.can_view_invoice(invoice_id));
create policy payments_select on public.payments for select to authenticated using (app.can_view_sale(sale_id));

-- Expenses
create policy expenses_select on public.expenses for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'accountant')));
create policy expenses_insert on public.expenses for insert to authenticated
  with check ((select app.has_any_role('owner', 'manager', 'accountant')));
create policy expenses_update on public.expenses for update to authenticated
  using ((select app.has_any_role('owner', 'manager', 'accountant')))
  with check ((select app.has_any_role('owner', 'manager', 'accountant')));
create policy expenses_delete on public.expenses for delete to authenticated
  using ((select app.has_any_role('owner')));
