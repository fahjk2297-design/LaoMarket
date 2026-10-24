-- =====================================================================
-- v12: SmartPOS <-> Supabase integration  (safe to re-run)
-- Run in Supabase Dashboard > SQL Editor AFTER schema.sql (v1..v11).
--
-- What this adds
--   * products.low_stock                -> per-product low-stock alert level
--   * pos_sales.vat_rate / vat_lak      -> VAT is stored with every receipt
--   * pos_shop_data                     -> per-shop POS settings, categories,
--                                          currencies and members (owner-only RLS)
--   * pos_checkout(...)  (replaced)     -> same as v11 + VAT
--   * pos_save_product(...)             -> create/update a product incl. barcode,
--                                          cost (private), low-stock level, image URL
--   * pos_adjust_stock(...)             -> atomic +/- stock change
-- Products, sales, void and stock all stay server-side; the browser only uses
-- the Publishable key.
-- =====================================================================

alter table public.products
  add column if not exists low_stock integer check (low_stock is null or low_stock >= 0);

alter table public.pos_sales
  add column if not exists vat_rate numeric(5,2) not null default 0,
  add column if not exists vat_lak  numeric(14,2) not null default 0;

-- ---------------------------------------------------------------------
-- Per-shop POS data (settings / categories / currencies / members)
-- ---------------------------------------------------------------------
create table if not exists public.pos_shop_data (
  shop_id    uuid primary key references public.shops(id) on delete cascade,
  settings   jsonb not null default '{}'::jsonb,
  categories jsonb not null default '[]'::jsonb,
  currencies jsonb not null default '[]'::jsonb,
  members    jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.pos_shop_data enable row level security;

drop policy if exists "owner or admin read pos data" on public.pos_shop_data;
create policy "owner or admin read pos data" on public.pos_shop_data for select
  using (public.owns_approved_shop(shop_id) or public.is_admin());
drop policy if exists "owner insert pos data" on public.pos_shop_data;
create policy "owner insert pos data" on public.pos_shop_data for insert
  with check (public.owns_approved_shop(shop_id));
drop policy if exists "owner update pos data" on public.pos_shop_data;
create policy "owner update pos data" on public.pos_shop_data for update
  using (public.owns_approved_shop(shop_id))
  with check (public.owns_approved_shop(shop_id));

-- ---------------------------------------------------------------------
-- pos_checkout: v11 + VAT (prices are VAT-inclusive, like the POS screen)
-- ---------------------------------------------------------------------
drop function if exists public.pos_checkout(uuid,jsonb,text,bigint,bigint);
drop function if exists public.pos_checkout(uuid,jsonb,text,bigint,bigint,numeric);

create or replace function public.pos_checkout(
  p_shop uuid, p_items jsonb, p_payment text,
  p_paid bigint default null, p_discount bigint default 0, p_vat_rate numeric default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); it record; pr record;
  sub bigint := 0; n int := 0; disc bigint := coalesce(p_discount, 0); tot bigint; paid bigint; chg bigint := 0;
  sid uuid; num text; cum bigint := 0; prev bigint := 0; cur bigint; alloc bigint; gross bigint; cst bigint;
  vr numeric := greatest(0, least(coalesce(p_vat_rate, 0), 100)); vat numeric;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from shops where id = p_shop and owner_id = uid and status = 'approved') then
    raise exception 'shop_not_approved'; end if;
  if p_payment not in ('cash','transfer','qr') then raise exception 'bad_payment'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'empty_cart'; end if;

  -- pass 1: validate + lock + subtotal (same product twice is merged)
  for it in select (v->>'id')::uuid as id, sum((v->>'qty')::int)::int as qty
            from jsonb_array_elements(p_items) v group by 1 loop
    if it.qty is null or it.qty <= 0 or it.qty > 1000 then raise exception 'bad_quantity'; end if;
    select * into pr from products where id = it.id and shop_id = p_shop for update;
    if not found then raise exception 'product_not_found'; end if;
    if pr.status = 'draft' then raise exception 'product_not_found'; end if;
    if pr.stock < it.qty then raise exception 'insufficient_stock: %', pr.name; end if;
    sub := sub + pr.price_lak * it.qty; n := n + 1;
  end loop;
  if disc < 0 or disc > sub then raise exception 'bad_discount'; end if;
  tot := sub - disc;
  if p_payment = 'cash' then
    paid := coalesce(p_paid, tot);
    if paid < tot then raise exception 'insufficient_payment'; end if;
    chg := paid - tot;
  else
    paid := tot;
  end if;
  vat := round(tot - tot / (1 + vr / 100), 2);

  num := 'POS-' || to_char(now() at time zone 'Asia/Vientiane', 'YYMMDD') || '-' ||
         upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  insert into pos_sales (sale_number, shop_id, cashier_id, subtotal_lak, discount_lak, total_lak,
                         payment_method, paid_lak, change_lak, vat_rate, vat_lak)
  values (num, p_shop, uid, sub, disc, tot, p_payment, paid, chg, vr, vat) returning id into sid;

  -- pass 2: lines, proportional discount (sums exactly to disc), stock deduction
  for it in select (v->>'id')::uuid as id, sum((v->>'qty')::int)::int as qty
            from jsonb_array_elements(p_items) v group by 1 loop
    select * into pr from products where id = it.id and shop_id = p_shop;
    select cost_lak into cst from product_costs where product_id = pr.id;
    gross := pr.price_lak * it.qty;
    cum := cum + gross;
    cur := case when sub > 0 then round(disc::numeric * cum / sub) else 0 end;
    alloc := cur - prev; prev := cur;
    insert into pos_sale_items (sale_id, product_id, product_name, barcode, quantity, unit_price_lak, unit_cost_lak, discount_lak, line_total_lak)
    values (sid, pr.id, pr.name, pr.barcode, it.qty, pr.price_lak, cst, alloc, gross);
    update products set stock = stock - it.qty,
      status = case when stock - it.qty = 0 and status = 'active' then 'out_of_stock' else status end,
      updated_at = now()
    where id = pr.id;
  end loop;

  return jsonb_build_object('sale_id', sid, 'sale_number', num, 'subtotal', sub, 'discount', disc,
                            'vat', vat, 'total', tot, 'paid', paid, 'change', chg);
