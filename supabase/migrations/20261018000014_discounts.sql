-- 0014 Task 1B: configurable discount limits, permissions, approvals and per-sale authorisation record.
--
--  * discount_policies  : per staff role - may it discount, max % per line, optional max amount per sale,
--                         and may it grant approvals to others. Owner-editable data, not code.
--  * discount_approvals : single-use, expiring, capped approval that an approver (owner/manager per policy)
--                         grants to a named seller; consumed by finalize_sale.
--  * sales.discount_*   : who authorised the discount, on what basis, and why.
-- The initial rows below are seed configuration only; the owner changes them in the CRM (audited).

create table public.discount_policies (
  role public.staff_role primary key,
  can_discount boolean not null default false,
  max_percent numeric(5, 2) not null default 0 check (max_percent between 0 and 100),   -- per line, % of gross
  max_amount public.inr,                                                                -- per sale; NULL = no cap
  can_approve boolean not null default false,                                           -- may grant approvals
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  constraint discount_policy_consistent check (
    (can_discount or (max_percent = 0 and max_amount is null))
    and (not can_approve or can_discount))
);
insert into public.discount_policies (role, can_discount, max_percent, max_amount, can_approve) values
  ('owner',               true,  100, null, true),
  ('manager',             true,   20, null, true),
  ('sales_executive',     true,    5, null, false),
  ('inventory_executive', false,   0, null, false),
  ('accountant',          false,   0, null, false);
create trigger discount_policies_updated before update on public.discount_policies
  for each row execute function app.set_updated_at();
create trigger discount_policies_no_delete before delete on public.discount_policies
  for each row execute function app.forbid_delete();
create trigger discount_policies_audit after insert or update or delete on public.discount_policies
  for each row execute function app.audit_row('role');

create table public.discount_approvals (
  id uuid primary key default gen_random_uuid(),
  requested_for uuid not null references public.staff_profiles (user_id) on delete restrict,
  approved_by uuid not null references public.staff_profiles (user_id) on delete restrict,
  max_amount public.inr not null check (max_amount > 0),             -- cap on the sale's total discount
  reason text not null check (length(btrim(reason)) >= 3),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_in_sale_id uuid references public.sales (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint approval_not_self check (requested_for <> approved_by),
  constraint approval_use_consistent check ((used_at is null) = (used_in_sale_id is null)),
  constraint approval_expiry check (expires_at > created_at)
);
create index discount_approvals_for_idx on public.discount_approvals (requested_for, created_at desc);

-- An approval can only be consumed once and is otherwise frozen.
create function app.guard_discount_approvals() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'discount approvals cannot be deleted' using errcode = 'TM010';
  end if;
  if old.used_at is not null
     or (new.id, new.requested_for, new.approved_by, new.max_amount, new.reason, new.expires_at, new.created_at)
        is distinct from (old.id, old.requested_for, old.approved_by, old.max_amount, old.reason, old.expires_at, old.created_at) then
    raise exception 'discount approvals are single-use and immutable' using errcode = 'TM010';
  end if;
  return new;
end $$;
create trigger discount_approvals_guard before update or delete on public.discount_approvals
  for each row execute function app.guard_discount_approvals();
create trigger discount_approvals_audit after insert or update on public.discount_approvals
  for each row execute function app.audit_row();

-- The limits formerly stored as a single setting now live in discount_policies.
alter table public.shop_settings drop column max_sales_exec_discount_pct;

-- Sales written before this migration (Task 1) have discounts but no recorded authoriser or reason. They are
-- labelled honestly as 'legacy_unrecorded' rather than given an invented authorisation. The sale function never
-- produces this value.
alter table public.sales
  add column discount_basis text not null default 'none'
    check (discount_basis in ('none', 'role_limit', 'manager_approval', 'legacy_unrecorded')),
  add column discount_authorized_by uuid references public.staff_profiles (user_id) on delete restrict,
  add column discount_approval_id uuid references public.discount_approvals (id) on delete restrict,
  add column discount_reason text;

alter table public.sales disable trigger sales_immutable;
update public.sales set discount_basis = 'legacy_unrecorded' where discount_total > 0;
alter table public.sales enable trigger sales_immutable;

alter table public.sales add constraint sales_discount_record check (
    (discount_total = 0 and discount_basis = 'none' and discount_authorized_by is null
       and discount_approval_id is null and discount_reason is null)
    or
    (discount_total > 0 and discount_basis in ('role_limit', 'manager_approval')
       and discount_authorized_by is not null
       and discount_reason is not null and length(btrim(discount_reason)) >= 3
       and ((discount_basis = 'manager_approval') = (discount_approval_id is not null)))
    or
    (discount_total > 0 and discount_basis = 'legacy_unrecorded'
       and discount_approval_id is null));
