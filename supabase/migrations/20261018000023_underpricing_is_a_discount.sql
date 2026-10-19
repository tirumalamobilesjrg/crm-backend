-- 0023 A unit price below the variant's selling price is a DISCOUNT, never a free price change.
--
-- Before this migration finalize_sale accepted any unit_price in (0, MRP]. A Manager without a discount allowance could
-- therefore sell a 19,000 phone for 1,000 by typing a low price: discount_basis 'none', no reason, no approval.
-- Now app.sale_lines (the single place where sale lines are parsed and priced) restates such a line as
-- unit_price = selling_price with the shortfall added to the line's discount. Every downstream rule then applies
-- unchanged: a reason is required, the role's allowance or an Admin approval is needed, and the invoice records
-- the true catalogue price and the discount. The sale total is unchanged (gross - discount stays the same).
-- A price ABOVE the selling price (up to the MRP ceiling from 0020) is still allowed and is not a discount.
-- Invalid prices (<= 0, more than 2 decimals) are left as sent so the existing validation still rejects them.

create or replace function app.sale_lines(p_items jsonb) returns table (
  ord int, kind text, inventory_item_id uuid, variant_id uuid, quantity int, qty_raw int,
  unit_price numeric, discount_amount numeric, gross numeric, line_total numeric,
  item_status public.inventory_status, tracking_mode public.tracking_mode, variant_active boolean,
  sku text, description text, imei1 text, imei2 text, serial_number text)
language sql stable set search_path = '' as $$
  select e.ord::int,
         case when x.item_id is not null and x.vid is null then 'serialized'
              when x.item_id is null and x.vid is not null then 'quantity' end,
         x.item_id, pv.id, q.eff, x.qty, n.price, n.disc, n.price * q.eff, n.price * q.eff - n.disc,
         ii.status, pv.tracking_mode, pv.is_active, pv.sku,
         concat_ws(' ', b.name, pr.name, pv.color,
                   case when pv.storage_gb is not null then pv.storage_gb::text || 'GB' end),
         ii.imei1, ii.imei2, ii.serial_number
    from jsonb_array_elements(p_items) with ordinality as e(elem, ord)
   cross join lateral (select (e.elem ->> 'inventory_item_id')::uuid as item_id,
                              (e.elem ->> 'variant_id')::uuid as vid,
                              (e.elem ->> 'quantity')::int as qty,
                              (e.elem ->> 'unit_price')::numeric as price,
                              coalesce((e.elem ->> 'discount_amount')::numeric, 0) as disc) x
   cross join lateral (select case when x.item_id is not null then 1 else coalesce(x.qty, 0) end as eff) q
    left join public.inventory_items ii on ii.id = x.item_id
    left join public.product_variants pv on pv.id = coalesce(ii.variant_id, x.vid)
    left join public.products pr on pr.id = pv.product_id
    left join public.brands b on b.id = pr.brand_id
   cross join lateral (
     select case when x.price > 0 and x.price = round(x.price, 2) and pv.selling_price > x.price
                 then pv.selling_price else x.price end as price,
            case when x.price > 0 and x.price = round(x.price, 2) and pv.selling_price > x.price
                 then x.disc + (pv.selling_price - x.price) * q.eff else x.disc end as disc) n
$$;
