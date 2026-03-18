# 🗑️ WasteVision — AI Waste Scanner

> **EN:** A Flutter mobile app that helps users sort waste correctly using **Barcode scanning** and **AI-powered object detection** via Google Cloud Vision API.
>
> **TH:** แอปพลิเคชัน Flutter ที่ช่วยให้ผู้ใช้คัดแยกขยะได้อย่างถูกต้อง ด้วยการ **สแกนบาร์โค้ด** และ **การตรวจจับวัตถุด้วย AI** ผ่าน Google Cloud Vision API

---

## 📱 Features / ฟีเจอร์

### 🔖 Barcode Mode
- EN: Scan product barcodes and fetch packaging data from **OpenFoodFacts API**
- TH: สแกนบาร์โค้ดสินค้าและดึงข้อมูลบรรจุภัณฑ์จาก **OpenFoodFacts API**

- EN: Automatically classifies waste type (Recycle / General / Hazardous)
- TH: จำแนกประเภทขยะโดยอัตโนมัติ (รีไซเคิล / ทั่วไป / อันตราย)

- **Fallback Logic** — EN: If the API has no packaging data, the app analyzes by:
  - **GS1 Barcode Range** (country/manufacturer prefix)
  - **Product name keywords** (e.g. coca cola → plastic bottle → recycle bin)
- TH: หาก API ไม่มีข้อมูลบรรจุภัณฑ์ แอปจะวิเคราะห์จาก:
  - **GS1 Barcode Range** (รหัสประเทศ/ผู้ผลิต)
  - **คำสำคัญในชื่อสินค้า** (เช่น coca cola → ขวดพลาสติก → ถังรีไซเคิล)

- **Cache** — EN: Avoids duplicate API calls for the same barcode / TH: ป้องกันการเรียก API ซ้ำสำหรับบาร์โค้ดเดิม
- **Rate Limiting** — EN: 2-second cooldown between requests / TH: หน่วงเวลา 2 วินาทีระหว่างคำขอ
- **Auto Retry** — EN: Retries up to 2 times with exponential backoff on network failure / TH: ลองใหม่อัตโนมัติสูงสุด 2 ครั้งเมื่อเครือข่ายขัดข้อง

### 🤖 AI Object Mode
- EN: Capture or pick an image from gallery
- TH: ถ่ายภาพหรือเลือกจากแกลเลอรี

- EN: Sends image to **Google Cloud Vision API** (Object Localization + Label Detection + Logo Detection)
- TH: ส่งภาพไปยัง **Google Cloud Vision API** (ระบุตำแหน่งวัตถุ + ตรวจจับ Label + ตรวจจับโลโก้)

- EN: Classifies waste from detected objects and brand logos
- TH: จำแนกประเภทขยะจากวัตถุและโลโก้ที่ตรวจพบ

- EN: Returns **up to 5 results** ranked by confidence score
- TH: แสดงผลลัพธ์สูงสุด **5 รายการ** เรียงตามคะแนนความมั่นใจ

- EN: Detects hands in frame and warns user before processing
- TH: ตรวจจับมือในภาพและแจ้งเตือนผู้ใช้ก่อนประมวลผล

---

## 🔐 Security / ความปลอดภัย

- EN: API Key stored in `.env` file — **never hardcoded**
- TH: เก็บ API Key ไว้ในไฟล์ `.env` — **ไม่ hardcode ในโค้ด**

- EN: Supports **Supabase Edge Function Proxy** to prevent API Key exposure from the client
- TH: รองรับ **Supabase Edge Function Proxy** เพื่อป้องกัน API Key รั่วไหลจาก client

- EN: `.env` is listed in `.gitignore` — safe to push
- TH: `.env` อยู่ใน `.gitignore` — push ได้อย่างปลอดภัย

```
GOOGLE_VISION_API_KEY=your_key_here
VISION_PROXY_URL=your_supabase_edge_function_url   # optional
VISION_PROXY_KEY=your_proxy_key                     # optional
SUPABASE_ACCESS_TOKEN=your_token                    # optional
```

---

## 🧠 Waste Classification Logic / ตรรกะการจำแนกขยะ

| Material / วัสดุ | Bin / ถัง |
|---|---|
| Plastic, PET, Glass, Aluminium, Paper/Carton | 🟡 Yellow — Recycle / รีไซเคิล |
| Food scraps, Organic | 🟢 Green — Wet waste / ขยะเปียก |
| Foil packaging, Mixed material | 🔵 Blue — General / ทั่วไป |
| Batteries, Electronics | 🔴 Red — Hazardous / อันตราย |

---

## 🛠️ Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter (Dart) |
| Barcode Scanning | mobile_scanner |
| AI / Vision | Google Cloud Vision API |
| Product Data | OpenFoodFacts API |
| Backend / Proxy | Supabase Edge Function |
| Config | flutter_dotenv |
| HTTP | http package |

---

## 🚀 Getting Started / วิธีติดตั้ง

**1. Clone the repo**
```bash
git clone https://github.com/JAMEJCG/WasteVision-AI-Waste-Scanner.git
cd WasteVision-AI-Waste-Scanner
```

**2. Install dependencies / ติดตั้ง dependencies**
```bash
flutter pub get
```

**3. Create `.env` file / สร้างไฟล์ `.env`**
```
GOOGLE_VISION_API_KEY=your_key_here
```

**4. Run the app / รันแอป**
```bash
flutter run
```

---

## 📁 Project Structure / โครงสร้างโปรเจค

```
lib/
└── main.dart         # Main app — UI, Barcode Logic, AI Logic, Classification
```

---

## ⚠️ Notes / หมายเหตุ

- EN: OpenFoodFacts API has limited Thai product data — Fallback Logic handles missing packaging info
- TH: OpenFoodFacts API มีข้อมูลสินค้าไทยจำกัด — Fallback Logic จัดการกรณีที่ไม่มีข้อมูลบรรจุภัณฑ์

- EN: Cloud Vision API requires billing to be enabled on Google Cloud Console
- TH: Cloud Vision API ต้องเปิดใช้งานการเรียกเก็บเงินใน Google Cloud Console

- EN: Tested on Android
- TH: ทดสอบบน Android

---

*Built by [Peerawit Aiamoakson (James)](https://github.com/JAMEJCG) and Suchanan Khanphrasaeng(Sam) — Digital Technology, Phuket Rajabhat University*
*พัฒนาโดย [พีรวิชญ์ เอี่ยมอักษร (เจมส์)](https://github.com/JAMEJCG) และ สุชานันท์ ขันพระแสง(แซม) — สาขาเทคโนโลยีดิจิทัล มหาวิทยาลัยราชภัฏภูเก็ต*
