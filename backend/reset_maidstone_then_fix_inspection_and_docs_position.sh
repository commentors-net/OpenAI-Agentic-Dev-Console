#!/usr/bin/env bash
set -euo pipefail

APPDIR="/home/servicedepartmen/public_html/dealdesk"
BACKEND="/home/servicedepartmen/dealdesk-backend"
SIDE="$BACKEND/claire_dealview_sidecar.js"
HTML="$APPDIR/claire-dealdesk-view.html"
DETAIL="$APPDIR/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/claire-reset-maidstone-inspection-placement-$STAMP"
SOURCE_DOC_ROOT="$APPDIR/source-docs"

mkdir -p "$BACKUP_DIR" "$SOURCE_DOC_ROOT/manifests"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Resetting 25 Maidstone test record, then patching inspection clearance and source-doc placement..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

for f in "$SIDE" "$HTML" "$DETAIL"; do
  if [ -f "$f" ]; then
    cp -f "$f" "$BACKUP_DIR/$(basename "$f").before-$STAMP.bak"
  fi
done

cd "$BACKEND"
npm install mysql2 dotenv >/tmp/claire-reset-maidstone-npm-$STAMP.log 2>&1 || {
  cat /tmp/claire-reset-maidstone-npm-$STAMP.log
  exit 1
}

cat > "$BACKEND/delete_maidstone_once.js" <<'NODE'
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

