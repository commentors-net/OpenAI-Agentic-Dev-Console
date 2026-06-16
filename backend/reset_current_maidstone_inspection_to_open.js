#!/usr/bin/env node
const fs = require("fs");
require("dotenv").config({ path: "/home/servicedepartmen/dealdesk-backend/.env" });
const mysql = require("mysql2/promise");

const TERMS = ["25 Maidstone", "Maidstone Lane", "Wading River"];
const NOTE = "Home Inspection contingency identified in the Memorandum of Offer to Purchase/Sell. This confirms inspection is a contingency, but does not confirm whether inspection is scheduled, completed, waived, resolved, or still open.";

function q(id){ return "`" + String(id).replace(/`/g, "``") + "`"; }
function isText(t){ return /char|text|json|enum|set/i.test(String(t || "")); }
function dbConfig() {
  return {
    host: process.env.DB_HOST || process.env.MYSQL_HOST || "localhost",
    user: process.env.DB_USER || process.env.MYSQL_USER || process.env.MYSQL_USERNAME || "servicedepartmen_dealdesk",
    password: process.env.DB_PASSWORD || process.env.MYSQL_PASSWORD || process.env.DB_PASS || "",
    database: process.env.DB_NAME || process.env.MYSQL_DATABASE || process.env.DATABASE_NAME || "servicedepartmen_dealdesk",
    multipleStatements: false
  };
}

async function main(){
  const conn = await mysql.createConnection(dbConfig());
  const [cols] = await conn.query(`
    SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE()
    ORDER BY TABLE_NAME, ORDINAL_POSITION
  `);

  const byTable = new Map();
  for (const c of cols) {
    if (!byTable.has(c.TABLE_NAME)) byTable.set(c.TABLE_NAME, []);
    byTable.get(c.TABLE_NAME).push(c);
  }

  const aliases = new Set(TERMS);

  for (const [table, tcols] of byTable.entries()) {
    const names = tcols.map(c => c.COLUMN_NAME);
    const textCols = tcols.filter(c => isText(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
    if (!textCols.length) continue;

    const wh = [];
    const params = [];

    for (const col of textCols) {
      for (const term of TERMS) {
        wh.push(`${q(col)} LIKE ?`);
        params.push(`%${term}%`);
      }
    }

    try {
      const [rows] = await conn.query(`SELECT * FROM ${q(table)} WHERE ${wh.join(" OR ")} LIMIT 100`, params);
      for (const row of rows) {
        for (const k of ["id","deal_id","public_id","deal_public_id","file_id","transaction_id","property_address"]) {
          if (row[k] !== undefined && row[k] !== null && String(row[k]).trim()) aliases.add(String(row[k]));
        }
      }
    } catch(e) {}
  }

  const allAliases = Array.from(aliases);
  const statusCols = ["status","clearance_status","item_status","state","task_status"];
  const doneCols = ["is_complete","complete","completed","is_completed","cleared","is_cleared","done","is_done","resolved","is_resolved"];
  const timeCols = ["completed_at","cleared_at","resolved_at"];
  const proofCols = ["proof_note","manager_proof_note","evidence_note","clearance_note","completion_note","response_summary","note","notes","operator_note","details","manager_proof","proof","description"];
  const relationCols = ["deal_id","dealId","deal_public_id","public_id","file_id","transaction_id"];
  const changed = [];

  for (const [table, tcols] of byTable.entries()) {
    const names = tcols.map(c => c.COLUMN_NAME);
    const textCols = tcols.filter(c => isText(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
    if (!textCols.length) continue;

    const rel = [];
    const relParams = [];

    for (const col of relationCols) {
      if (names.includes(col)) {
        rel.push(`${q(col)} IN (${allAliases.map(() => "?").join(",")})`);
        relParams.push(...allAliases);
      }
    }

    for (const col of textCols) {
      for (const a of allAliases) {
        if (!a || String(a).length < 3) continue;
        rel.push(`${q(col)} LIKE ?`);
        relParams.push(`%${a}%`);
      }
    }

    if (!rel.length) continue;

    const ins = textCols.map(c => `${q(c)} LIKE ?`);
    const insParams = textCols.map(() => "%inspection%");

    let rows = [];
    try {
      [rows] = await conn.query(
        `SELECT * FROM ${q(table)} WHERE (${rel.join(" OR ")}) AND (${ins.join(" OR ")}) LIMIT 150`,
        [...relParams, ...insParams]
      );
    } catch(e) {
      continue;
    }

    if (!rows.length || !names.includes("id")) continue;

    const sets = [];
    const vals = [];

    for (const col of statusCols) {
      if (names.includes(col)) {
        sets.push(`${q(col)}=?`);
        vals.push("Open");
      }
    }

    for (const col of doneCols) {
      if (names.includes(col)) {
        sets.push(`${q(col)}=?`);
        vals.push(0);
      }
    }

    for (const col of timeCols) {
      if (names.includes(col)) sets.push(`${q(col)}=NULL`);
    }

    for (const col of proofCols) {
      if (names.includes(col)) {
        sets.push(`${q(col)}=?`);
        vals.push(NOTE);
        break;
      }
    }

    if (!sets.length) continue;

    const ids = rows.map(r => r.id).filter(v => v !== undefined && v !== null);
    if (!ids.length) continue;

    try {
      const [r] = await conn.query(
        `UPDATE ${q(table)} SET ${sets.join(", ")} WHERE ${q("id")} IN (${ids.map(() => "?").join(",")})`,
        [...vals, ...ids]
      );
      if (r.affectedRows) changed.push({ table, rows: r.affectedRows });
    } catch(e) {}
  }

  await conn.end();
  console.log(JSON.stringify({ ok:true, aliases:allAliases, changed }, null, 2));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
