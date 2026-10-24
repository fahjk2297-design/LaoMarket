-- =====================================================================
-- v12: SmartPOS Pro cloud data (run AFTER the existing schema.sql; safe to re-run)
--   Products, costs, stock and POS sales already live in the LaoMarket tables
--   (products, product_costs, pos_sales, pos_sale_items). This adds one small
--   per-shop key/value table for the rest of SmartPOS Pro's data:
--     settings, currencies, members (wallets), categories, product_meta,
--     admin_security (hash of the POS admin-page password)
-- =====================================================================
create table if not exists public.shop_pos_data (
  shop_id uuid not null references public.shops(id) on delete cascade,
  key text not null check (key in ('settings','currencies','members','categories','product_meta','admin_security')),
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (shop_id, key),
  check (pg_column_size(value) < 500000)
);

alter table public.shop_pos_data enable row level security;

-- the approved shop owner can read / create / change their own shop's POS data
drop policy if exists "owner read pos data" on public.shop_pos_data;
create policy "owner read pos data" on public.shop_pos_data for select
  using (public.owns_approved_shop(shop_id) or public.is_admin());

drop policy if exists "owner insert pos data" on public.shop_pos_data;
create policy "owner insert pos data" on public.shop_pos_data for insert
  with check (public.owns_approved_shop(shop_id));

drop policy if exists "owner update pos data" on public.shop_pos_data;
create policy "owner update pos data" on public.shop_pos_data for update
  using (public.owns_approved_shop(shop_id)) with check (public.owns_approved_shop(shop_id));

-- LaoMarket main admin can manage everything (needed to reset a forgotten POS admin password)
drop policy if exists "admin manage pos data" on public.shop_pos_data;
create policy "admin manage pos data" on public.shop_pos_data for all
  using (public.is_admin()) with check (public.is_admin());

-- For a future admin.html button: reset a shop's POS admin password
create or replace function public.admin_reset_pos_admin_password(p_shop uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  delete from shop_pos_data where shop_id = p_shop and key = 'admin_security';
end; $$;
revoke all on function public.admin_reset_pos_admin_password(uuid) from public, anon;
grant execute on function public.admin_reset_pos_admin_password(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- HOW THE LAOMARKET MAIN ADMIN RESETS A FORGOTTEN POS ADMIN PASSWORD
-- (the shop gives you the "ລະຫັດຮ້ານ / shop id" shown on the forgot-password screen):
--
--   delete from public.shop_pos_data
--   where shop_id = 'PUT-SHOP-ID-HERE' and key = 'admin_security';
--
-- The shop owner then presses "ກວດສອບການຣີເຊັດ" and sets a new password.
-- ---------------------------------------------------------------------
