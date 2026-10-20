
-- LaoMarket production Supabase schema (PostgreSQL)
-- Run in Supabase Dashboard > SQL Editor > New query.
-- Browser code uses ONLY the Publishable key. Secret/service_role keys stay server-side.

create extension if not exists pgcrypto;

do $$ begin
  create type public.app_role as enum ('customer','seller','affiliate','staff','admin');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  phone text,
  role public.app_role not null default 'customer',
  is_suspended boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.shops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  name text not null,
  description text,
  category text,
  phone text,
  status text not null default 'pending' check (status in ('pending','approved','suspended','rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete restrict,
  name text not null,
  description text,
  category text not null default 'Other',
  price_lak bigint not null check (price_lak >= 0),
  stock integer not null default 0 check (stock >= 0),
  emoji text not null default '📦',
  image_url text,
  status text not null default 'draft' check (status in ('draft','active','hidden','out_of_stock')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text unique not null default ('LM-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),
  customer_id uuid not null references public.profiles(id) on delete restrict,
  customer_name text not null,
  phone text not null,
  shipping_address text not null,
  subtotal_lak bigint not null check (subtotal_lak >= 0),
  shipping_lak bigint not null default 0 check (shipping_lak >= 0),
  total_lak bigint not null check (total_lak >= 0),
  payment_method text not null default 'cash_on_delivery',
  payment_status text not null default 'pending' check (payment_status in ('pending','confirmed','failed','refunded')),
  status text not null default 'pending' check (status in ('pending','confirmed','processing','shipped','delivered','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  shop_id uuid references public.shops(id) on delete set null,
  product_name text not null,
  quantity integer not null check (quantity > 0),
  unit_price_lak bigint not null check (unit_price_lak >= 0),
  line_total_lak bigint not null check (line_total_lak >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  provider text not null default 'manual',
  provider_reference text,
  amount_lak bigint not null check (amount_lak >= 0),
  status text not null default 'pending' check (status in ('pending','confirmed','failed','refunded')),
  proof_url text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.payout_requests (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete restrict,
  requested_by uuid not null references public.profiles(id) on delete restrict,
  amount_lak bigint not null check (amount_lak > 0),
  payout_method text not null,
  payout_account_masked text,
  status text not null default 'pending' check (status in ('pending','approved','paid','rejected')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.affiliate_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  referral_code text not null unique,
  status text not null default 'pending' check (status in ('pending','approved','suspended')),
  created_at timestamptz not null default now()
);

create table if not exists public.affiliate_commissions (
  id uuid primary key default gen_random_uuid(),
  affiliate_id uuid not null references public.affiliate_profiles(id) on delete restrict,
  order_id uuid not null references public.orders(id) on delete restrict,
  amount_lak bigint not null check (amount_lak >= 0),
  status text not null default 'pending' check (status in ('pending','approved','paid','cancelled')),
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.platform_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create index if not exists products_shop_id_idx on public.products(shop_id);
create index if not exists products_status_idx on public.products(status);
create index if not exists orders_customer_id_idx on public.orders(customer_id);
create index if not exists orders_created_at_idx on public.orders(created_at desc);
create index if not exists order_items_order_id_idx on public.order_items(order_id);
create index if not exists payments_order_id_idx on public.payments(order_id);
create index if not exists payouts_shop_id_idx on public.payout_requests(shop_id);

-- Admin check. A user becomes admin only when an existing project owner changes
-- their own profile role from the SQL Editor after verifying their account.
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and is_suspended = false
  );
$$;

create or replace function public.owns_shop(target_shop uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.shops
    where id = target_shop and owner_id = auth.uid()
  );
$$;

-- Create a customer profile after signup. Role is always customer on self-signup.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name',''), 'customer')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.shops enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payments enable row level security;
alter table public.payout_requests enable row level security;
alter table public.affiliate_profiles enable row level security;
alter table public.affiliate_commissions enable row level security;
alter table public.platform_settings enable row level security;

-- Profiles
drop policy if exists "profile read self or admin" on public.profiles;
create policy "profile read self or admin" on public.profiles for select
using (id = auth.uid() or public.is_admin());
drop policy if exists "profile update self or admin" on public.profiles;
drop policy if exists "admin update profiles" on public.profiles;
create policy "admin update profiles" on public.profiles for update
using (public.is_admin()) with check (public.is_admin());
-- For safety, normal users cannot update profile rows directly yet. Add a narrow
-- RPC for editable profile fields after the app's exact permissions are finalized.
-- Role promotion is intended to be done only by trusted project owner in SQL Editor.
-- Do not expose service_role keys in HTML.

-- Shops
drop policy if exists "public read approved shops" on public.shops;
create policy "public read approved shops" on public.shops for select
using (status = 'approved' or owner_id = auth.uid() or public.is_admin());
drop policy if exists "seller create own shop" on public.shops;
create policy "seller create own shop" on public.shops for insert
with check (owner_id = auth.uid() and status = 'pending');
drop policy if exists "owner update own shop or admin" on public.shops;
create policy "owner update own shop or admin" on public.shops for update
using (owner_id = auth.uid() or public.is_admin())
with check (owner_id = auth.uid() or public.is_admin());

-- Products
drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products for select
using (status = 'active' or public.owns_shop(shop_id) or public.is_admin());
drop policy if exists "shop owner insert products" on public.products;
create policy "shop owner insert products" on public.products for insert
with check (public.owns_shop(shop_id) and status in ('draft','active','hidden','out_of_stock'));
drop policy if exists "shop owner update products" on public.products;
create policy "shop owner update products" on public.products for update
using (public.owns_shop(shop_id) or public.is_admin())
with check (public.owns_shop(shop_id) or public.is_admin());
drop policy if exists "shop owner delete products" on public.products;
create policy "shop owner delete products" on public.products for delete
using (public.owns_shop(shop_id) or public.is_admin());

-- Orders: customers can read their own; admins can read all.
drop policy if exists "customer read own orders" on public.orders;
create policy "customer read own orders" on public.orders for select
using (customer_id = auth.uid() or public.is_admin());
drop policy if exists "customer create own pending order" on public.orders;
create policy "customer create own pending order" on public.orders for insert
with check (customer_id = auth.uid() and status = 'pending' and payment_status = 'pending');
drop policy if exists "admin update orders" on public.orders;
create policy "admin update orders" on public.orders for update
using (public.is_admin()) with check (public.is_admin());

-- Order items: customers read items for their orders; admin reads all.
drop policy if exists "read own order items or admin" on public.order_items;
create policy "read own order items or admin" on public.order_items for select
using (public.is_admin() or exists (
  select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid()
));
drop policy if exists "customer add items to own pending order" on public.order_items;
create policy "customer add items to own pending order" on public.order_items for insert
with check (exists (
  select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid() and o.status = 'pending'
));

-- Payments: customer can create pending payment only for own order; only admin can change status.
drop policy if exists "read own payments or admin" on public.payments;
create policy "read own payments or admin" on public.payments for select
using (customer_id = auth.uid() or public.is_admin());
drop policy if exists "customer create pending payment" on public.payments;
create policy "customer create pending payment" on public.payments for insert
with check (customer_id = auth.uid() and status = 'pending' and exists (
  select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid()
));
drop policy if exists "admin update payments" on public.payments;
create policy "admin update payments" on public.payments for update
using (public.is_admin()) with check (public.is_admin());

-- Payouts
drop policy if exists "seller read own payouts or admin" on public.payout_requests;
create policy "seller read own payouts or admin" on public.payout_requests for select
using (public.is_admin() or requested_by = auth.uid() or public.owns_shop(shop_id));
drop policy if exists "seller request payout" on public.payout_requests;
create policy "seller request payout" on public.payout_requests for insert
with check (requested_by = auth.uid() and public.owns_shop(shop_id) and status = 'pending');
drop policy if exists "admin manage payouts" on public.payout_requests;
create policy "admin manage payouts" on public.payout_requests for update
using (public.is_admin()) with check (public.is_admin());

-- Affiliates
drop policy if exists "affiliate read own or admin" on public.affiliate_profiles;
create policy "affiliate read own or admin" on public.affiliate_profiles for select
using (user_id = auth.uid() or public.is_admin());
drop policy if exists "user create own affiliate profile" on public.affiliate_profiles;
create policy "user create own affiliate profile" on public.affiliate_profiles for insert
with check (user_id = auth.uid() and status = 'pending');
drop policy if exists "affiliate commissions read own or admin" on public.affiliate_commissions;
create policy "affiliate commissions read own or admin" on public.affiliate_commissions for select
using (public.is_admin() or exists (
  select 1 from public.affiliate_profiles a where a.id = affiliate_id and a.user_id = auth.uid()
));
drop policy if exists "admin manage affiliate commissions" on public.affiliate_commissions;
create policy "admin manage affiliate commissions" on public.affiliate_commissions for all
using (public.is_admin()) with check (public.is_admin());

-- Settings are admin-only. Add initial settings.
drop policy if exists "admin read settings" on public.platform_settings;
create policy "admin read settings" on public.platform_settings for select
using (public.is_admin());
drop policy if exists "admin write settings" on public.platform_settings;
create policy "admin write settings" on public.platform_settings for all
using (public.is_admin()) with check (public.is_admin());

insert into public.platform_settings(key,value)
values
 ('currency', '{"code":"LAK","name":"Lao Kip"}'::jsonb),
 ('affiliate_commission_percent', '5'::jsonb),
 ('platform_fee_percent', '3'::jsonb)
on conflict (key) do nothing;

-- After creating your own user account in Authentication > Users, run this
-- separately in SQL Editor after replacing the email with your own admin email:
-- update public.profiles p
-- set role = 'admin'
-- from auth.users u
-- where p.id = u.id and u.email = 'YOUR_ADMIN_EMAIL_HERE';


-- Promotions and customer-support knowledge base
create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  discount_label text not null,
  promo_code text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_active boolean not null default false,
  terms text not null default '',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or starts_at is null or ends_at >= starts_at)
);
create index if not exists promotions_active_dates_idx on public.promotions(is_active, starts_at, ends_at);

create table if not exists public.support_faqs (
  id uuid primary key default gen_random_uuid(),
  question_lo text not null default '',
  question_th text not null default '',
  question_en text not null default '',
  answer_lo text not null default '',
  answer_th text not null default '',
  answer_en text not null default '',
  keywords text[] not null default '{}',
  is_published boolean not null default false,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.promotions enable row level security;
alter table public.support_faqs enable row level security;

drop policy if exists "public read active promotions" on public.promotions;
create policy "public read active promotions" on public.promotions for select
using (is_active = true or public.is_admin());
drop policy if exists "admin manage promotions" on public.promotions;
create policy "admin manage promotions" on public.promotions for all
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "public read published FAQs" on public.support_faqs;
create policy "public read published FAQs" on public.support_faqs for select
using (is_published = true or public.is_admin());
drop policy if exists "admin manage FAQs" on public.support_faqs;
create policy "admin manage FAQs" on public.support_faqs for all
using (public.is_admin()) with check (public.is_admin());


-- =====================================================================
-- v2: production hardening (safe to re-run)
-- =====================================================================
alter table public.profiles add column if not exists email text;
update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email is null;

alter table public.profiles add column if not exists address text;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, email, phone, address, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name',''), new.email,
          nullif(new.raw_user_meta_data->>'phone',''), nullif(new.raw_user_meta_data->>'address',''), 'customer')
  on conflict (id) do nothing;
  return new;
end; $$;

-- Sellers must not approve their own shop or change its owner.
create or replace function public.lock_shop_fields()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if new.status is distinct from old.status then raise exception 'only admin can change shop status'; end if;
    if new.owner_id is distinct from old.owner_id then raise exception 'cannot change shop owner'; end if;
  end if;
  return new;
end; $$;
drop trigger if exists lock_shop_fields on public.shops;
create trigger lock_shop_fields before update on public.shops
  for each row execute procedure public.lock_shop_fields();

drop policy if exists "admin insert shops" on public.shops;
create policy "admin insert shops" on public.shops for insert with check (public.is_admin());

-- Products are public only when their shop is approved.
drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products for select
using ((status = 'active' and exists (select 1 from public.shops s where s.id = shop_id and s.status = 'approved'))
       or public.owns_shop(shop_id) or public.is_admin());
drop policy if exists "shop owner insert products" on public.products;
create policy "shop owner insert products" on public.products for insert
with check (exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid() and s.status = 'approved')
            or public.is_admin());

-- Orders are created ONLY through place_order() (server-side pricing + stock check).
drop policy if exists "customer create own pending order" on public.orders;
drop policy if exists "customer add items to own pending order" on public.order_items;
drop policy if exists "customer create pending payment" on public.payments;

create or replace function public.place_order(
  p_name text, p_phone text, p_address text, p_method text, p_items jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); it record; pr record; q int;
  sub bigint := 0; ship bigint := 0; oid uuid; onum text;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if exists (select 1 from profiles where id = uid and is_suspended) then raise exception 'account_suspended'; end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_phone),'') = '' or coalesce(trim(p_address),'') = '' then
    raise exception 'missing_fields'; end if;
  if p_method not in ('cash_on_delivery','bank_transfer','qr_payment') then raise exception 'bad_payment_method'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'empty_cart'; end if;

  insert into orders (customer_id, customer_name, phone, shipping_address, subtotal_lak, shipping_lak, total_lak, payment_method)
  values (uid, trim(p_name), trim(p_phone), trim(p_address), 0, 0, 0, p_method)
  returning id, order_number into oid, onum;

  for it in select value from jsonb_array_elements(p_items) loop
    q := (it.value->>'qty')::int;
    if q is null or q <= 0 or q > 100 then raise exception 'bad_quantity'; end if;
    select p.* into pr from products p join shops s on s.id = p.shop_id
      where p.id = (it.value->>'id')::uuid and p.status = 'active' and s.status = 'approved'
      for update of p;
    if not found then raise exception 'product_unavailable'; end if;
    if pr.stock < q then raise exception 'out_of_stock: %', pr.name; end if;
    update products set stock = stock - q,
      status = case when stock - q = 0 then 'out_of_stock' else status end,
      updated_at = now() where id = pr.id;
    insert into order_items (order_id, product_id, shop_id, product_name, quantity, unit_price_lak, line_total_lak)
    values (oid, pr.id, pr.shop_id, pr.name, q, pr.price_lak, pr.price_lak * q);
    sub := sub + pr.price_lak * q;
  end loop;

  update orders set subtotal_lak = sub, total_lak = sub + ship where id = oid;
  insert into payments (order_id, customer_id, provider, amount_lak) values (oid, uid, p_method, sub + ship);
  return onum;
end; $$;
revoke all on function public.place_order(text,text,text,text,jsonb) from public, anon;
grant execute on function public.place_order(text,text,text,text,jsonb) to authenticated;

-- Storefront may read only the public support settings.
drop policy if exists "public read support settings" on public.platform_settings;
create policy "public read support settings" on public.platform_settings for select
using (key in ('support_whatsapp','support_welcome'));


-- =====================================================================
-- v3: seller center (cost price kept private + server-side product saving)
-- =====================================================================
create table if not exists public.product_costs (
  product_id uuid primary key references public.products(id) on delete cascade,
  shop_id uuid not null references public.shops(id) on delete cascade,
  cost_lak bigint not null check (cost_lak >= 0),
  updated_at timestamptz not null default now()
);
alter table public.product_costs enable row level security;
drop policy if exists "owner or admin read costs" on public.product_costs;
create policy "owner or admin read costs" on public.product_costs for select
  using (public.owns_shop(shop_id) or public.is_admin());

create or replace function public.seller_save_product(
  p_id uuid, p_shop uuid, p_name text, p_category text,
  p_price bigint, p_cost bigint, p_stock int, p_status text)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); pid uuid; st text := p_status;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from shops where id = p_shop and owner_id = uid and status = 'approved') then
    raise exception 'shop_not_approved'; end if;
  if coalesce(trim(p_name),'') = '' or length(p_name) > 200 then raise exception 'bad_name'; end if;
  if p_price is null or p_price <= 0 or p_cost is null or p_cost < 0 or p_stock is null or p_stock < 0 then
    raise exception 'bad_numbers'; end if;
  if st not in ('active','hidden','draft') then st := 'draft'; end if;
  if st = 'active' and p_stock = 0 then st := 'out_of_stock'; end if;
  if p_id is null then
    insert into products (shop_id, name, category, price_lak, stock, status)
    values (p_shop, trim(p_name), coalesce(nullif(p_category,''),'Other'), p_price, p_stock, st)
    returning id into pid;
  else
    update products set name = trim(p_name), category = coalesce(nullif(p_category,''),'Other'),
      price_lak = p_price, stock = p_stock, status = st, updated_at = now()
    where id = p_id and shop_id = p_shop returning id into pid;
    if pid is null then raise exception 'product_not_found'; end if;
  end if;
  insert into product_costs (product_id, shop_id, cost_lak) values (pid, p_shop, p_cost)
  on conflict (product_id) do update set cost_lak = excluded.cost_lak, updated_at = now();
  return pid;
end; $$;

create or replace function public.seller_delete_product(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  delete from products where id = p_id
    and shop_id in (select id from shops where owner_id = auth.uid());
end; $$;

revoke all on function public.seller_save_product(uuid,uuid,text,text,bigint,bigint,int,text) from public, anon;
grant execute on function public.seller_save_product(uuid,uuid,text,text,bigint,bigint,int,text) to authenticated;
revoke all on function public.seller_delete_product(uuid) from public, anon;
grant execute on function public.seller_delete_product(uuid) to authenticated;


-- =====================================================================
-- v4: product images (Supabase Storage) + image support in seller_save_product
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = 2097152, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "product images public read" on storage.objects;
create policy "product images public read" on storage.objects for select
  using (bucket_id = 'product-images');

drop policy if exists "product images seller upload" on storage.objects;
create policy "product images seller upload" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = auth.uid()::text
    and (public.is_admin() or exists (select 1 from public.shops s where s.owner_id = auth.uid() and s.status = 'approved'))
  );

drop policy if exists "product images owner delete" on storage.objects;
create policy "product images owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

drop function if exists public.seller_save_product(uuid,uuid,text,text,bigint,bigint,int,text);
create or replace function public.seller_save_product(
  p_id uuid, p_shop uuid, p_name text, p_category text,
  p_price bigint, p_cost bigint, p_stock int, p_status text, p_image text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); pid uuid; st text := p_status;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from shops where id = p_shop and owner_id = uid and status = 'approved') then
    raise exception 'shop_not_approved'; end if;
  if coalesce(trim(p_name),'') = '' or length(p_name) > 200 then raise exception 'bad_name'; end if;
  if p_price is null or p_price <= 0 or p_cost is null or p_cost < 0 or p_stock is null or p_stock < 0 then
    raise exception 'bad_numbers'; end if;
  -- image: null = keep, '' = remove, otherwise must be a public product-images URL inside the caller's own folder
  if p_image is not null and p_image <> '' and position('/storage/v1/object/public/product-images/' || uid::text || '/' in p_image) = 0 then
    raise exception 'bad_image'; end if;
  if st not in ('active','hidden','draft') then st := 'draft'; end if;
  if st = 'active' and p_stock = 0 then st := 'out_of_stock'; end if;
  if p_id is null then
    insert into products (shop_id, name, category, price_lak, stock, status, image_url)
    values (p_shop, trim(p_name), coalesce(nullif(p_category,''),'Other'), p_price, p_stock, st, nullif(p_image,''))
    returning id into pid;
  else
    update products set name = trim(p_name), category = coalesce(nullif(p_category,''),'Other'),
      price_lak = p_price, stock = p_stock, status = st, updated_at = now(),
      image_url = case when p_image is null then image_url else nullif(p_image,'') end
    where id = p_id and shop_id = p_shop returning id into pid;
    if pid is null then raise exception 'product_not_found'; end if;
  end if;
  insert into product_costs (product_id, shop_id, cost_lak) values (pid, p_shop, p_cost)
  on conflict (product_id) do update set cost_lak = excluded.cost_lak, updated_at = now();
  return pid;
