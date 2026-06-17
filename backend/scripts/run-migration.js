#!/usr/bin/env node
/**
 * Simple Auto-Migration Tool for Deal Desk
 * Scans backend/sql/ and applies missing .sql files.
 */
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
        multipleStatements: true
    });

    try {
        // 1. Ensure migration tracking table exists
        await pool.query(`
            CREATE TABLE IF NOT EXISTS dd_migrations (
                id INT AUTO_INCREMENT PRIMARY KEY,
                filename VARCHAR(255) NOT NULL UNIQUE,
                applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        `);

        // 2. Get applied migrations
        const [rows] = await pool.query('SELECT filename FROM dd_migrations');
        const applied = new Set(rows.map(r => r.filename));

        // 3. Scan sql directory
        const sqlDir = path.join(__dirname, '..', 'sql');
        const files = fs.readdirSync(sqlDir)
            .filter(f => f.endsWith('.sql'))
            .sort();

        for (const file of files) {
            if (!applied.has(file)) {
                console.log(`Applying migration: ${file}...`);
                const sql = fs.readFileSync(path.join(sqlDir, file), 'utf8');
                
                // We use a connection for multiple statements
                const conn = await pool.getConnection();
                try {
                    await conn.query(sql);
                    await conn.query('INSERT INTO dd_migrations (filename) VALUES (?)', [file]);
                } catch (err) {
                    if (err.errno === 1060 || err.errno === 1061 || err.code === 'ER_DUP_FIELDNAME' || err.code === 'ER_DUP_KEYNAME') {
                        console.log(`[Warning] Migration ${file} has duplicate columns/keys but is assumed applied: ${err.message}`);
                        await conn.query('INSERT INTO dd_migrations (filename) VALUES (?)', [file]);
                    } else {
                        throw err;
                    }
                } finally {
                    conn.release();
                }
            }
        }

        console.log("Database migration check complete.");
    } catch (err) {
        console.error("Migration failed: " + err.message);
        process.exit(1);
    } finally {
        await pool.end();
    }
}

migrate();
