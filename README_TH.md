# วิธีตั้งค่าฐานข้อมูล LaoMarket ด้วย Supabase

1. เข้า https://supabase.com แล้วสมัคร/เข้าสู่ระบบ และสร้าง Project ใหม่
2. ไปที่เมนู **SQL Editor** → **New query**
3. เปิดไฟล์ `schema.sql` คัดลอก SQL ทั้งหมดไปวาง แล้วกด **Run**
4. ไปที่ **Project Settings → API** แล้วคัดลอก **Project URL** และ **Publishable key** (หรือ anon key รุ่นเก่า)
5. สร้างบัญชีของคุณเองใน **Authentication → Users** หรือผ่านหน้า Signup
6. กลับไป SQL Editor แล้วรันคำสั่ง UPDATE ท้ายไฟล์ `schema.sql` โดยแทน `YOUR_ADMIN_EMAIL_HERE` ด้วยอีเมลแอดมินของคุณ
7. ส่งให้ฉันเฉพาะ **Project URL** และ **Publishable/anon key** เพื่อเตรียมเชื่อม HTML ทั้งสองไฟล์

**ห้ามส่งรหัสผ่านบัญชี Supabase และห้ามนำ service_role/secret key ไปใส่ใน HTML เด็ดขาด**

ข้อสำคัญ: ไฟล์ HTML ปัจจุบันยังบันทึกข้อมูลใน browser (localStorage) อยู่ SQL นี้สร้างฐานข้อมูลและนโยบายความปลอดภัยให้แล้ว แต่ยังต้องปรับโค้ดหน้าเว็บให้ใช้ Supabase Auth และตารางเหล่านี้ก่อนที่ข้อมูลจะซิงก์ร่วมกันจริง การยืนยันการชำระเงินจริงต้องทำผ่านผู้ให้บริการและ webhook ฝั่งเซิร์ฟเวอร์ ไม่ใช่ปุ่มในหน้า HTML.


## ຟີເຈີໃໝ່: Chat, WhatsApp ແລະ Promotions
- `promotions`: ເກັບໂປຣໂມຊັນ, ໂຄດ, ເວລາເລີ່ມ/ສິ້ນສຸດ ແລະສະຖານະ.
- `support_faqs`: ເກັບຄຳຖາມ/ຄຳຕອບພາສາລາວ, ໄທ ແລະອັງກິດ ເພື່ອໃຫ້ chatbot ຕອບຈາກຂໍ້ມູນທີ່ກວດແລ້ວ.
- ໃນ HTML ສະບັບເດໂມ, chatbot ໃຊ້ກົດຕອບ FAQ ແລະຍັງບໍ່ແມ່ນ AI ເຕັມຮູບແບບ. ການເຊື່ອມ AI ຈິງຕ້ອງໃຊ້ backend/Edge Function ເພື່ອບໍ່ເປີດເຜີຍ API key.
- ຢ່າລືມວ່າຈະຕ້ອງລັນ schema.sql ສະບັບອັບເດດໃນ Supabase SQL Editor.
