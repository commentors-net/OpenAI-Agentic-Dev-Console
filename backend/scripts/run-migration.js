'use strict';

const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

async function migrate() {
  const pool = mysql.createPool({
    host: process.env.DB_HOST,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME,
    waitForConnections: true,
    connectionLimit: 1
  });

  try {
    const sqlPath = path.join(__dirname, '..', 'sql', '012_dev_agent_audit.sql');
    const sql = fs.readFileSync(sqlPath, 'utf8');
    
    console.log('Running migration: 012_dev_agent_audit.sql');
    await pool.query(sql);
    console.log('Migration successful.');

    const [tables] = await pool.query('SHOW TABLES LIKE "dd_dev_agent_audit"');
    if (tables.length > 0) {
      console.log('Table dd_dev_agent_audit verified.');
    } else {
      console.error('Table verification failed!');
    }
  } catch (err) {
    console.error('Migration failed:', err.message);
    process.exit(1);
  } finally {
    await pool.end();
  }
}

migrate();
