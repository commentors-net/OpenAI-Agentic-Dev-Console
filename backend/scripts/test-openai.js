'use strict';

const https = require('https');
const fs = require('fs');
const path = require('path');

const envPath = path.join(__dirname, '..', '.env');

function loadEnv(filePath) {
  const text = fs.readFileSync(filePath, 'utf8');
  for (const line of text.split(/\r?\n/)) {
    if (!line || line.trim().startsWith('#') || !line.includes('=')) continue;
    const idx = line.indexOf('=');
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    if (key && !(key in process.env)) process.env[key] = value;
  }
}

function extractText(responseJson) {
  if (typeof responseJson.output_text === 'string') return responseJson.output_text;
  const chunks = [];
  for (const item of responseJson.output || []) {
    for (const content of item.content || []) {
      if (content.type === 'output_text' && content.text) chunks.push(content.text);
    }
  }
  return chunks.join('\n').trim();
}

loadEnv(envPath);

const apiKey = process.env.OPENAI_API_KEY;
const model = process.env.OPENAI_MODEL || 'gpt-5.5';

if (!apiKey || !apiKey.startsWith('sk-')) {
  console.error('FAIL: OPENAI_API_KEY missing or invalid in .env');
  process.exit(1);
}

const payload = JSON.stringify({
  model,
  input: 'Reply with exactly: Accepted Offer to Close API test passed.',
  store: false
});

const req = https.request({
  hostname: 'api.openai.com',
  path: '/v1/responses',
  method: 'POST',
  timeout: 30000,
  headers: {
    'Authorization': `Bearer ${apiKey}`,
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload)
  }
}, (res) => {
  let body = '';
  res.on('data', chunk => body += chunk);
  res.on('end', () => {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (err) {
      console.error('FAIL: OpenAI returned non-JSON response');
      console.error(body.slice(0, 500));
      process.exit(1);
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      console.error('FAIL: OpenAI API request failed');
      console.error('HTTP status:', res.statusCode);
      console.error('Error:', parsed.error ? parsed.error.message : body.slice(0, 500));
      process.exit(1);
    }

    console.log('PASS: OpenAI API key works.');
    console.log('Model:', model);
    console.log('Response ID:', parsed.id || '(none)');
    console.log('Output:', extractText(parsed) || '(no text output found)');
  });
});

req.on('timeout', () => {
  req.destroy(new Error('Request timed out'));
});

req.on('error', (err) => {
  console.error('FAIL: Request error:', err.message);
  process.exit(1);
});

req.write(payload);
req.end();