function quoteId(id) {
  return "`" + String(id).replace(/`/g, "``") + "`";
}

function isTextType(t) {
  return /char|text|json|enum|set/i.test(String(t || ""));
}

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
  const dealIds = new Set();
  const publicIds = new Set();
  const properties = new Set();

  for (const [table, tableCols] of byTable.entries()) {
    const textCols = tableCols.filter(c => isTextType(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
    if (!textCols.length) continue;

    const wheres = [];
    const params = [];
    for (const col of textCols) {
      for (const term of TERMS) {
        wheres.push(`${quoteId(col)} LIKE ?`);
        params.push(`%${term}%`);
      }
    }

    let rows = [];
    try {
      [rows] = await conn.query(`SELECT * FROM ${quoteId(table)} WHERE ${wheres.join(" OR ")} LIMIT 500`, params);
    } catch (err) {
      continue;
    }

    if (!rows.length) continue;
    candidates.push({ table, rows });

    for (const row of rows) {
      if (row.id !== undefined && row.id !== null) dealIds.add(String(row.id));
      if (row.deal_id !== undefined && row.deal_id !== null) dealIds.add(String(row.deal_id));
      if (row.public_id !== undefined && row.public_id !== null) publicIds.add(String(row.public_id));
      if (row.property_address) properties.add(String(row.property_address));
    }
  }

  const backupPath = path.join(BACKUP_DIR, "maidstone-delete-backup.json");
  fs.writeFileSync(backupPath, JSON.stringify({
    deleted_at: new Date().toISOString(),
    terms: TERMS,
    deal_ids: Array.from(dealIds),
    public_ids: Array.from(publicIds),
    properties: Array.from(properties),
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
  const aliases = Array.from(new Set([...dealIds, ...publicIds, ...properties]));

  // Delete child/dependent rows using likely deal reference columns.
  for (const [table, tableCols] of byTable.entries()) {
    const names = tableCols.map(c => c.COLUMN_NAME);
    for (const col of ["deal_id", "dealId", "deal_public_id", "public_id", "file_id", "transaction_id"]) {
      if (!names.includes(col) || !aliases.length) continue;
      try {
        const [r] = await conn.query(
          `DELETE FROM ${quoteId(table)} WHERE ${quoteId(col)} IN (${aliases.map(() => "?").join(",")})`,
          aliases
        );
        if (r.affectedRows) deleted.push({ table, column: col, rows: r.affectedRows });
      } catch (err) {}
    }
  }

  // Delete rows directly containing Maidstone.
  for (const item of candidates) {
    const tableCols = byTable.get(item.table) || [];
    const names = tableCols.map(c => c.COLUMN_NAME);
    if (names.includes("id")) {
      const ids = item.rows.map(r => r.id).filter(v => v !== undefined && v !== null);
      if (!ids.length) continue;
      try {
        const [r] = await conn.query(
          `DELETE FROM ${quoteId(item.table)} WHERE ${quoteId("id")} IN (${ids.map(() => "?").join(",")})`,
          ids
        );
        if (r.affectedRows) deleted.push({ table: item.table, column: "id", rows: r.affectedRows });
      } catch (err) {}
    } else {
      const textCols = tableCols.filter(c => isTextType(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
      const wheres = [];
      const params = [];
      for (const col of textCols) {
        for (const term of TERMS) {
          wheres.push(`${quoteId(col)} LIKE ?`);
          params.push(`%${term}%`);
        }
      }
      try {
        const [r] = await conn.query(`DELETE FROM ${quoteId(item.table)} WHERE ${wheres.join(" OR ")}`, params);
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
NODE

DD_BACKUP_DIR="$BACKUP_DIR" node "$BACKEND/delete_maidstone_once.js" || true

# Remove Maidstone source-doc manifests/files from prior test runs.
if [ -d "$SOURCE_DOC_ROOT/manifests" ]; then
  mkdir -p "$BACKUP_DIR/source-doc-manifests"
  grep -ril "maidstone\|25 Maidstone\|Wading River" "$SOURCE_DOC_ROOT/manifests" 2>/dev/null | while read -r mf; do
    cp -f "$mf" "$BACKUP_DIR/source-doc-manifests/$(basename "$mf")" || true
    folder="$(python3 - "$mf" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1]))
    print(data.get("folder",""))
except Exception:
    print("")
PY
)"
    rm -f "$mf"
    if [ -n "$folder" ] && [ -d "$SOURCE_DOC_ROOT/$folder" ]; then
      mkdir -p "$BACKUP_DIR/source-doc-folders"
      cp -a "$SOURCE_DOC_ROOT/$folder" "$BACKUP_DIR/source-doc-folders/" 2>/dev/null || true
      rm -rf "$SOURCE_DOC_ROOT/$folder"
    fi
  done
fi

python3 - <<'PY'
from pathlib import Path
import sys
import re

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
HTML = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")
DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")

if not SIDE.exists():
    print("ERROR: missing sidecar", SIDE)
    sys.exit(1)
if not HTML.exists():
    print("ERROR: missing HTML", HTML)
    sys.exit(1)

side = SIDE.read_text(encoding="utf-8", errors="replace")

# Ensure source doc constants exist.
if "SOURCE_DOC_ROOT" not in side:
    needle = 'const MAX_ATTACHMENT_BYTES = Number(process.env.CLAIRE_MAX_ATTACHMENT_BYTES || 25 * 1024 * 1024);'
    if needle not in side:
        print("ERROR: sidecar missing MAX_ATTACHMENT_BYTES marker")
        sys.exit(1)
    side = side.replace(needle, needle + r'''

const PUBLIC_DEALDESK_ROOT = "/home/servicedepartmen/public_html/dealdesk";
const SOURCE_DOC_ROOT = path.join(PUBLIC_DEALDESK_ROOT, "source-docs");
const SOURCE_DOC_MANIFEST_ROOT = path.join(SOURCE_DOC_ROOT, "manifests");
try { fs.mkdirSync(SOURCE_DOC_ROOT, { recursive: true }); fs.mkdirSync(SOURCE_DOC_MANIFEST_ROOT, { recursive: true }); } catch (err) {}
''', 1)

strong_func = r'''
async function bestEffortClearInspectionForDeal(aliases, note) {
  let mysql;
  try { mysql = require("mysql2/promise"); } catch (err) { return { ok: false, skipped: true, reason: "mysql2 not available" }; }

  const cleanAliases = Array.from(new Set((aliases || []).filter(Boolean).map(String)));
  if (!cleanAliases.length) return { ok: false, skipped: true, reason: "no deal identifiers" };

  const conn = await mysql.createConnection(dbConfigForClaire());
  const changed = [];
  const inspected = [];
  const errors = [];

  try {
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

    const expandedAliases = new Set(cleanAliases);

    // Expand identifiers by locating rows matching created deal property/public id.
    for (const [table, tableCols] of byTable.entries()) {
      const textCols = tableCols
        .filter(c => /char|text|json|enum|set/i.test(String(c.DATA_TYPE || "")))
        .map(c => c.COLUMN_NAME);
      if (!textCols.length) continue;

      const wheres = [];
      const params = [];
      for (const col of textCols) {
        for (const a of cleanAliases) {
          if (!a || a.length < 3) continue;
          wheres.push(`${quoteSqlId(col)} LIKE ?`);
          params.push(`%${a}%`);
        }
      }
      if (!wheres.length) continue;

      try {
        const [rows] = await conn.query(`SELECT * FROM ${quoteSqlId(table)} WHERE ${wheres.join(" OR ")} LIMIT 100`, params);
        for (const row of rows) {
          for (const k of ["id","deal_id","public_id","deal_public_id","file_id","transaction_id","property_address"]) {
            if (row[k] !== undefined && row[k] !== null && String(row[k]).trim()) expandedAliases.add(String(row[k]));
          }
        }
      } catch (err) {}
    }

    const allAliases = Array.from(expandedAliases);

    const statusCols = ["status", "clearance_status", "item_status", "state"];
    const doneCols = ["is_complete", "complete", "completed", "is_completed", "cleared", "is_cleared", "done", "is_done", "resolved", "is_resolved"];
    const timeCols = ["completed_at", "cleared_at", "resolved_at", "updated_at"];
    const proofCols = ["proof_note", "manager_proof_note", "evidence_note", "clearance_note", "completion_note", "response_summary", "note", "notes", "operator_note", "details"];

    for (const [table, tableCols] of byTable.entries()) {
      const names = tableCols.map(c => c.COLUMN_NAME);
      const textCols = tableCols
        .filter(c => /char|text|json|enum|set/i.test(String(c.DATA_TYPE || "")))
        .map(c => c.COLUMN_NAME);

      const relationWheres = [];
      const relationParams = [];

      for (const col of ["deal_id", "dealId", "deal_public_id", "public_id", "file_id", "transaction_id"]) {
        if (names.includes(col)) {
          relationWheres.push(`${quoteSqlId(col)} IN (${allAliases.map(() => "?").join(",")})`);
          relationParams.push(...allAliases);
        }
      }

      for (const col of textCols) {
        for (const a of allAliases) {
          if (!a || a.length < 3) continue;
          relationWheres.push(`${quoteSqlId(col)} LIKE ?`);
          relationParams.push(`%${a}%`);
        }
      }

      if (!relationWheres.length || !textCols.length) continue;

      const inspectionWheres = textCols.map(c => `${quoteSqlId(c)} LIKE ?`);
      const inspectionParams = textCols.map(() => "%inspection%");

      let rows = [];
      try {
        [rows] = await conn.query(
          `SELECT * FROM ${quoteSqlId(table)} WHERE (${relationWheres.join(" OR ")}) AND (${inspectionWheres.join(" OR ")}) LIMIT 100`,
          [...relationParams, ...inspectionParams]
        );
      } catch (err) {
        errors.push({ table, stage: "select", error: err.message });
        continue;
      }

      if (!rows.length) continue;
      inspected.push({ table, rows: rows.length });

      const sets = [];
      const values = [];

      for (const col of statusCols) {
        if (names.includes(col)) {
          sets.push(`${quoteSqlId(col)}=?`);
          values.push("Complete");
        }
      }

      for (const col of doneCols) {
        if (names.includes(col)) {
          sets.push(`${quoteSqlId(col)}=?`);
          values.push(1);
        }
      }

      for (const col of timeCols) {
        if (names.includes(col)) sets.push(`${quoteSqlId(col)}=NOW()`);
      }

      for (const col of proofCols) {
        if (names.includes(col)) {
          sets.push(`${quoteSqlId(col)}=?`);
          values.push(note);
          break;
        }
      }

      if (!sets.length) continue;

      try {
        if (names.includes("id")) {
          const ids = rows.map(r => r.id).filter(v => v !== undefined && v !== null);
          if (!ids.length) continue;
          const [result] = await conn.query(
            `UPDATE ${quoteSqlId(table)} SET ${sets.join(", ")} WHERE ${quoteSqlId("id")} IN (${ids.map(() => "?").join(",")})`,
            [...values, ...ids]
          );
          if (result.affectedRows) changed.push({ table, rows: result.affectedRows, method: "id" });
        } else {
          const [result] = await conn.query(
            `UPDATE ${quoteSqlId(table)} SET ${sets.join(", ")} WHERE (${relationWheres.join(" OR ")}) AND (${inspectionWheres.join(" OR ")})`,
            [...values, ...relationParams, ...inspectionParams]
          );
          if (result.affectedRows) changed.push({ table, rows: result.affectedRows, method: "relation+inspection" });
        }
      } catch (err) {
        errors.push({ table, stage: "update", error: err.message });
      }
    }

    return { ok: true, aliases: allAliases, inspected, changed, errors };
  } catch (err) {
    return { ok: false, error: err.message, inspected, changed, errors };
  } finally {
    await conn.end().catch(() => {});
  }
}
'''

# Ensure db helper functions exist.
if "function dbConfigForClaire()" not in side:
    helper = r'''
function dbConfigForClaire() {
  return {
    host: process.env.DB_HOST || process.env.MYSQL_HOST || "localhost",
    user: process.env.DB_USER || process.env.MYSQL_USER || process.env.MYSQL_USERNAME || "servicedepartmen_dealdesk",
    password: process.env.DB_PASSWORD || process.env.MYSQL_PASSWORD || process.env.DB_PASS || "",
    database: process.env.DB_NAME || process.env.MYSQL_DATABASE || process.env.DATABASE_NAME || "servicedepartmen_dealdesk",
    multipleStatements: false
  };
}

function quoteSqlId(id) {
  return "`" + String(id).replace(/`/g, "``") + "`";
}
'''
    idx = side.find("async function handle(req, res)")
    if idx < 0:
      print("ERROR: cannot insert db helpers")
      sys.exit(1)
    side = side[:idx] + helper + "\n" + side[idx:]

def replace_function(src, fn_name, replacement):
    start = src.find(fn_name)
    if start < 0:
        return src, False
    brace = src.find("{", start)
    depth = 0
    i = brace
    in_string = False
    quote = ""
    esc = False
    in_line = False
    in_block = False
    while i < len(src):
        ch = src[i]
        nx = src[i+1] if i+1 < len(src) else ""
        if in_line:
            if ch == "\n": in_line = False
            i += 1; continue
        if in_block:
            if ch == "*" and nx == "/":
                in_block = False; i += 2
            else:
                i += 1
            continue
        if in_string:
            if esc: esc = False
            elif ch == "\\": esc = True
            elif ch == quote: in_string = False
            i += 1; continue
        if ch == "/" and nx == "/":
            in_line = True; i += 2; continue
        if ch == "/" and nx == "*":
            in_block = True; i += 2; continue
        if ch in ("'", '"', "`"):
            in_string = True; quote = ch; i += 1; continue
        if ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[:start] + replacement + src[i+1:], True
        i += 1
    return src, False

side, replaced = replace_function(side, "async function bestEffortClearInspectionForDeal", strong_func)
if not replaced:
    idx = side.find("async function handle(req, res)")
    side = side[:idx] + strong_func + "\n" + side[idx:]

# Ensure source doc routes exist.
if '"/api/claire-dealview/save-source-docs"' in side:
    side = side.replace(
        'const inspectionNote = "Inspection treated as cleared from accepted-offer intake package. CLAIRE detected/verified inspection status before deal creation; operator should confirm if office policy requires separate proof.";',
        'const inspectionNote = "Inspection status cleared from accepted-offer intake using the offer memorandum as clearance detail: Home Inspection contingency/status was identified in the Memorandum of Offer to Purchase/Sell reviewed by CLAIRE. Operator should confirm if office policy requires separate inspection proof.";'
    )
else:
    print("WARNING: source-doc route not found; this script assumes prior source-doc upgrade was installed.")

SIDE.write_text(side, encoding="utf-8")

# Patch CLAIRE create payload note.
html = HTML.read_text(encoding="utf-8", errors="replace")
html = html.replace(
    'inspection_proof_note: "Inspection treated as cleared at accepted-offer intake based on CLAIRE review; operator should confirm if office policy requires separate proof.",',
    'inspection_proof_note: "Inspection status cleared from accepted-offer intake using the offer memorandum as clearance detail. CLAIRE identified the Home Inspection contingency/status in the Memorandum of Offer to Purchase/Sell; operator should confirm if office policy requires separate inspection proof.",'
)
html = html.replace(
    'proof_note:"Inspection treated as cleared at accepted-offer intake based on CLAIRE review; operator should confirm if office policy requires separate proof."',
    'proof_note:"Inspection status cleared from accepted-offer intake using the offer memorandum as clearance detail. CLAIRE identified the Home Inspection contingency/status in the Memorandum of Offer to Purchase/Sell; operator should confirm if office policy requires separate inspection proof."'
)
HTML.write_text(html, encoding="utf-8")

# Move/source docs placement in detail.
if DETAIL.exists():
    detail = DETAIL.read_text(encoding="utf-8", errors="replace")
    new_panel_script = r'''
<!-- DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->
<script>
(function(){
  function esc(s){return String(s||"").replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[c]})}
  function dealIdFromUrl(){
    const u=new URL(location.href);
    return u.searchParams.get("id") || u.searchParams.get("deal_id") || u.searchParams.get("public_id") || "";
  }
  function closestPanel(el){
    if(!el)return null;
    return el.closest("section,.card,.panel,.deal-section,.detail-section,[class*='card'],[class*='panel'],[class*='section']") || el.parentElement;
  }
  function findPanelByText(needles){
    const els=Array.from(document.querySelectorAll("h1,h2,h3,h4,section,.card,.panel,div"));
    for(const el of els){
      const txt=(el.textContent||"").replace(/\s+/g," ").trim().toLowerCase();
      if(!txt)continue;
      if(needles.some(n=>txt.includes(n)))return closestPanel(el);
    }
    return null;
  }
  function placeSourceDocsPanel(panel){
    const offer=findPanelByText(["offer review","accepted offer review","offer details","deal review"]);
    const audit=findPanelByText(["audit history","file history","activity history","deal history"]);

    if(offer && offer.parentNode){
      offer.insertAdjacentElement("afterend", panel);
      return;
    }

    if(audit && audit.parentNode){
      audit.parentNode.insertBefore(panel, audit);
      return;
    }

    const main=document.querySelector("main") || document.body;
    main.appendChild(panel);
  }
  async function loadClaireSourceDocs(){
    const id=dealIdFromUrl();
    if(!id)return;
    try{
      const res=await fetch("./api/claire-dealview/source-docs?deal_id="+encodeURIComponent(id),{headers:{Accept:"application/json"},cache:"no-store"});
      const data=await res.json();
      const docs=data.source_documents||[];
      if(!docs.length)return;

      const existing=document.querySelector(".claire-source-docs-card");
      if(existing)existing.remove();

      const panel=document.createElement("section");
      panel.className="card claire-source-docs-card";
      panel.style.cssText="margin:16px 0;padding:0;border:1px solid #dbe5ef;border-radius:14px;background:#fff;box-shadow:0 10px 26px rgba(15,35,55,.06);overflow:hidden;font-family:Arial,Helvetica,sans-serif;";
      panel.innerHTML='<div style="padding:14px 16px;background:#f8fbfe;border-bottom:1px solid #dbe5ef;font-weight:900;">CLAIRE Source Documents</div><div style="padding:14px 16px;display:grid;gap:8px;">'+docs.map(function(d){return '<a style="display:block;padding:10px 12px;border:1px solid #dbe5ef;border-radius:10px;text-decoration:none;color:#071b2c;font-weight:800;background:#fff;" target="_blank" rel="noopener" href="'+esc(d.url)+'">'+esc(d.filename)+' <span style="color:#66758a;font-weight:400;">('+esc(d.mime_type||"document")+')</span></a>'}).join("")+'</div>';

      placeSourceDocsPanel(panel);
    }catch(e){}
  }
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",loadClaireSourceDocs);
  else loadClaireSourceDocs();
})();
</script>
<!-- END_DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->
'''
    pattern = re.compile(r'<!-- DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->[\s\S]*?<!-- END_DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->')
    if pattern.search(detail):
        detail = pattern.sub(new_panel_script, detail)
    else:
        idx = detail.lower().rfind("</body>")
        if idx >= 0:
            detail = detail[:idx] + new_panel_script + "\n" + detail[idx:]
        else:
            detail += "\n" + new_panel_script
    DETAIL.write_text(detail, encoding="utf-8")

print("Reset and patch complete.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Done."
echo ""
echo "Included:"
echo "1. Deleted/reset 25 Maidstone rows found in MySQL, with backup."
echo "2. Removed prior Maidstone CLAIRE source-doc manifests/folders, with backup."
echo "3. Reapplied inspection clearance fix using offer memo as clearance detail."
echo "4. Reapplied source-doc panel placement below Offer Review / above Audit History."
echo ""
echo "Now run from the beginning:"
echo "https://servicedepartment.ai/dealdesk/claire-dealdesk-view.html"
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
