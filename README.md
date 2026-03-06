# 🗑️ WasteVision — AI Waste Scanner

> A Flutter mobile app that helps users sort waste correctly using **Barcode scanning** and **AI-powered object detection** via Google Cloud Vision API.

---

## 📱 Features

### 🔖 Barcode Mode
- Scan product barcodes and fetch packaging data from **OpenFoodFacts API**
- Automatically classifies waste type (Recycle / General / Hazardous)
- **Fallback Logic** — if API has no packaging data, the app analyzes by:
  - **GS1 Barcode Range** (country/manufacturer prefix)
  - **Product name keywords** (e.g. coca cola → plastic bottle → recycle bin)
- Built-in **Cache** — avoids duplicate API calls for the same barcode
- **Rate Limiting** — 2-second cooldown between requests
- **Auto Retry** — retries up to 2 times with exponential backoff on network failure

### 🤖 AI Object Mode
- Capture or pick an image from gallery
- Sends image to **Google Cloud Vision API** (Object Localization + Label Detection + Logo Detection)
- Classifies waste from detected objects and brand logos
- Returns **up to 5 results** ranked by confidence score
- Detects hands in frame and warns user before processing

---

## 🔐 Security

- API Key stored in `.env` file — **never hardcoded**
- Supports **Supabase Edge Function Proxy** to prevent API Key exposure from the client
- `.env` is listed in `.gitignore` — safe to push

```
GOOGLE_VISION_API_KEY=your_key_here
VISION_PROXY_URL=your_supabase_edge_function_url   # optional
VISION_PROXY_KEY=your_proxy_key                     # optional
SUPABASE_ACCESS_TOKEN=your_token                    # optional
```

---

## 🧠 Waste Classification Logic

| Material | Bin |
|---|---|
| Plastic, PET, Glass, Aluminium, Paper/Carton | 🟡 Yellow (Recycle) |
| Food scraps, Organic | 🟢 Green (Wet waste) |
| Foil packaging, Mixed material | 🔵 Blue (General) |
| Batteries, Electronics | 🔴 Red (Hazardous) |

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

## 🚀 Getting Started

**1. Clone the repo**
```bash
git clone https://github.com/JAMEJCG/WasteVision-AI-Waste-Scanner.git
cd WasteVision-AI-Waste-Scanner
```

**2. Install dependencies**
```bash
flutter pub get
```

**3. Create `.env` file**
```
GOOGLE_VISION_API_KEY=your_key_here
```

**4. Run the app**
```bash
flutter run
```

---

## 📁 Project Structure

```
lib/
└── main.dart         # Main app — UI, Barcode Logic, AI Logic, Classification
```

---

## ⚠️ Notes

- OpenFoodFacts API has limited Thai product data — Fallback Logic handles missing packaging info
- Cloud Vision API requires billing to be enabled on Google Cloud Console
- Tested on Android

---

*Built by [Peerawit Aiamoakson (James)](https://github.com/JAMEJCG) — Digital Technology, Phuket Rajabhat University*