end; $$;
revoke all on function public.seller_save_product(uuid,uuid,text,text,bigint,bigint,int,text,text) from public, anon;
grant execute on function public.seller_save_product(uuid,uuid,text,text,bigint,bigint,int,text,text) to authenticated;


-- =====================================================================
-- v5: order records, payment slips (private bucket), preliminary slip checks,
--     order tracking timeline, customer cancel + automatic restock
-- =====================================================================
alter table public.orders
  add column if not exists carrier text,
  add column if not exists tracking_number text;

alter table public.payments
  add column if not exists slip_path text,
  add column if not exists slip_hash text,
  add column if not exists declared_amount_lak bigint,
  add column if not exists transfer_ref text,
  add column if not exists declared_paid_at timestamptz,
  add column if not exists slip_submitted_at timestamptz;
create index if not exists payments_slip_hash_idx on public.payments(slip_hash);
create index if not exists payments_transfer_ref_idx on public.payments(lower(transfer_ref));

-- Automatic check results: visible to admin only (customers must not see the rules)
create table if not exists public.payment_checks (
  payment_id uuid primary key references public.payments(id) on delete cascade,
  status text not null check (status in ('pass','review','fail')),
  notes jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.payment_checks enable row level security;
drop policy if exists "admin read payment checks" on public.payment_checks;
create policy "admin read payment checks" on public.payment_checks for select using (public.is_admin());

-- Tracking timeline
create table if not exists public.order_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  event text not null,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists order_events_order_idx on public.order_events(order_id, created_at);
alter table public.order_events enable row level security;
drop policy if exists "read own order events or admin" on public.order_events;
create policy "read own order events or admin" on public.order_events for select
  using (public.is_admin() or exists (select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid()));

insert into public.order_events (order_id, event, created_at)
select o.id, 'created', o.created_at from public.orders o
where not exists (select 1 from public.order_events e where e.order_id = o.id);

create or replace function public.orders_before_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.payment_status = 'confirmed' and old.payment_status is distinct from 'confirmed' and new.status = 'pending' then
    new.status := 'confirmed';
  end if;
  return new;
end; $$;
drop trigger if exists orders_before_update on public.orders;
create trigger orders_before_update before update on public.orders
  for each row execute procedure public.orders_before_update();

create or replace function public.orders_after_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into order_events (order_id, event) values (new.id, 'created');
    return new;
  end if;
  if new.status is distinct from old.status then
    insert into order_events (order_id, event) values (new.id, 'status_' || new.status);
    if new.status = 'cancelled' and old.status <> 'cancelled' then
      update products p set stock = p.stock + i.q,
             status = case when p.status = 'out_of_stock' then 'active' else p.status end,
             updated_at = now()
      from (select product_id, sum(quantity) as q from order_items
            where order_id = new.id and product_id is not null group by product_id) i
      where p.id = i.product_id;
    end if;
  end if;
  if new.payment_status is distinct from old.payment_status then
    insert into order_events (order_id, event) values (new.id, 'payment_' || new.payment_status);
  end if;
  if new.tracking_number is distinct from old.tracking_number and new.tracking_number is not null then
    insert into order_events (order_id, event, note)
    values (new.id, 'tracking', trim(coalesce(new.carrier,'') || ' ' || new.tracking_number));
  end if;
  return new;
end; $$;
drop trigger if exists orders_after_change on public.orders;
create trigger orders_after_change after insert or update on public.orders
  for each row execute procedure public.orders_after_change();

-- Private bucket for payment slips (owner + admin can read)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-slips', 'payment-slips', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = 3145728, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "slips owner upload" on storage.objects;
create policy "slips owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'payment-slips' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "slips owner or admin read" on storage.objects;
create policy "slips owner or admin read" on storage.objects for select to authenticated
  using (bucket_id = 'payment-slips' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- Customer submits slip -> preliminary automatic checks (admin still confirms)
create or replace function public.submit_payment_slip(
  p_order_number text, p_path text, p_hash text, p_amount bigint, p_ref text, p_paid_at timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); o record; pay record;
  notes jsonb := '[]'::jsonb; st text := 'pass'; dup int;
  ref text := nullif(trim(p_ref), '');
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select * into o from orders where order_number = p_order_number and customer_id = uid;
  if not found then raise exception 'order_not_found'; end if;
  if o.payment_method = 'cash_on_delivery' then raise exception 'cod_no_slip'; end if;
  if o.status = 'cancelled' then raise exception 'order_cancelled'; end if;
  select * into pay from payments where order_id = o.id order by created_at desc limit 1 for update;
  if not found then raise exception 'payment_not_found'; end if;
  if pay.status in ('confirmed','refunded') then raise exception 'already_confirmed'; end if;
  if p_path is null or position(uid::text || '/' in p_path) <> 1 then raise exception 'bad_slip_path'; end if;
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then raise exception 'bad_hash'; end if;

  select count(*) into dup from payments where id <> pay.id and slip_hash = p_hash;
  if dup > 0 then
    notes := notes || jsonb_build_array(jsonb_build_object('code','duplicate_slip','level','fail','msg','ຮູບບິນນີ້ເຄີຍຖືກໃຊ້ກັບອໍເດີອື່ນ'));
    st := 'fail';
  end if;
  if ref is not null then
    select count(*) into dup from payments where id <> pay.id and lower(transfer_ref) = lower(ref);
    if dup > 0 then
      notes := notes || jsonb_build_array(jsonb_build_object('code','duplicate_ref','level','fail','msg','ເລກອ້າງອີງການໂອນຊ້ຳກັບອໍເດີອື່ນ'));
      st := 'fail';
    end if;
  else
    notes := notes || jsonb_build_array(jsonb_build_object('code','no_ref','level','info','msg','ບໍ່ໄດ້ໃສ່ເລກອ້າງອີງການໂອນ'));
  end if;
  if p_amount is distinct from o.total_lak then
    notes := notes || jsonb_build_array(jsonb_build_object('code','amount_mismatch','level','review',
      'msg','ຍອດທີ່ລູກຄ້າແຈ້ງ ' || coalesce(p_amount::text,'-') || ' ບໍ່ກົງກັບຍອດອໍເດີ ' || o.total_lak));
    if st = 'pass' then st := 'review'; end if;
  end if;
  if p_paid_at is null then
    notes := notes || jsonb_build_array(jsonb_build_object('code','no_time','level','review','msg','ບໍ່ໄດ້ແຈ້ງເວລາໂອນ'));
    if st = 'pass' then st := 'review'; end if;
  elsif p_paid_at < o.created_at - interval '10 minutes' then
    notes := notes || jsonb_build_array(jsonb_build_object('code','paid_before_order','level','review','msg','ເວລາໂອນກ່ອນເວລາສັ່ງຊື້'));
    if st = 'pass' then st := 'review'; end if;
  elsif p_paid_at > now() + interval '10 minutes' then
    notes := notes || jsonb_build_array(jsonb_build_object('code','paid_in_future','level','review','msg','ເວລາໂອນຢູ່ໃນອະນາຄົດ'));
    if st = 'pass' then st := 'review'; end if;
  elsif p_paid_at < now() - interval '7 days' then
    notes := notes || jsonb_build_array(jsonb_build_object('code','paid_too_old','level','review','msg','ເວລາໂອນເກົ່າກວ່າ 7 ວັນ'));
    if st = 'pass' then st := 'review'; end if;
  end if;

  update payments set slip_path = p_path, slip_hash = p_hash, declared_amount_lak = p_amount,
    transfer_ref = ref, declared_paid_at = p_paid_at, slip_submitted_at = now()
  where id = pay.id;
  insert into payment_checks (payment_id, status, notes) values (pay.id, st, notes)
  on conflict (payment_id) do update set status = excluded.status, notes = excluded.notes, created_at = now();
  insert into order_events (order_id, event) values (o.id, 'slip_submitted');
  return st;
end; $$;
revoke all on function public.submit_payment_slip(text,text,text,bigint,text,timestamptz) from public, anon;
grant execute on function public.submit_payment_slip(text,text,text,bigint,text,timestamptz) to authenticated;

-- Customer may cancel while unpaid and still pending (stock is restored by trigger)
create or replace function public.cancel_my_order(p_order_number text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update orders set status = 'cancelled', updated_at = now()
  where order_number = p_order_number and customer_id = auth.uid()
    and status = 'pending' and payment_status = 'pending';
  if not found then raise exception 'cannot_cancel'; end if;
end; $$;
revoke all on function public.cancel_my_order(text) from public, anon;
grant execute on function public.cancel_my_order(text) to authenticated;

-- Storefront may read the bank transfer info shown on the payment screen
drop policy if exists "public read support settings" on public.platform_settings;
create policy "public read support settings" on public.platform_settings for select
using (key in ('support_whatsapp','support_welcome','bank_info'));


-- =====================================================================
-- v6: customer notifications (email / WhatsApp outbox) + preferences
--     Sending is done by the Edge Function `send-notifications` (secrets stay server-side)
-- =====================================================================
alter table public.profiles
  add column if not exists notify_email boolean not null default true,
  add column if not exists notify_whatsapp boolean not null default true;

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  event text not null,
  channel text not null check (channel in ('email','whatsapp')),
  recipient text not null,
  subject text,
  message text not null,
  status text not null default 'pending' check (status in ('pending','sending','sent','failed','skipped')),
  attempts int not null default 0,
  error text,
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index if not exists notifications_queue_idx on public.notifications(status, created_at);
create index if not exists notifications_order_idx on public.notifications(order_id, created_at);
alter table public.notifications enable row level security;
drop policy if exists "admin read notifications" on public.notifications;
create policy "admin read notifications" on public.notifications for select using (public.is_admin());

create or replace function public.enqueue_order_notification()
returns trigger language plpgsql security definer set search_path = public as $$
declare o record; pr record; msg text; subj text; tn text; total text;
begin
  if new.event not in ('status_confirmed','status_processing','status_shipped','status_delivered','status_cancelled',
                       'payment_confirmed','payment_failed','tracking') then
    return new;
  end if;
  select * into o from orders where id = new.order_id;
  if not found then return new; end if;
  -- a paid order gets one combined message (payment_confirmed), not two
  if new.event = 'status_confirmed' and o.payment_status = 'confirmed' then return new; end if;
  -- avoid a second message when status_shipped and the tracking number are set together
  if new.event = 'tracking' then
    if o.status <> 'shipped' then return new; end if;
    if exists (select 1 from notifications where order_id = o.id and event = 'status_shipped'
               and created_at > now() - interval '1 minute') then return new; end if;
  end if;
  select email, notify_email, notify_whatsapp into pr from profiles where id = o.customer_id;
  total := to_char(o.total_lak, 'FM999,999,999,999,999');
  tn := case when o.tracking_number is not null
        then ' (' || trim(coalesce(o.carrier,'') || ' ເລກພັດສະດຸ ' || o.tracking_number) || ')' else '' end;
  msg := case new.event
    when 'status_confirmed'  then 'ອໍເດີ ' || o.order_number || ' ຂອງທ່ານຖືກຢືນຢັນແລ້ວ ຍອດລວມ ' || total || ' ກີບ. ຂອບໃຈທີ່ໃຊ້ LaoMarket.'
    when 'status_processing' then 'ອໍເດີ ' || o.order_number || ' ກຳລັງກະກຽມສິນຄ້າ.'
    when 'status_shipped'    then 'ອໍເດີ ' || o.order_number || ' ກຳລັງຈັດສົ່ງ' || tn || '.'
    when 'tracking'          then 'ອໍເດີ ' || o.order_number || ' ອັບເດດເລກພັດສະດຸ' || tn || '.'
    when 'status_delivered'  then 'ອໍເດີ ' || o.order_number || ' ຈັດສົ່ງສຳເລັດແລ້ວ. ຂອບໃຈທີ່ໃຊ້ LaoMarket!'
    when 'status_cancelled'  then 'ອໍເດີ ' || o.order_number || ' ຖືກຍົກເລີກ.'
    when 'payment_confirmed' then 'ໄດ້ຮັບການຊຳລະເງິນຂອງອໍເດີ ' || o.order_number || ' ແລ້ວ ແລະ ອໍເດີຖືກຢືນຢັນແລ້ວ. ຂອບໃຈທີ່ໃຊ້ LaoMarket!'
    when 'payment_failed'    then 'ການຊຳລະຂອງອໍເດີ ' || o.order_number || ' ບໍ່ຜ່ານການກວດສອບ ກະລຸນາສົ່ງບິນໃໝ່ ຫຼື ຕິດຕໍ່ຮ້ານ.'
  end;
  if msg is null then return new; end if;
  subj := 'LaoMarket — ອໍເດີ ' || o.order_number;
  if coalesce(pr.notify_email, true) and coalesce(pr.email,'') <> '' then
    insert into notifications (order_id, event, channel, recipient, subject, message)
    values (o.id, new.event, 'email', pr.email, subj, msg);
  end if;
  if coalesce(pr.notify_whatsapp, true) and coalesce(o.phone,'') <> '' then
    insert into notifications (order_id, event, channel, recipient, subject, message)
    values (o.id, new.event, 'whatsapp', o.phone, null, msg);
  end if;
  return new;
end; $$;
drop trigger if exists enqueue_order_notification on public.order_events;
create trigger enqueue_order_notification after insert on public.order_events
  for each row execute procedure public.enqueue_order_notification();

-- Used only by the Edge Function (service_role): atomically claim a batch
create or replace function public.claim_notifications(p_limit int default 50)
returns setof public.notifications language sql security definer set search_path = public as $$
  update notifications set status = 'sending', claimed_at = now(), attempts = attempts + 1
  where id in (
    select id from notifications
    where status = 'pending' or (status = 'sending' and claimed_at < now() - interval '5 minutes')
    order by created_at limit greatest(1, least(p_limit, 200))
    for update skip locked)
  returning *;
$$;
revoke all on function public.claim_notifications(int) from public, anon, authenticated;
grant execute on function public.claim_notifications(int) to service_role;

-- Customer notification preferences
create or replace function public.update_my_notify_prefs(p_email boolean, p_whatsapp boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update profiles set notify_email = coalesce(p_email, notify_email),
    notify_whatsapp = coalesce(p_whatsapp, notify_whatsapp), updated_at = now()
  where id = auth.uid();
end; $$;
revoke all on function public.update_my_notify_prefs(boolean,boolean) from public, anon;
grant execute on function public.update_my_notify_prefs(boolean,boolean) to authenticated;


-- =====================================================================
-- v7: shop profile, per-shop fulfillment (seller order management), reviews (stars),
--     sales report (revenue / cost / profit). Cost price is never exposed to customers.
-- =====================================================================
alter table public.shops
  add column if not exists logo_url text,
  add column if not exists address text;

-- ---- cost snapshot per order line (private) ----
create table if not exists public.order_item_costs (
  order_item_id uuid primary key references public.order_items(id) on delete cascade,
  shop_id uuid not null references public.shops(id) on delete cascade,
  unit_cost_lak bigint not null check (unit_cost_lak >= 0)
);
alter table public.order_item_costs enable row level security;
drop policy if exists "owner or admin read item costs" on public.order_item_costs;
create policy "owner or admin read item costs" on public.order_item_costs for select
  using (public.owns_shop(shop_id) or public.is_admin());

insert into public.order_item_costs (order_item_id, shop_id, unit_cost_lak)
select i.id, i.shop_id, c.cost_lak
from public.order_items i join public.product_costs c on c.product_id = i.product_id
where i.shop_id is not null
on conflict (order_item_id) do nothing;

-- ---- per-shop fulfillment ----
create table if not exists public.shop_orders (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  shop_id uuid not null references public.shops(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','confirmed','shipped','delivered','cancelled')),
  carrier text,
  tracking_number text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_id, shop_id)
);
create index if not exists shop_orders_shop_idx on public.shop_orders(shop_id, created_at desc);
alter table public.shop_orders enable row level security;
drop policy if exists "read own shop orders" on public.shop_orders;
create policy "read own shop orders" on public.shop_orders for select
  using (public.is_admin() or public.owns_shop(shop_id)
         or exists (select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid()));

create or replace function public._ful_rank(s text) returns int language sql immutable as $$
  select case s when 'pending' then 0 when 'confirmed' then 1 when 'processing' then 1
                when 'shipped' then 2 when 'delivered' then 3 else -1 end
$$;

create or replace function public.order_items_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.shop_id is not null then
    insert into shop_orders (order_id, shop_id) values (new.order_id, new.shop_id) on conflict do nothing;
    insert into order_item_costs (order_item_id, shop_id, unit_cost_lak)
    select new.id, new.shop_id, c.cost_lak from product_costs c where c.product_id = new.product_id
    on conflict (order_item_id) do nothing;
  end if;
  return new;
end; $$;
drop trigger if exists order_items_after_insert on public.order_items;
create trigger order_items_after_insert after insert on public.order_items
  for each row execute procedure public.order_items_after_insert();

insert into public.shop_orders (order_id, shop_id, status)
select distinct i.order_id, i.shop_id,
  case o.status when 'cancelled' then 'cancelled' when 'delivered' then 'delivered' when 'shipped' then 'shipped'
                when 'pending' then 'pending' else 'confirmed' end
from public.order_items i join public.orders o on o.id = i.order_id
where i.shop_id is not null
on conflict (order_id, shop_id) do nothing;

-- shop status drives the overall order status (never moves it backwards)
create or replace function public.shop_orders_after_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare o record; tot int; dcnt int; scnt int; ccnt int; newst text; sname text;
begin
  select * into o from orders where id = new.order_id;
  if not found or o.status = 'cancelled' then return new; end if;
  if new.status is distinct from old.status or new.tracking_number is distinct from old.tracking_number then
    select name into sname from shops where id = new.shop_id;
    insert into order_events (order_id, event, note)
    values (new.order_id, 'shop_' || new.status,
            trim(coalesce(sname,'') || coalesce(' · ' || nullif(trim(coalesce(new.carrier,'') || ' ' || coalesce(new.tracking_number,'')), ''), '')));
  end if;
  select count(*) filter (where status <> 'cancelled'),
         count(*) filter (where status = 'delivered'),
         count(*) filter (where status in ('shipped','delivered')),
         count(*) filter (where status in ('confirmed','shipped','delivered'))
    into tot, dcnt, scnt, ccnt from shop_orders where order_id = new.order_id;
  newst := case when tot > 0 and dcnt = tot then 'delivered'
                when scnt > 0 then 'shipped'
                when ccnt > 0 then 'confirmed' end;
  if newst is not null and public._ful_rank(newst) > public._ful_rank(o.status) then
    update orders set status = newst,
      carrier = coalesce(carrier, new.carrier),
      tracking_number = coalesce(tracking_number, new.tracking_number),
      updated_at = now()
    where id = o.id;
  end if;
  return new;
end; $$;
drop trigger if exists shop_orders_after_update on public.shop_orders;
create trigger shop_orders_after_update after update on public.shop_orders
  for each row execute procedure public.shop_orders_after_update();

-- order timeline / restock / admin override sync (replaces the v5 version)
create or replace function public.orders_after_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into order_events (order_id, event) values (new.id, 'created');
    return new;
  end if;
  if new.status is distinct from old.status then
    insert into order_events (order_id, event) values (new.id, 'status_' || new.status);
    if new.status = 'cancelled' and old.status <> 'cancelled' then
      update products p set stock = p.stock + i.q,
             status = case when p.status = 'out_of_stock' then 'active' else p.status end,
             updated_at = now()
      from (select product_id, sum(quantity) as q from order_items
            where order_id = new.id and product_id is not null group by product_id) i
      where p.id = i.product_id;
      update shop_orders set status = 'cancelled', updated_at = now()
      where order_id = new.id and status <> 'cancelled';
    elsif new.status in ('confirmed','processing','shipped','delivered') then
      update shop_orders set status = case when new.status = 'processing' then 'confirmed' else new.status end, updated_at = now()
      where order_id = new.id and status <> 'cancelled'
        and public._ful_rank(status) < public._ful_rank(new.status);
    end if;
  end if;
  if new.payment_status is distinct from old.payment_status then
    insert into order_events (order_id, event) values (new.id, 'payment_' || new.payment_status);
  end if;
  if new.tracking_number is distinct from old.tracking_number and new.tracking_number is not null then
    insert into order_events (order_id, event, note)
    values (new.id, 'tracking', trim(coalesce(new.carrier,'') || ' ' || new.tracking_number));
  end if;
  return new;
end; $$;

-- notifications: one message per shipment for multi-shop orders (replaces the v6 version)
create or replace function public.enqueue_order_notification()
returns trigger language plpgsql security definer set search_path = public as $$
declare o record; pr record; msg text; subj text; tn text; total text; shopcount int;
begin
  if new.event not in ('status_confirmed','status_processing','status_shipped','status_delivered','status_cancelled',
                       'payment_confirmed','payment_failed','tracking','shop_shipped') then
    return new;
  end if;
  select * into o from orders where id = new.order_id;
  if not found then return new; end if;
  select count(*) into shopcount from shop_orders where order_id = o.id;
  if new.event = 'shop_shipped' and shopcount <= 1 then return new; end if;
  if new.event in ('status_shipped','tracking') and shopcount > 1 then return new; end if;
  if new.event = 'status_confirmed' and o.payment_status = 'confirmed' then return new; end if;
  if new.event = 'tracking' then
    if o.status <> 'shipped' then return new; end if;
    if exists (select 1 from notifications where order_id = o.id and event = 'status_shipped'
               and created_at > now() - interval '1 minute') then return new; end if;
  end if;
  select email, notify_email, notify_whatsapp into pr from profiles where id = o.customer_id;
  total := to_char(o.total_lak, 'FM999,999,999,999,999');
  tn := case when o.tracking_number is not null
        then ' (' || trim(coalesce(o.carrier,'') || ' ເລກພັດສະດຸ ' || o.tracking_number) || ')' else '' end;
  msg := case new.event
    when 'status_confirmed'  then 'ອໍເດີ ' || o.order_number || ' ຂອງທ່ານຖືກຢືນຢັນແລ້ວ ຍອດລວມ ' || total || ' ກີບ. ຂອບໃຈທີ່ໃຊ້ LaoMarket.'
    when 'status_processing' then 'ອໍເດີ ' || o.order_number || ' ກຳລັງກະກຽມສິນຄ້າ.'
    when 'status_shipped'    then 'ອໍເດີ ' || o.order_number || ' ກຳລັງຈັດສົ່ງ' || tn || '.'
    when 'shop_shipped'      then 'ອໍເດີ ' || o.order_number || ': ຮ້ານ ' || coalesce(new.note,'') || ' ຈັດສົ່ງສິນຄ້າແລ້ວ.'
    when 'tracking'          then 'ອໍເດີ ' || o.order_number || ' ອັບເດດເລກພັດສະດຸ' || tn || '.'
    when 'status_delivered'  then 'ອໍເດີ ' || o.order_number || ' ຈັດສົ່ງສຳເລັດແລ້ວ. ຂອບໃຈທີ່ໃຊ້ LaoMarket!'
    when 'status_cancelled'  then 'ອໍເດີ ' || o.order_number || ' ຖືກຍົກເລີກ.'
    when 'payment_confirmed' then 'ໄດ້ຮັບການຊຳລະເງິນຂອງອໍເດີ ' || o.order_number || ' ແລ້ວ ແລະ ອໍເດີຖືກຢືນຢັນແລ້ວ. ຂອບໃຈທີ່ໃຊ້ LaoMarket!'
    when 'payment_failed'    then 'ການຊຳລະຂອງອໍເດີ ' || o.order_number || ' ບໍ່ຜ່ານການກວດສອບ ກະລຸນາສົ່ງບິນໃໝ່ ຫຼື ຕິດຕໍ່ຮ້ານ.'
  end;
  if msg is null then return new; end if;
  subj := 'LaoMarket — ອໍເດີ ' || o.order_number;
  if coalesce(pr.notify_email, true) and coalesce(pr.email,'') <> '' then
    insert into notifications (order_id, event, channel, recipient, subject, message)
    values (o.id, new.event, 'email', pr.email, subj, msg);
  end if;
  if coalesce(pr.notify_whatsapp, true) and coalesce(o.phone,'') <> '' then
    insert into notifications (order_id, event, channel, recipient, subject, message)
    values (o.id, new.event, 'whatsapp', o.phone, null, msg);
  end if;
  return new;
end; $$;

-- seller: orders containing my shop's items (only my items; customer contact is needed to ship)
create or replace function public.seller_orders(p_shop uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not (public.is_admin() or exists (select 1 from shops where id = p_shop and owner_id = auth.uid() and status = 'approved')) then
    raise exception 'forbidden'; end if;
  return coalesce((
    select jsonb_agg(x.r order by x.ts desc) from (
      select o.created_at as ts, jsonb_build_object(
        'order_number', o.order_number, 'created_at', o.created_at,
        'customer_name', o.customer_name, 'phone', o.phone, 'address', o.shipping_address,
        'payment_method', o.payment_method, 'payment_status', o.payment_status, 'order_status', o.status,
        'fulfillment', so.status, 'carrier', so.carrier, 'tracking_number', so.tracking_number,
        'shop_total', (select coalesce(sum(i.line_total_lak),0) from order_items i where i.order_id = o.id and i.shop_id = p_shop),
        'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'qty', i.quantity, 'total', i.line_total_lak)), '[]'::jsonb)
                  from order_items i where i.order_id = o.id and i.shop_id = p_shop)) as r
      from shop_orders so join orders o on o.id = so.order_id
      where so.shop_id = p_shop order by o.created_at desc limit 100) x), '[]'::jsonb);
end; $$;

create or replace function public.seller_update_fulfillment(
  p_order_number text, p_shop uuid, p_status text, p_carrier text default null, p_tracking text default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); o record; so record;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from shops where id = p_shop and owner_id = uid and status = 'approved') then
    raise exception 'shop_not_approved'; end if;
  select * into o from orders where order_number = p_order_number;
  if not found then raise exception 'order_not_found'; end if;
  select * into so from shop_orders where order_id = o.id and shop_id = p_shop for update;
  if not found then raise exception 'order_not_found'; end if;
  if o.status = 'cancelled' or so.status = 'cancelled' then raise exception 'order_cancelled'; end if;
  if p_status not in ('confirmed','shipped','delivered') then raise exception 'bad_status'; end if;
  if o.payment_method <> 'cash_on_delivery' and o.payment_status <> 'confirmed' then
    raise exception 'payment_not_confirmed'; end if;
  if public._ful_rank(p_status) <> public._ful_rank(so.status) + 1 then raise exception 'invalid_transition'; end if;
  update shop_orders set status = p_status,
    carrier = case when p_status = 'shipped' then nullif(left(trim(coalesce(p_carrier,'')), 80), '') else carrier end,
    tracking_number = case when p_status = 'shipped' then nullif(left(trim(coalesce(p_tracking,'')), 80), '') else tracking_number end,
    updated_at = now()
  where id = so.id;
end; $$;
revoke all on function public.seller_orders(uuid) from public, anon;
grant execute on function public.seller_orders(uuid) to authenticated;
revoke all on function public.seller_update_fulfillment(text,uuid,text,text,text) from public, anon;
grant execute on function public.seller_update_fulfillment(text,uuid,text,text,text) to authenticated;

-- ---- reviews (stars) : only customers with a delivered order from that shop ----
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  rating int not null check (rating between 1 and 5),
  comment text check (comment is null or char_length(comment) <= 1000),
  reviewer_name text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (shop_id, customer_id)
);
alter table public.reviews enable row level security;
drop policy if exists "read own or admin reviews" on public.reviews;
create policy "read own or admin reviews" on public.reviews for select
  using (customer_id = auth.uid() or public.is_admin());
drop policy if exists "admin delete reviews" on public.reviews;
create policy "admin delete reviews" on public.reviews for delete using (public.is_admin());

create or replace view public.public_reviews as
  select shop_id, rating, comment, reviewer_name, created_at from public.reviews;
create or replace view public.shop_ratings as
  select shop_id, round(avg(rating)::numeric, 1) as avg_rating, count(*)::int as review_count
  from public.reviews group by shop_id;
grant select on public.public_reviews, public.shop_ratings to anon, authenticated;

create or replace function public.submit_shop_review(p_shop uuid, p_rating int, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'bad_rating'; end if;
  if exists (select 1 from shops where id = p_shop and owner_id = uid) then raise exception 'own_shop'; end if;
  if not exists (select 1 from shop_orders so join orders o on o.id = so.order_id
                 where so.shop_id = p_shop and o.customer_id = uid and so.status = 'delivered') then
    raise exception 'no_delivered_order'; end if;
  select coalesce(nullif(split_part(trim(display_name), ' ', 1), ''), 'ລູກຄ້າ') into nm from profiles where id = uid;
  insert into reviews (shop_id, customer_id, rating, comment, reviewer_name)
  values (p_shop, uid, p_rating, nullif(left(trim(coalesce(p_comment,'')), 1000), ''), coalesce(nm, 'ລູກຄ້າ'))
  on conflict (shop_id, customer_id) do update
    set rating = excluded.rating, comment = excluded.comment, reviewer_name = excluded.reviewer_name, updated_at = now();
end; $$;
revoke all on function public.submit_shop_review(uuid,int,text) from public, anon;
grant execute on function public.submit_shop_review(uuid,int,text) to authenticated;

-- ---- sales report: revenue / cost / profit (counted when paid or delivered) ----
create or replace function public.seller_sales_report(p_shop uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare res jsonb; tz text := 'Asia/Vientiane';
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not (public.is_admin() or exists (select 1 from shops where id = p_shop and owner_id = auth.uid())) then
    raise exception 'forbidden'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'bad_range'; end if;
  with base as (
    select (o.created_at at time zone tz)::date as d, o.id as oid, i.product_name, i.quantity as q,
           i.line_total_lak as rev, (c.unit_cost_lak * i.quantity) as cost, (c.unit_cost_lak is null) as nocost,
           (o.payment_status = 'confirmed' or so.status = 'delivered') as realized
    from order_items i
    join orders o on o.id = i.order_id
    join shop_orders so on so.order_id = o.id and so.shop_id = i.shop_id
    left join order_item_costs c on c.order_item_id = i.id
    where i.shop_id = p_shop and o.status <> 'cancelled' and so.status <> 'cancelled'
      and (o.created_at at time zone tz)::date between p_from and p_to),
  sale as (select * from base where realized)
  select jsonb_build_object(
    'totals', jsonb_build_object(
      'revenue', coalesce((select sum(rev) from sale), 0),
      'cost', coalesce((select sum(cost) from sale), 0),
      'profit', coalesce((select sum(rev - coalesce(cost, 0)) from sale), 0),
      'orders', (select count(distinct oid) from sale),
      'items', coalesce((select sum(q) from sale), 0),
      'pending_amount', coalesce((select sum(rev) from base where not realized), 0),
      'pending_orders', (select count(distinct oid) from base where not realized),
      'missing_cost', (select count(*) from sale where nocost)),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'revenue', r, 'cost', c, 'profit', pf, 'orders', n) order by d)
                       from (select d, sum(rev) r, coalesce(sum(cost), 0) c, sum(rev - coalesce(cost, 0)) pf, count(distinct oid) n
                             from sale group by d) x), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object('name', n, 'qty', q, 'revenue', r, 'cost', c, 'profit', pf) order by pf desc)
                          from (select product_name n, sum(q) q, sum(rev) r, coalesce(sum(cost), 0) c, sum(rev - coalesce(cost, 0)) pf
                                from sale group by product_name order by sum(rev - coalesce(cost, 0)) desc limit 10) y), '[]'::jsonb)
  ) into res;
  return res;
end; $$;
revoke all on function public.seller_sales_report(uuid,date,date) from public, anon;
grant execute on function public.seller_sales_report(uuid,date,date) to authenticated;


-- =====================================================================
-- v8: only APPROVED shop owners can manage products (ordinary members cannot)
-- =====================================================================
create or replace function public.owns_approved_shop(target uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from shops where id = target and owner_id = auth.uid() and status = 'approved')
$$;

drop policy if exists "shop owner update products" on public.products;
create policy "shop owner update products" on public.products for update
  using (public.owns_approved_shop(shop_id) or public.is_admin())
  with check (public.owns_approved_shop(shop_id) or public.is_admin());

drop policy if exists "shop owner delete products" on public.products;
create policy "shop owner delete products" on public.products for delete
  using (public.owns_approved_shop(shop_id) or public.is_admin());
