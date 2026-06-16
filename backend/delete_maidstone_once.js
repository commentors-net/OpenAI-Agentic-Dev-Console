#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
require("dotenv").config({ path: "/home/servicedepartmen/dealdesk-backend/.env" });
const mysql = require("mysql2/promise");

const BACKUP_DIR = process.env.DD_BACKUP_DIR || "/home/servicedepartmen/dealdesk-backend/backups";
const TERMS = ["25 Maidstone", "Maidstone Lane", "25 Maidstone Lane", "Wading River"];

function dbConfig() {
  return {
    host: process.env.DB_HOST || process.env.MYSQL_HOST || "localhost",
    user: process.env.DB_USER || process.env.MYSQL_USER || process.env.MYSQL_USERNAME || "servicedepartmen_dealdesk",
    password: process.env.DB_PASSWORD || process.env.MYSQL_PASSWORD || process.env.DB_PASS || "",
    database: process.env.DB_NAME || process.env.MYSQL_DATABASE || process.env.DATABASE_NAME || "servicedepartmen_dealdesk",
    multipleStatements: false
  };
}
function q(id){ return "`" + String(id).replace(/`/g, "``") + "`"; }
function isText(t){ return /char|text|json|enum|set/i.test(String(t || "")); }

async function main() {
  const conn = await mysql.createConnection(dbConfig());
  const [cols] = await conn.query(`
    SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
    ORDER BY TABLE_NAME, ORDINAL_POSITION
  `);

  const byTable = new Map();
  for (const c of cols) {
    if (!byTable.has(c.TABLE_NAME)) byTable.set(c.TABLE_NAME, []);
    byTable.get(c.TABLE_NAME).push(c);
  }

  const candidates = [];
  const aliases = new Set(TERMS);

  for (const [table, tableCols] of byTable.entries()) {
    const textCols = tableCols.filter(c => isText(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
    if (!textCols.length) continue;

    const wheres = [];
    const params = [];
    for (const col of textCols) {
      for (const term of TERMS) {
        wheres.push(`${q(col)} LIKE ?`);
        params.push(`%${term}%`);
      }
    }

    let rows = [];
    try {
      [rows] = await conn.query(`SELECT * FROM ${q(table)} WHERE ${wheres.join(" OR ")} LIMIT 500`, params);
    } catch (err) {
      continue;
    }

    if (!rows.length) continue;
    candidates.push({ table, rows });

    for (const row of rows) {
      for (const k of ["id","deal_id","public_id","deal_public_id","file_id","transaction_id","property_address"]) {
        if (row[k] !== undefined && row[k] !== null && String(row[k]).trim()) aliases.add(String(row[k]));
      }
    }
  }

  const backupPath = path.join(BACKUP_DIR, "maidstone-delete-backup.json");
  fs.writeFileSync(backupPath, JSON.stringify({
    deleted_at: new Date().toISOString(),
    terms: TERMS,
    aliases: Array.from(aliases),
    candidates
  }, null, 2));

  if (!candidates.length) {
    console.log("No Maidstone rows found. Nothing deleted.");
    console.log("Backup:", backupPath);
    await conn.end();
    return;
  }

  await conn.query("SET FOREIGN_KEY_CHECKS=0");

  const deleted = [];
  const allAliases = Array.from(aliases);

  for (const [table, tableCols] of byTable.entries()) {
    const names = tableCols.map(c => c.COLUMN_NAME);
    for (const col of ["deal_id", "dealId", "deal_public_id", "public_id", "file_id", "transaction_id"]) {
      if (!names.includes(col) || !allAliases.length) continue;
      try {
        const [r] = await conn.query(
          `DELETE FROM ${q(table)} WHERE ${q(col)} IN (${allAliases.map(() => "?").join(",")})`,
          allAliases
        );
        if (r.affectedRows) deleted.push({ table, column: col, rows: r.affectedRows });
      } catch (err) {}
    }
  }

  for (const item of candidates) {
    const tableCols = byTable.get(item.table) || [];
    const names = tableCols.map(c => c.COLUMN_NAME);

    if (names.includes("id")) {
      const ids = item.rows.map(r => r.id).filter(v => v !== undefined && v !== null);
      if (!ids.length) continue;
      try {
        const [r] = await conn.query(
          `DELETE FROM ${q(item.table)} WHERE ${q("id")} IN (${ids.map(() => "?").join(",")})`,
          ids
        );
        if (r.affectedRows) deleted.push({ table: item.table, column: "id", rows: r.affectedRows });
      } catch (err) {}
    } else {
      const textCols = tableCols.filter(c => isText(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
      const wheres = [];
      const params = [];
      for (const col of textCols) {
        for (const term of TERMS) {
          wheres.push(`${q(col)} LIKE ?`);
          params.push(`%${term}%`);
        }
      }
      try {
        const [r] = await conn.query(`DELETE FROM ${q(item.table)} WHERE ${wheres.join(" OR ")}`, params);
        if (r.affectedRows) deleted.push({ table: item.table, column: "text match", rows: r.affectedRows });
      } catch (err) {}
    }
  }

  await conn.query("SET FOREIGN_KEY_CHECKS=1");
  await conn.end();

  console.log("Maidstone delete complete.");
  console.log("Backup:", backupPath);
  console.log("Deleted:", JSON.stringify(deleted, null, 2));
}
main().catch(err => {
  console.error("Maidstone delete failed:", err.message);
  process.exit(1);
});
