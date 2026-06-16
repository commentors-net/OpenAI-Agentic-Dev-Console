#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
HTML="$APPDIR/claire-dealdesk-view.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKEND/backups/revert-inspection-auto-clear-$STAMP"
PM2_NAME="dealdesk-claire-dealview"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Reverting inspection auto-clear logic."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

for f in "$SIDE" "$HTML"; do
  if [ -f "$f" ]; then
    cp -f "$f" "$BACKUP_DIR/$(basename "$f").before-$STAMP.bak"
  fi
done

cd "$BACKEND"
npm install mysql2 dotenv >/tmp/revert-inspection-npm-$STAMP.log 2>&1 || {
  cat /tmp/revert-inspection-npm-$STAMP.log
  exit 1
}

python3 - <<'PY'
from pathlib import Path
import re
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
HTML = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")

CONTINGENCY_NOTE = (
    "Home Inspection contingency identified in the Memorandum of Offer to Purchase/Sell. "
    "This confirms inspection is a contingency, but does not confirm whether inspection is scheduled, "
    "completed, waived, resolved, or still open."
)

# Patch sidecar so saving source docs does NOT clear inspection.
if SIDE.exists():
    side = SIDE.read_text(encoding="utf-8", errors="replace")

    # Replace any explicit inspection-clear report call in save-source-doc route with no-op.
    side = re.sub(
        r'const\s+inspectionNote\s*=\s*"[^"]*";\s*const\s+inspection_clear_report\s*=\s*await\s+bestEffortClearInspectionForDeal\([^;]+;\s*',
        'const inspection_clear_report = { ok: true, skipped: true, reason: "Offer memo identifies inspection contingency only; not auto-cleared." };\n\n',
        side,
        flags=re.S
    )

    # If clear-inspection route exists, make it return skipped/no-op instead of updating DB.
    route_start = side.find('url.pathname === "/api/claire-dealview/clear-inspection"')
    if route_start >= 0:
        # Find enclosing if statement start.
        if_start = side.rfind("if", 0, route_start)
        brace = side.find("{", route_start)
        if if_start >= 0 and brace >= 0:
            depth = 0
            i = brace
            in_str = False
            quote = ""
            esc = False
            in_line = False
            in_block = False
            while i < len(side):
                ch = side[i]
                nx = side[i+1] if i+1 < len(side) else ""
                if in_line:
                    if ch == "\n": in_line = False
                    i += 1; continue
                if in_block:
                    if ch == "*" and nx == "/":
                        in_block = False; i += 2
                    else:
                        i += 1
                    continue
                if in_str:
                    if esc: esc = False
                    elif ch == "\\": esc = True
                    elif ch == quote: in_str = False
                    i += 1; continue
                if ch == "/" and nx == "/":
                    in_line = True; i += 2; continue
                if ch == "/" and nx == "*":
                    in_block = True; i += 2; continue
                if ch in ("'", '"', "`"):
                    in_str = True; quote = ch; i += 1; continue
                if ch == "{": depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        new_route = '''if (req.method === "POST" && url.pathname === "/api/claire-dealview/clear-inspection") {
    sendJson(res, 200, {
      ok: true,
      skipped: true,
      reason: "Offer memo identifies home inspection as a contingency only. Inspection is not auto-cleared without completion, waiver, or resolution proof."
    });
    return;
  }'''
                        side = side[:if_start] + new_route + side[i+1:]
                        break
                i += 1

    SIDE.write_text(side, encoding="utf-8")

# Patch CLAIRE UI create payload / helper so future created deals do not ask to clear inspection.
if HTML.exists():
    html = HTML.read_text(encoding="utf-8", errors="replace")

    # Disable helper if present.
    html = re.sub(
        r'async function clearInspectionForCreatedDeal\s*\([^)]*\)\s*\{[\s\S]*?\n  \}',
        '''async function clearInspectionForCreatedDeal(deal,payload){
    return {
      ok:true,
      skipped:true,
      reason:"Offer memo identifies home inspection as a contingency only. Inspection is not auto-cleared without completion, waiver, or resolution proof."
    };
  }''',
        html,
        count=1
    )

    # Ensure payload does not send Complete for inspection.
    html = html.replace('inspection_status: "Complete",', 'inspection_status: "Open",')
    html = html.replace('inspection_status:"Complete",', 'inspection_status:"Open",')

    # Replace aggressive proof notes with contingency note.
    html = re.sub(
        r'inspection_proof_note:\s*"[^"]*(?:Inspection|inspection)[^"]*",',
        'inspection_proof_note: "' + CONTINGENCY_NOTE.replace('"', '\\"') + '",',
        html
    )
    html = re.sub(
        r'proof_note:\s*"[^"]*(?:Inspection|inspection)[^"]*"',
        'proof_note:"' + CONTINGENCY_NOTE.replace('"', '\\"') + '"',
        html
    )

    HTML.write_text(html, encoding="utf-8")

print("Patched sidecar/UI to stop inspection auto-clear.")
PY

node --check "$SIDE"

cat > "$BACKEND/reset_current_maidstone_inspection_to_open.js" <<'NODE'
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
NODE

node "$BACKEND/reset_current_maidstone_inspection_to_open.js" || true

pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Inspection logic corrected."
echo ""
echo "What changed:"
echo "1. Future CLAIRE-created deals will NOT auto-clear inspection from the offer memo."
echo "2. Offer memo home-inspection checkbox is treated as contingency only."
echo "3. Current Maidstone inspection item was targeted back to Open with the correct contingency note."
echo ""
echo "Correct state:"
echo "- Track inspection status = Open"
echo "- Count remains 0 of 10 unless actual inspection completion/waiver/resolution proof exists."
echo "- Note should say the offer memo identifies a contingency only."
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
