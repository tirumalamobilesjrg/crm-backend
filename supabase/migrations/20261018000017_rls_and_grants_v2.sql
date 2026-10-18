-- 0017 Task 1B: RLS and grants for the new tables and functions. Same posture as 0008: nothing is
-- granted by default; every new table has RLS enabled and explicit policies.

alter table public.stock_levels enable row level security;
alter table public.discount_policies enable row level security;
alter table public.discount_approvals enable row level security;
alter table public.inventory_identifier_corrections enable row level security;

grant select on public.stock_levels, public.discount_policies, public.discount_approvals,
  public.inventory_identifier_corrections to authenticated;
-- Only discount_policies is directly writable (owner, by policy); everything else changes through functions.
grant insert, update on public.discount_policies to authenticated;

-- On-hand quantities of accessories are visible to all active staff (the POS needs them); never to anon.
create policy stock_levels_select on public.stock_levels for select to authenticated
  using ((select app.is_staff()));

-- Limits are visible to all staff so the POS can show them; only the owner changes them.
create policy discount_policies_select on public.discount_policies for select to authenticated
  using ((select app.is_staff()));
create policy discount_policies_insert on public.discount_policies for insert to authenticated
  with check ((select app.has_any_role('owner')));
create policy discount_policies_update on public.discount_policies for update to authenticated
  using ((select app.has_any_role('owner'))) with check ((select app.has_any_role('owner')));

-- Approvals: owner/manager/accountant see all; a seller or approver sees their own.
create policy discount_approvals_select on public.discount_approvals for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'accountant'))
         or ((select app.is_staff()) and (requested_for = (select auth.uid()) or approved_by = (select auth.uid()))));

create policy identifier_corrections_select on public.inventory_identifier_corrections for select to authenticated
  using ((select app.has_any_role('owner', 'manager', 'inventory_executive', 'accountant')));

revoke all on function public.finalize_sale(text, uuid, jsonb, jsonb, text, text, uuid),
  public.adjust_quantity_stock(text, uuid, integer, public.adjustment_reason, text),
  public.grant_discount_approval(text, uuid, numeric, text, integer),
  public.correct_item_identifiers(text, uuid, jsonb, text) from public, anon, authenticated;
revoke all on function app.sale_lines(jsonb), app.guard_variant_tracking(), app.guard_item_variant_mode(),
  app.guard_stock_levels(), app.guard_discount_approvals(), app.guard_inventory_identifiers()
  from public, anon, authenticated;
grant execute on function public.finalize_sale(text, uuid, jsonb, jsonb, text, text, uuid),
  public.adjust_quantity_stock(text, uuid, integer, public.adjustment_reason, text),
  public.grant_discount_approval(text, uuid, numeric, text, integer),
  public.correct_item_identifiers(text, uuid, jsonb, text) to authenticated;
