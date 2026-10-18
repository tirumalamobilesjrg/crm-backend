-- 0013 Task 1B: exactly one manually recorded payment per sale; no split payments, credit or EMI.
--
-- A payment row is what a member of staff typed in after collecting money in the shop. Nothing verifies
-- it with a bank, UPI provider, card network or gateway, and `reference` is free text.

-- Upgrade safety: Task 1 allowed several payments per sale. Those cannot be merged automatically (payments are
-- immutable records of money received), so stop with a readable message instead of a cryptic index error.
do $$
begin
  if exists (select 1 from public.payments group by sale_id having count(*) > 1) then
    raise exception 'Existing sales have more than one payment (split payments were allowed before Task 1B). '
                    'Review them manually before applying this migration; Task 1 itself was never deployed.';
  end if;
end $$;

alter table public.payments
  add column entry_source text not null default 'manual' check (entry_source = 'manual');
comment on table public.payments is
  'One manually recorded, physically collected payment per sale. Not gateway-verified; no online payments.';
comment on column public.payments.entry_source is 'Always manual: staff-entered, unverified by any payment provider.';
comment on column public.payments.reference is 'Optional free-text note (e.g. UPI transaction id read from the customer phone). Unverified.';

drop index public.payments_sale_idx;
create unique index payments_one_per_sale on public.payments (sale_id);
create unique index payments_one_per_invoice on public.payments (invoice_id);

-- Completeness check at commit, now for quantity lines and the single payment.
create or replace function app.assert_sale_complete() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_items int;
begin
  select count(*) into v_items from public.sale_items where sale_id = new.id;
  if v_items = 0 then
    raise exception 'sale % has no lines', new.id using errcode = 'TM012';
  end if;
  if (select coalesce(sum(line_total), 0) from public.sale_items where sale_id = new.id) <> new.total then
    raise exception 'sale % lines do not add up to the total', new.id using errcode = 'TM012';
  end if;
  if (select coalesce(sum(discount_amount), 0) from public.sale_items where sale_id = new.id) <> new.discount_total then
    raise exception 'sale % line discounts do not add up to the discount total', new.id using errcode = 'TM012';
  end if;
  if not exists (select 1 from public.invoices where sale_id = new.id and grand_total = new.total) then
    raise exception 'sale % has no matching invoice', new.id using errcode = 'TM012';
  end if;
  if (select count(*) from public.invoice_items ii join public.invoices i on i.id = ii.invoice_id
       where i.sale_id = new.id) <> v_items then
    raise exception 'sale % invoice lines do not match sale lines', new.id using errcode = 'TM012';
  end if;
  if (select count(*) from public.payments where sale_id = new.id) <> 1
     or (select amount from public.payments where sale_id = new.id) <> new.total then
    raise exception 'sale % must have exactly one payment equal to the total', new.id using errcode = 'TM012';
  end if;
  if exists (select 1 from public.sale_items si
              where si.sale_id = new.id
                and not exists (select 1 from public.stock_movements m
                                 where m.sale_id = new.id and m.movement_type = 'sale'
                                   and ((si.inventory_item_id is not null and m.inventory_item_id = si.inventory_item_id)
                                     or (si.inventory_item_id is null and m.inventory_item_id is null
                                         and m.variant_id = si.variant_id and -m.quantity_delta = si.quantity)))) then
    raise exception 'sale % has lines without a stock movement', new.id using errcode = 'TM012';
  end if;
  if not exists (select 1 from public.audit_logs
                  where action = 'sale.finalized' and table_name = 'sales' and record_id = new.id::text) then
    raise exception 'sale % has no audit record', new.id using errcode = 'TM012';
  end if;
  return null;
end $$;
