-- 0022 Public shop profile: the shop's contact details are edited once, by an Admin in the CRM, and the public
-- website reads them through one definer-rights view with an explicit column list.
--
-- Added to shop_settings (Admin-only update, already audited): whatsapp, opening_hours, map_url, about.
-- public_shop_profile exposes ONLY shop_name, address, phone, whatsapp, email, opening_hours, map_url, about.
-- It does not expose legal_name, invoice_prefix, currency or anything else.

alter table public.shop_settings
  add column whatsapp text check (whatsapp is null or length(btrim(whatsapp)) between 1 and 30),
  add column opening_hours text check (opening_hours is null or length(btrim(opening_hours)) between 1 and 500),
  add column map_url text check (map_url is null or (map_url ~ '^https://[^[:space:]]+$' and length(map_url) <= 500)),
  add column about text check (about is null or length(btrim(about)) between 1 and 2000);

create view public.public_shop_profile with (security_invoker = false) as
select shop_name, address, phone, whatsapp, email, opening_hours, map_url, about
  from public.shop_settings;

revoke all on public.public_shop_profile from public, anon, authenticated;
grant select on public.public_shop_profile to anon, authenticated;
