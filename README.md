# LaoMarket — Production Web + Supabase

## ຕິດຕັ້ງ (5 ຂັ້ນຕອນ)
1. ສ້າງໂປຣເຈັກ Supabase → SQL Editor → ຣັນ `schema.sql` ທັງໄຟລ໌ (ຣັນຊ້ຳໄດ້).
2. ແກ້ `config.js`: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` (sb_publishable_…), `WHATSAPP_BUSINESS_NUMBER`.
3. ສະໝັກສະມາຊິກໃນ `index.html` ແລ້ວເຮັດໃຫ້ເປັນ admin ໃນ SQL Editor:
   `update public.profiles set role='admin' where email='YOUR_EMAIL';`
4. Deploy ທຸກໄຟລ໌ (index.html, admin.html, config.js) ຂຶ້ນ Netlify / Vercel / Cloudflare Pages / GitHub Pages.
5. Supabase → Authentication → URL Configuration: ໃສ່ URL ເວັບຂອງທ່ານ. ເປີດ/ປິດ Email confirmation ຕາມຕ້ອງການ.

## ວິທີເຮັດວຽກ
- ລູກຄ້າ: ສະໝັກ/ເຂົ້າລະບົບ → ສັ່ງຊື້ ຜ່ານ `place_order()` (ລາຄາ ແລະ ສະຕັອກຄິດຝັ່ງ server).
- Admin (`admin.html`): ເຂົ້າດ້ວຍອີເມວ+ລະຫັດ Supabase. ອະນຸມັດຮ້ານ, ເພີ່ມ/ແກ້ສິນຄ້າ, ປ່ຽນສະຖານະອໍເດີ, ຢືນຢັນການຊຳລະ, ໂປຣໂມຊັນ, ຕັ້ງຄ່າ ທັງໝົດບັນທຶກລົງ Supabase.
- ສິນຄ້າສະແດງໜ້າຮ້ານສະເພາະຮ້ານທີ່ອະນຸມັດແລ້ວ ແລະ status = active.

## ຄວາມປອດໄພ
- ໃຊ້ Publishable key ໃນ browser ເທົ່ານັ້ນ. ຫ້າມໃສ່ `sb_secret_` / `service_role`.
- RLS ເປີດທຸກຕາຕະລາງ; ຜູ້ຂາຍອະນຸມັດຮ້ານຕົນເອງບໍ່ໄດ້ (trigger).
- ການຢືນຢັນຈ່າຍເງິນຈິງ (bank/QR) ຕ້ອງເຮັດໂດຍ admin ຫຼື webhook ຝັ່ງ server; ຍັງບໍ່ມີ payment gateway ອັດຕະໂນມັດ.

## ໄຟລ໌
index.html (ໜ້າຮ້ານ) · admin.html (ແຜງ admin) · config.js · schema.sql
