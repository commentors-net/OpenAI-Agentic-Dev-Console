'use strict';

const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const mysql = require('mysql2/promise');

async function main() {
  const required = ['DB_HOST', 'DB_USER', 'DB_PASSWORD', 'DB_NAME'];
  for (const key of required) {
    if (!process.env[key]) {
      throw new Error(`${key} is missing from .env`);
    }
  }

  const connection = await mysql.createConnection({
    host: process.env.DB_HOST,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME
  });

  const [dbRows] = await connection.query('SELECT DATABASE() AS db_name');
  const [tableRows] = await connection.query(
    "SELECT table_name FROM information_schema.tables WHERE table_schema = ? AND table_name LIKE 'dd_%' ORDER BY table_name",
    [process.env.DB_NAME]
  );

  await connection.end();

  console.log('PASS: MySQL connection works.');
  console.log('Database:', dbRows[0].db_name);
  console.log('DealDesk tables found:', tableRows.length);

  for (const row of tableRows) {
    console.log('-', row.table_name);
  }

  if (tableRows.length < 8) {
    console.log('WARNING: Expected 8 DealDesk tables. Schema may not have been applied yet.');
  }
}

main().catch((err) => {
  console.error('FAIL:', err.message);
  process.exit(1);
});
