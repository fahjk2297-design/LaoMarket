
-- LaoMarket Supabase schema (PostgreSQL)
-- Run in Supabase Dashboard > SQL Editor > New query.
-- Start with a fresh project. Review policies before production launch.

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
