#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKEND/backups/inspection-force-diagnostic-$STAMP.txt"
NODE_SCRIPT="$BACKEND/force_inspection_clear_diagnostic.js"

mkdir -p "$BACKEND/backups"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Running exact inspection diagnostic + force clear..."
echo "Output file: $OUT"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

cd "$BACKEND"
npm install mysql2 dotenv >/tmp/inspection-force-npm-$STAMP.log 2>&1 || {
  cat /tmp/inspection-force-npm-$STAMP.log
  exit 1
}

cat > "$NODE_SCRIPT" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
require("dotenv").config({ path: "/home/servicedepartmen/dealdesk-backend/.env" });
const mysql = require("mysql2/promise");

const OUT = process.env.OUT_FILE || "/tmp/inspection-force-diagnostic.txt";
const lines = [];
function log(...args) {
  const s = args.map(a => typeof a === "string" ? a : JSON.stringify(a, null, 2)).join(" ");
  lines.push(s);
  console.log(s);
}
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

const TARGET_TERMS = ["25 Maidstone", "Maidstone Lane", "25 Maidstone Lane", "Wading River"];
const NOTE = "Inspection CLEARED from accepted-offer intake using the offer memorandum as clearance detail. CLAIRE identified the Home Inspection contingency/status in the Memorandum of Offer to Purchase/Sell. Operator should confirm if office policy requires separate inspection proof.";

const statusCols = ["status","clearance_status","item_status","state","task_status"];
const doneCols = ["is_complete","complete","completed","is_completed","cleared","is_cleared","done","is_done","resolved","is_resolved"];
const timeCols = ["completed_at","cleared_at","resolved_at","updated_at","last_updated_at"];
const proofCols = ["proof_note","manager_proof_note","evidence_note","clearance_note","completion_note","response_summary","note","notes","operator_note","details","manager_proof","proof","description"];
const relationCols = ["deal_id","dealId","deal_public_id","public_id","file_id","transaction_id"];

function pickStatusValue(colName) {
  const c = String(colName || "").toLowerCase();
  if (c.includes("status") || c === "state") return "cleared";
  return "cleared";
}

async function columnsByTable(conn) {
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
  return byTable;
}