end; $$;
revoke all on function public.pos_checkout(uuid,jsonb,text,bigint,bigint,numeric) from public, anon;
grant execute on function public.pos_checkout(uuid,jsonb,text,bigint,bigint,numeric) to authenticated;

-- ---------------------------------------------------------------------
-- pos_save_product: create / update (barcode, price, private cost, stock,
-- low-stock level, image URL, on-sale switch)
--   p_image: null = keep, '' = remove, otherwise an https:// URL
--   p_active=false -> status 'hidden'; stock 0 -> 'out_of_stock'
-- A duplicate barcode inside the same shop raises unique_violation (23505).
-- ---------------------------------------------------------------------
create or replace function public.pos_save_product(
  p_id uuid, p_shop uuid, p_name text, p_barcode text, p_category text,
  p_price bigint, p_cost bigint, p_stock int, p_low_stock int, p_image text, p_active boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); pid uuid; st text;
  bc text := nullif(trim(coalesce(p_barcode, '')), '');
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from shops where id = p_shop and owner_id = uid and status = 'approved') then
    raise exception 'shop_not_approved'; end if;
  if coalesce(trim(p_name), '') = '' or length(p_name) > 200 then raise exception 'bad_name'; end if;
  if p_price is null or p_price < 0 or coalesce(p_cost, 0) < 0 or p_stock is null or p_stock < 0
     or (p_low_stock is not null and p_low_stock < 0) then
    raise exception 'bad_numbers'; end if;
  if p_image is not null and p_image <> '' and (p_image !~* '^https://' or length(p_image) > 500) then
    raise exception 'bad_image'; end if;

  st := case when not coalesce(p_active, true) then 'hidden'
             when p_stock = 0 then 'out_of_stock'
             else 'active' end;

  if p_id is null then
    insert into products (shop_id, name, barcode, category, price_lak, stock, low_stock, status, image_url)
    values (p_shop, trim(p_name), bc, coalesce(nullif(trim(p_category), ''), 'Other'),
            p_price, p_stock, p_low_stock, st, nullif(p_image, ''))
    returning id into pid;
  else
    update products set
      name = trim(p_name), barcode = bc,
      category = coalesce(nullif(trim(p_category), ''), 'Other'),
      price_lak = p_price, stock = p_stock, low_stock = p_low_stock, status = st,
      image_url = case when p_image is null then image_url else nullif(p_image, '') end,
      updated_at = now()
    where id = p_id and shop_id = p_shop
    returning id into pid;
    if pid is null then raise exception 'product_not_found'; end if;
  end if;

  insert into product_costs (product_id, shop_id, cost_lak)
  values (pid, p_shop, coalesce(p_cost, 0))
  on conflict (product_id) do update set cost_lak = excluded.cost_lak, updated_at = now();
  return pid;
end; $$;
revoke all on function public.pos_save_product(uuid,uuid,text,text,text,bigint,bigint,int,int,text,boolean) from public, anon;
grant execute on function public.pos_save_product(uuid,uuid,text,text,text,bigint,bigint,int,int,text,boolean) to authenticated;

-- ---------------------------------------------------------------------
-- pos_adjust_stock: atomic +/- change, returns the new stock
-- ---------------------------------------------------------------------
create or replace function public.pos_adjust_stock(p_product uuid, p_delta int)
returns int language plpgsql security definer set search_path = public as $$
declare pr record; ns int;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_delta is null or p_delta = 0 or abs(p_delta) > 100000 then raise exception 'bad_numbers'; end if;
  select * into pr from products where id = p_product for update;
  if not found then raise exception 'product_not_found'; end if;
  if not exists (select 1 from shops where id = pr.shop_id and owner_id = auth.uid() and status = 'approved') then
    raise exception 'shop_not_approved'; end if;
  ns := pr.stock + p_delta;
  if ns < 0 then raise exception 'insufficient_stock: %', pr.name; end if;
  update products set stock = ns,
    status = case when status = 'out_of_stock' and ns > 0 then 'active'
                  when status = 'active' and ns = 0 then 'out_of_stock'
                  else status end,
    updated_at = now()
  where id = pr.id;
  return ns;
end; $$;
revoke all on function public.pos_adjust_stock(uuid,int) from public, anon;
grant execute on function public.pos_adjust_stock(uuid,int) to authenticated;
