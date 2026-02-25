# ♻️ WasteVision - AI Waste Classifier App

**WasteVision** คือแอปพลิเคชันบนสมาร์ตโฟนที่ช่วยให้การคัดแยกขยะเป็นเรื่องง่ายและถูกต้องตามหลักสากล โดยผสานการทำงานของระบบสแกนบาร์โค้ด (Barcode Scanner) และเทคโนโลยีปัญญาประดิษฐ์ (AI Object Detection) เพื่อวิเคราะห์ขยะและแนะนำประเภทถังขยะที่ถูกต้อง (เหลือง, น้ำเงิน, เขียว, แดง)

---

## ✨ Features (คุณสมบัติเด่น)

- 📷 **AI Object & Logo Detection:** ถ่ายภาพขยะเพื่อให้ AI วิเคราะห์รูปร่าง (Label), ข้อความ (Text), และยี่ห้อสินค้า (Logo) ผ่าน Google Cloud Vision API
- 🏷️ **Smart Barcode Scanner:** สแกนบาร์โค้ดเพื่อดึงข้อมูลชื่อสินค้าและวัสดุบรรจุภัณฑ์แบบ Real-time จากฐานข้อมูลระดับโลก OpenFoodFacts API
- 🧠 **Intelligent Fallback Logic:** หากฐานข้อมูล API ไม่มีข้อมูลบรรจุภัณฑ์ ระบบสามารถคาดเดาวัสดุและวิธีทิ้งจาก "ชื่อและยี่ห้อสินค้า" ได้อัตโนมัติ
- 🔀 **Smart Gallery Picker:** รองรับการดึงรูปภาพจากแกลลอรี่ โดยระบบจะแยกแยะและสลับโหมดการประมวลผล (Barcode / AI) ให้อัตโนมัติ
- 📊 **Alternative Predictions:** แสดงผลลัพธ์หลักที่แม่นยำที่สุด พร้อมตัวเลือกความเป็นไปได้อื่นๆ (Alternative Results) เพื่อให้ผู้ใช้ตัดสินใจได้ดีขึ้น

---

## 🛠️ Tech Stack (เทคโนโลยีที่ใช้)

- **Framework:** [Flutter](https://flutter.dev/) (Dart)
- **AI & Cloud:** Google Cloud Vision API
- **Database/API:** OpenFoodFacts API
- **Key Packages:** `mobile

## 📄License
โปรเจกต์นี้เป็นส่วนหนึ่งของการศึกษาและพัฒนาซอฟต์แวร์ระดับมหาวิทยาลัย (Educational Purpose)
