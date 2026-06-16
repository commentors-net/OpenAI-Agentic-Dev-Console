'use strict';

const http = require('http');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

async function testApi() {
    console.log('--- Testing Dev Agent API Route ---');

    const payload = JSON.stringify({
        prompt: 'What is the current status of the deal with public_id 0ac33db6-93cb-4571-93c0-4514f94893b1?',
        history: []
    });

    const options = {
        hostname: '127.0.0.1',
        port: process.env.DEALDESK_PORT || 3017,
        path: '/api/dev-agent/chat',
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(payload),
            'x-dev-agent-token': process.env.DEALDESK_DEV_AGENT_TOKEN
        }
    };

    console.log('Sending request to', options.hostname + ':' + options.port + options.path);
    console.log('Using Token:', process.env.DEALDESK_DEV_AGENT_TOKEN.slice(0, 8) + '...');

    const req = http.request(options, (res) => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
            console.log('\nResponse Status:', res.statusCode);
            try {
                const parsed = JSON.parse(body);
                console.log('Response Body:', JSON.stringify(parsed, null, 2));
                if (res.statusCode === 200) {
                    console.log('\nPASS: API route is reachable and authenticated.');
                } else {
                    console.log('\nFAIL: API returned error status.');
                }
            } catch (err) {
                console.log('\nResponse is not JSON:', body);
            }
        });
    });

    req.on('error', (err) => {
        console.log('\nERROR: Could not connect to server. Is it running?');
        console.log('Details:', err.message);
        console.log('\nTo test this, run "node server.js" in one terminal and this script in another.');
    });

    req.write(payload);
    req.end();
}

testApi();