async function findDeals(conn, byTable) {
  const found = [];
  const aliases = new Set(TARGET_TERMS);
  for (const [table, cols] of byTable.entries()) {
    const textCols = cols.filter(c => isText(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
    if (!textCols.length) continue;

    const wh = [];
    const params = [];
    for (const col of textCols) {
      for (const term of TARGET_TERMS) {
        wh.push(`${q(col)} LIKE ?`);
        params.push(`%${term}%`);
      }
    }

    let rows = [];
    try {
      [rows] = await conn.query(`SELECT * FROM ${q(table)} WHERE ${wh.join(" OR ")} LIMIT 100`, params);
    } catch (e) {
      continue;
    }

    if (rows.length) {
      found.push({ table, rows });
      for (const row of rows) {
        for (const k of ["id","deal_id","public_id","deal_public_id","file_id","transaction_id","property_address"]) {
          if (row[k] !== undefined && row[k] !== null && String(row[k]).trim()) aliases.add(String(row[k]));
        }
      }
    }
  }
  return { found, aliases: Array.from(aliases) };
}

async function distinctStatuses(conn, table, cols) {
  const names = cols.map(c => c.COLUMN_NAME);
  const out = {};
  for (const col of statusCols) {
    if (!names.includes(col)) continue;
    try {
      const [rows] = await conn.query(`SELECT ${q(col)} value, COUNT(*) count FROM ${q(table)} GROUP BY ${q(col)} ORDER BY count DESC LIMIT 20`);
      out[col] = rows;
    } catch (e) {}
  }
  return out;
}

async function findInspectionRows(conn, byTable, aliases) {
  const all = [];
  for (const [table, cols] of byTable.entries()) {
    const names = cols.map(c => c.COLUMN_NAME);
    const textCols = cols.filter(c => isText(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
    if (!textCols.length) continue;

    const rel = [];
    const relParams = [];

    for (const col of relationCols) {
      if (names.includes(col)) {
        rel.push(`${q(col)} IN (${aliases.map(() => "?").join(",")})`);
        relParams.push(...aliases);
      }
    }

    for (const col of textCols) {
      for (const a of aliases) {
        if (!a || String(a).length < 3) continue;
        rel.push(`${q(col)} LIKE ?`);
        relParams.push(`%${a}%`);
      }
    }

    if (!rel.length) continue;

    const ins = [];
    const insParams = [];
    for (const col of textCols) {
      ins.push(`${q(col)} LIKE ?`);
      insParams.push("%inspection%");
    }

    let rows = [];
    try {
      [rows] = await conn.query(
        `SELECT * FROM ${q(table)} WHERE (${rel.join(" OR ")}) AND (${ins.join(" OR ")}) LIMIT 200`,
        [...relParams, ...insParams]
      );
    } catch (e) {
      continue;
    }

    if (rows.length) {
      all.push({ table, cols, rows });
    }
  }
  return all;
}

async function updateInspectionRows(conn, matches) {
  const changed = [];

  for (const item of matches) {
    const table = item.table;
    const names = item.cols.map(c => c.COLUMN_NAME);

    const sets = [];
    const vals = [];

    for (const col of statusCols) {
      if (names.includes(col)) {
        sets.push(`${q(col)}=?`);
        vals.push(pickStatusValue(col));
      }
    }

    for (const col of doneCols) {
      if (names.includes(col)) {
        sets.push(`${q(col)}=?`);
        vals.push(1);
      }
    }

    for (const col of timeCols) {
      if (names.includes(col)) {
        sets.push(`${q(col)}=NOW()`);
      }
    }

    for (const col of proofCols) {
      if (names.includes(col)) {
        sets.push(`${q(col)}=?`);
        vals.push(NOTE);
        break;
      }
    }

    if (!sets.length) {
      changed.push({ table, skipped: true, reason: "no status/done/proof columns detected" });
      continue;
    }

    if (!names.includes("id")) {
      changed.push({ table, skipped: true, reason: "no id column; not updating blindly" });
      continue;
    }

    const ids = item.rows.map(r => r.id).filter(v => v !== undefined && v !== null);
    if (!ids.length) {
      changed.push({ table, skipped: true, reason: "no ids found" });
      continue;
    }

    try {
      const [r] = await conn.query(
        `UPDATE ${q(table)} SET ${sets.join(", ")} WHERE ${q("id")} IN (${ids.map(() => "?").join(",")})`,
        [...vals, ...ids]
      );
      changed.push({ table, ids, affectedRows: r.affectedRows, sets: sets.map(s => s.replace(/=.*/, "")) });
    } catch (e) {
      changed.push({ table, ids, error: e.message });
    }
  }

  return changed;
}

async function main() {
  const conn = await mysql.createConnection(dbConfig());
  const [dbRows] = await conn.query("SELECT DATABASE() db");
  log("DATABASE:", dbRows[0].db);

  const byTable = await columnsByTable(conn);
  const { found, aliases } = await findDeals(conn, byTable);

  log("\nMATCHING MAIDSTONE ROW GROUPS:");
  log(found.map(x => ({ table: x.table, rows: x.rows.length })));

  log("\nALIASES USED:");
  log(aliases);

  log("\nLIKELY DEAL ROWS:");
  for (const group of found) {
    if (/deal/i.test(group.table)) {
      log("TABLE " + group.table);
      for (const row of group.rows.slice(0, 10)) log(row);
    }
  }

  log("\nSTATUS VALUE INVENTORY FOR TASK/CHECKLIST TABLES:");
  for (const [table, cols] of byTable.entries()) {
    if (!/task|checklist|clearance|history|deal/i.test(table)) continue;
    const statuses = await distinctStatuses(conn, table, cols);
    if (Object.keys(statuses).length) log({ table, statuses });
  }

  const matches = await findInspectionRows(conn, byTable, aliases);

  log("\nINSPECTION ROWS FOUND BEFORE UPDATE:");
  for (const item of matches) {
    log("TABLE " + item.table);
    log("COLUMNS:", item.cols.map(c => `${c.COLUMN_NAME}:${c.DATA_TYPE}`).join(", "));
    for (const row of item.rows) log(row);
  }

  const changed = await updateInspectionRows(conn, matches);
  log("\nUPDATE RESULTS:");
  log(changed);

  const after = await findInspectionRows(conn, byTable, aliases);
  log("\nINSPECTION ROWS AFTER UPDATE:");
  for (const item of after) {
    log("TABLE " + item.table);
    for (const row of item.rows) log(row);
  }

  await conn.end();
}

main().catch(err => {
  log("FATAL:", err.stack || err.message);
  process.exitCode = 1;
}).finally(() => {
  fs.writeFileSync(OUT, lines.join("\n") + "\n", "utf8");
});
NODE

OUT_FILE="$OUT" node "$NODE_SCRIPT"

# Add/repair UI-only hide for empty Deal Documents. This is independent of DB.
if [ -f "$APPDIR/detail.html" ]; then
  cp -f "$APPDIR/detail.html" "$BACKEND/backups/detail.html.before-hide-empty-docs-$STAMP.bak"

  python3 - <<'PY'
from pathlib import Path

p = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")
text = p.read_text(encoding="utf-8", errors="replace")

marker = "DEALDESK_HIDE_EMPTY_GENERIC_DOCS_V1"
snippet = r'''
<!-- DEALDESK_HIDE_EMPTY_GENERIC_DOCS_V1 -->
<script>
(function(){
  function closestPanel(el){
    if(!el)return null;
    return el.closest("section,.card,.panel,.deal-section,.detail-section,[class*='card'],[class*='panel'],[class*='section']") || el.parentElement;
  }
  function hideEmptyDocs(){
    const nodes=Array.from(document.querySelectorAll("h1,h2,h3,h4,section,.card,.panel,div"));
    for(const n of nodes){
      const txt=(n.textContent||"").replace(/\s+/g," ").trim().toLowerCase();
      if(txt.includes("deal documents") && txt.includes("no documents attached to this deal yet")){
        const panel=closestPanel(n);
        if(panel)panel.style.display="none";
      }
    }
  }
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",hideEmptyDocs);
  else hideEmptyDocs();
  setTimeout(hideEmptyDocs,500);
  setTimeout(hideEmptyDocs,1500);
})();
</script>
<!-- END_DEALDESK_HIDE_EMPTY_GENERIC_DOCS_V1 -->
'''

if marker not in text:
    idx = text.lower().rfind("</body>")
    if idx >= 0:
        text = text[:idx] + snippet + "\n" + text[idx:]
    else:
        text += "\n" + snippet
    p.write_text(text, encoding="utf-8")
PY
fi

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
cat "$OUT"
echo ""
echo "Output saved at:"
echo "$OUT"
echo ""
echo "Next:"
echo "1. Hard refresh the deal detail page."
echo "2. Hard refresh dashboard."
echo "3. If count still says 10 open, paste the INSPECTION ROWS AFTER UPDATE section from above."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
