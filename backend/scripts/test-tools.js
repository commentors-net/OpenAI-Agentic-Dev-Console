'use strict';

const path = require('path');
const mysql = require('mysql2/promise');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
const tools = require('../dev-agent-tools');

async function test() {
    console.log('--- Testing Dev Agent Tools ---');

    const pool = mysql.createPool({
        host: process.env.DB_HOST,
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD,
        database: process.env.DB_NAME,
        waitForConnections: true,
        connectionLimit: 1
    });

    try {
        // 1. Test Redaction
        console.log('\n[1] Testing Redaction...');
        const raw = 'My key is OPENAI_API_KEY="sk-123" and DB_PASSWORD=my_pass';
        console.log('Original:', raw);
        console.log('Redacted:', tools.redact(raw));

        // 2. Test read_file
        console.log('\n[2] Testing read_file (server.js, first 5 lines)...');
        const fileContent = await tools.read_file({ file_key: 'server.js', start_line: 1, end_line: 5 });
        console.log(fileContent);

        // 3. Test grep_file
        console.log('\n[3] Testing grep_file (server.js for "pool")...');
        const grepResult = await tools.grep_file({ file_key: 'server.js', pattern: 'pool' });
        console.log(grepResult.split('\n').slice(0, 5).join('\n') + '\n...');

        // 4. Test mysql_schema
        console.log('\n[4] Testing mysql_schema (dd_deals)...');
        const schema = await tools.mysql_schema({ table_name: 'dd_deals' }, pool);
        console.log(JSON.parse(schema).slice(0, 3));

        // 5. Test mysql_select
        console.log('\n[5] Testing mysql_select...');
        const select = await tools.mysql_select({ query: 'SELECT public_id, property_address FROM dd_deals LIMIT 2' }, pool);
        console.log(select);

        // 6. Test Snapshots
        console.log('\n[6] Testing get_dashboard_snapshot...');
        const dashboard = await tools.get_dashboard_snapshot({}, pool);
        console.log(dashboard);

        console.log('\n[7] Testing node_check...');
        const check = await tools.node_check();
        console.log('Result:', check);

    } catch (err) {
        console.error('\nTest failed:', err.message);
    } finally {
        await pool.end();
        console.log('\n--- Tests Complete ---');
    }
}

test();
