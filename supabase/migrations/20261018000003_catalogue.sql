-- 0003 catalogue.
--   product         = a model (e.g. "Galaxy S24"); what the public website describes.
--   product_variant = a sellable SKU of that model (colour / RAM / storage); carries price + GST.
--   inventory_item  = one physical device with its own IMEI/serial (see 0005).

create table public.brands (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index brands_name_key on public.brands (lower(name));

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index categories_name_key on public.categories (lower(name));

create table public.products (
  id uuid primary key default gen_random_uuid(),
  brand_id uuid not null references public.brands (id) on delete restrict,
  category_id uuid not null references public.categories (id) on delete restrict,
  name text not null check (length(btrim(name)) between 1 and 160),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  description text,
  is_published boolean not null default false,
  published_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint products_published_consistent check (is_published = (published_at is not null))
);
create unique index products_brand_name_key on public.products (brand_id, lower(name));
create index products_published_idx on public.products (is_published) where is_published;
create index products_category_idx on public.products (category_id);

create table public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete restrict,
  sku text not null unique check (sku ~ '^[A-Z0-9][A-Z0-9._-]{1,39}$'),
  color text,
  ram_gb smallint check (ram_gb > 0),
  storage_gb integer check (storage_gb > 0),
  hsn_code text not null default '8517' check (hsn_code ~ '^[0-9]{4,8}$'),
  gst_rate public.gst_rate not null default 18,
  mrp public.inr not null,
  selling_price public.inr not null,
  -- Price shown on the public website. NULL = "contact the shop". Never derived from selling_price.
  public_price public.inr,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint variants_price_le_mrp check (selling_price <= mrp),
  unique (id, product_id)
);
create unique index product_variants_attrs_key on public.product_variants
  (product_id, coalesce(lower(color), ''), coalesce(ram_gb, 0), coalesce(storage_gb, 0));
create index product_variants_product_idx on public.product_variants (product_id);

create table public.product_specifications (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  group_name text not null default 'General',
  spec_key text not null check (length(btrim(spec_key)) > 0),
  spec_value text not null check (length(btrim(spec_value)) > 0),
  sort_order integer not null default 0,
  unique (product_id, group_name, spec_key)
);

create table public.product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  variant_id uuid,
  storage_path text not null unique
    check (storage_path !~ '(^/|\.\.)' and length(storage_path) <= 300),
  alt_text text not null default '',
  sort_order integer not null default 0,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  -- an image can only point at a variant of the same product
  foreign key (variant_id, product_id) references public.product_variants (id, product_id)
);
create unique index product_images_one_primary on public.product_images (product_id) where is_primary;

-- published_at follows is_published.
create function app.sync_published_at() returns trigger
language plpgsql as $$
begin
  if new.is_published then
    new.published_at := coalesce(case when tg_op = 'UPDATE' then old.published_at end, now());
  else
    new.published_at := null;
  end if;
  return new;
end $$;
create trigger products_published_at before insert or update on public.products
  for each row execute function app.sync_published_at();

-- Only owner/manager may publish products or set the public price. Direct DB sessions without a
-- JWT subject (migrations, service role) are exempt; anon/authenticated API users are not.
create function app.guard_publication() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_changed boolean;
begin
  if auth.uid() is null then
    return new;
  end if;
  if tg_table_name = 'products' then
    v_changed := new.is_published is distinct from (case when tg_op = 'UPDATE' then old.is_published else false end);
  else
    v_changed := new.public_price is distinct from (case when tg_op = 'UPDATE' then old.public_price end);
  end if;
  if v_changed and not app.has_any_role('owner', 'manager') then
    raise exception 'only owner or manager can change publication/public price' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger products_guard_publication before insert or update on public.products
  for each row execute function app.guard_publication();
create trigger variants_guard_publication before insert or update on public.product_variants
  for each row execute function app.guard_publication();

create trigger brands_updated before update on public.brands for each row execute function app.set_updated_at();
create trigger categories_updated before update on public.categories for each row execute function app.set_updated_at();
create trigger products_updated before update on public.products for each row execute function app.set_updated_at();
create trigger variants_updated before update on public.product_variants for each row execute function app.set_updated_at();

create trigger brands_audit after insert or update or delete on public.brands for each row execute function app.audit_row();
create trigger categories_audit after insert or update or delete on public.categories for each row execute function app.audit_row();
create trigger products_audit after insert or update or delete on public.products for each row execute function app.audit_row();
create trigger variants_audit after insert or update or delete on public.product_variants for each row execute function app.audit_row();
create trigger specs_audit after insert or update or delete on public.product_specifications for each row execute function app.audit_row();
create trigger images_audit after insert or update or delete on public.product_images for each row execute function app.audit_row();
