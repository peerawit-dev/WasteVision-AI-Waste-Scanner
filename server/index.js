require('dotenv').config();
const express = require('express');
const cors = require('cors');
const axios = require('axios');
const bodyParser = require('body-parser');

const app = express();
const PORT = process.env.PORT || 8080;
const GOOGLE_KEY = process.env.GOOGLE_VISION_API_KEY;

if (!GOOGLE_KEY) {
  console.warn('WARNING: GOOGLE_VISION_API_KEY is not set in .env');
}

app.use(cors());
app.use(bodyParser.json({ limit: '10mb' }));

// Simple health check
app.get('/', (req, res) => res.json({ ok: true }));

// POST /vision
// Accepts: { image: '<base64 string>' }
// Forwards to Google Vision API using server-side key
app.post('/vision', async (req, res) => {
  try {
    const image = req.body?.image;
    if (!image) return res.status(400).json({ error: 'Missing image in request body' });

    const visionReq = {
      requests: [
        {
          image: { content: image },
          features: [
            { type: 'TEXT_DETECTION' },
            { type: 'LABEL_DETECTION' },
            { type: 'LOGO_DETECTION' }
          ]
        }
      ]
    };

    const url = `https://vision.googleapis.com/v1/images:annotate?key=${GOOGLE_KEY}`;
    const r = await axios.post(url, visionReq, { timeout: 15000 });
    return res.status(r.status).json(r.data);
  } catch (err) {
    console.error('Proxy error', err?.toString?.() || err);
    if (err.response) {
      return res.status(err.response.status).json(err.response.data);
    }
    return res.status(500).json({ error: 'Internal Server Error' });
  }
});

app.listen(PORT, () => console.log(`Vision proxy listening on ${PORT}`));
