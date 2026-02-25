Vision Proxy
============

Small Node.js proxy to keep your Google Vision API key on the server instead of embedding it in mobile clients.

Quick start
-----------

1. Copy `.env.example` to `.env` and set `GOOGLE_VISION_API_KEY`.

2. Install dependencies and start:

```bash
cd server
npm install
npm start
```

3. Configure your mobile app `.env` (in Flutter project root) to point to the proxy, for example:

```
VISION_PROXY_URL=http://10.0.2.2:8080/vision
```

- `10.0.2.2` maps to host machine from Android emulator. Use your LAN IP when testing on a physical device.

Request format
--------------

POST /vision
Content-Type: application/json

Body:

```json
{ "image": "<base64-image-content>" }
```

Response
--------

The proxy forwards the Google Vision response JSON back to the client.

Security
--------

- This proxy keeps your API key on the server; do not expose `.env` or commit it.
- For production, add authentication (API key, JWT), rate-limiting, HTTPS, and logging.
