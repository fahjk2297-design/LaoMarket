-- LaoMarket: ເຊື່ອມລະບົບການເງິນ (ແອັດມິນຄວບຄຸມ). ຣັນຊ້ຳໄດ້.
-- ໝາຍເຫດ: ສົມມຸດວ່າ profiles.role = 'admin' ສຳລັບແອັດມິນ (ຕາມ admin.html ເດີມ)
create table if not exists public.shop_payout_settings(
  shop_id uuid primary key references public.shops(id) on delete cascade,
  bank text not null default ''
);
alter table public.shop_payout_settings enable row level security;
drop policy if exists "owner bank" on public.shop_payout_settings;
create policy "owner bank" on public.shop_payout_settings for all
  using (exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid()))
  with check (exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid()));
drop policy if exists "admin read bank" on public.shop_payout_settings;
create policy "admin read bank" on public.shop_payout_settings for select
  using (exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'));

-- ຄຳຂໍຖອນເງິນ (ຕາຕະລາງ payout_requests ທີ່ admin ໃຊ້ຢູ່ແລ້ວ)
drop policy if exists "owner request payout" on public.payout_requests;
create policy "owner request payout" on public.payout_requests for insert
  with check (status='pending' and exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid()));
drop policy if exists "owner view payouts" on public.payout_requests;
create policy "owner view payouts" on public.payout_requests for select
  using (exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid()));
drop policy if exists "admin manage payouts" on public.payout_requests;
create policy "admin manage payouts" on public.payout_requests for all
  using (exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'))
  with check (exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'));

-- ແອັດມິນຈ່າຍຄ່າຄອມ Affiliate
drop policy if exists "admin manage commissions" on public.affiliate_commissions;
create policy "admin manage commissions" on public.affiliate_commissions for all
  using (exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'))
  with check (exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'));

-- ຄ່າເລີ່ມຕົ້ນ (ແກ້ໄດ້ໃນ admin)
insert into public.platform_settings(key,value) values
 ('payout_schedule','weekly'),('payout_weekday','1'),('payout_min_lak','100000')
on conflict (key) do nothing;
