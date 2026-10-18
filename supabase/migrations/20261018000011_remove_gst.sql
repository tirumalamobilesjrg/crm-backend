-- 0011 Task 1B: no GST in the MVP. Remove every tax calculation/breakdown column. Selling prices,
-- discounts and invoice totals remain. Nothing here (or in the invoice) is a statutory tax document.

drop function public.finalize_sale(text, uuid, jsonb, jsonb, text);
drop function app.sale_lines(jsonb);

alter table public.shop_settings drop column gstin, drop column state_code;
alter table public.customers drop column gstin;
alter table public.suppliers drop column gstin;
alter table public.product_variants drop column hsn_code, drop column gst_rate;

-- purchases: cost as paid to the supplier; total is simply the sum of the lines
alter table public.purchase_items drop column taxable_value, drop column tax_amount, drop column gst_rate;
alter table public.purchase_items
  add column line_total numeric(14, 2) generated always as (round(quantity * unit_cost, 2)) stored;
alter table public.purchases drop constraint purchases_total_consistent;
alter table public.purchases drop column subtotal, drop column tax_total;

create or replace function app.recalc_purchase_totals() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := case when tg_op = 'DELETE' then old.purchase_id else new.purchase_id end;
begin
  update public.purchases p
     set total = coalesce((select sum(line_total) from public.purchase_items where purchase_id = v_id), 0)
   where p.id = v_id;
  return null;
end $$;

alter table public.sale_items drop constraint sale_items_tax_split;
alter table public.sale_items drop column gst_rate, drop column taxable_value, drop column tax_amount;
alter table public.sales drop column tax_total;

alter table public.invoices drop constraint invoices_totals;
alter table public.invoices
  drop column shop_gstin, drop column shop_state_code, drop column customer_gstin,
  drop column taxable_total, drop column tax_total;
alter table public.invoices
  add constraint invoices_totals check (grand_total = subtotal - discount_total);
alter table public.invoice_items
  drop column hsn_code, drop column taxable_value, drop column gst_rate, drop column tax_amount;

-- The invoice number format keeps its shape (PFX/YY-YY/NNNNNN) purely as a readable, gapless series.
comment on table public.invoices is
  'Internal sale receipt with shop and customer snapshots. It carries no tax breakdown and makes no statutory tax-invoice claim.';
