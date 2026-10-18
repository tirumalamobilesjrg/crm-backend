-- Migration 0022: public shop profile. Admin edits shop_settings; anon reads only the whitelisted columns.
do $$
declare
  adm uuid := 'a0000000-0000-0000-0000-000000000001';
  mgr uuid := 'a0000000-0000-0000-0000-000000000002';
  n bigint;
begin
  perform t.reset();
  update public.shop_settings set legal_name = 'Secret Legal Name Pvt', invoice_prefix = 'ZZ', address = '1 Main Road', phone = '+91 98765 43210',
         whatsapp = '9876543210', opening_hours = 'Mon-Sat 10:00-21:00', map_url = 'https://maps.example.com/x', about = 'Local mobile shop.';

  perform t.as_anon();
  perform t.eq((select count(*) from public.public_shop_profile), 1::bigint, 'anon can read the shop profile');
  perform t.eq((select address from public.public_shop_profile), '1 Main Road', 'the address is exposed');
  perform t.eq((select whatsapp from public.public_shop_profile), '9876543210', 'the WhatsApp number is exposed');
  perform t.ok(not exists (select 1 from public.public_shop_profile p where to_jsonb(p)::text ~* '(secret legal|invoice|ZZ|currency)'),
               'legal name and invoice prefix are not exposed');
  perform t.throws('select legal_name from public.shop_settings', '42501', 'anon cannot read shop_settings directly');
  perform t.throws($q$update public.public_shop_profile set about = 'x'$q$, '42501', 'anon cannot write the profile view');
  perform t.throws($q$insert into public.public_shop_profile (shop_name) values ('x')$q$, '42501', 'anon cannot insert into the profile view');

  -- columns are exactly the allowlist
  perform t.reset();
  perform t.eq((select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a
                 where a.attrelid = 'public.public_shop_profile'::regclass and a.attnum > 0 and not a.attisdropped),
               'shop_name,address,phone,whatsapp,email,opening_hours,map_url,about', 'the profile view exposes exactly the approved columns');

  -- Admin edits; Manager cannot
  perform t.as_user(adm);
  perform t.eq(t.affected($q$update public.shop_settings set about = 'Updated by admin'$q$), 1::bigint, 'an Admin can edit the profile');
  perform t.as_user(mgr);
  perform t.eq(t.affected($q$update public.shop_settings set about = 'Hacked by manager'$q$), 0::bigint, 'a Manager cannot edit the profile');
  perform t.as_anon();
  perform t.eq((select about from public.public_shop_profile), 'Updated by admin', 'the website sees the Admin edit');

  -- validation
  perform t.reset();
  perform t.throws($q$update public.shop_settings set map_url = 'javascript:alert(1)'$q$, '23514', 'the map link must be https');
  perform t.throws($q$update public.shop_settings set map_url = 'http://insecure.example.com'$q$, '23514', 'an http map link is refused');
  perform t.throws($q$update public.shop_settings set about = '   '$q$, '23514', 'a blank about text is refused (use NULL)');
  perform t.lives($q$update public.shop_settings set whatsapp = null, opening_hours = null, map_url = null, about = null$q$, 'every optional field can be cleared');
end $$;
