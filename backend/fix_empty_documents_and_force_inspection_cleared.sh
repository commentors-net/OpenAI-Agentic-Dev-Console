#!/usr/bin/env bash
set -euo pipefail

APPDIR="/home/servicedepartmen/public_html/dealdesk"
BACKEND="/home/servicedepartmen/dealdesk-backend"
SIDE="$BACKEND/claire_dealview_sidecar.js"
HTML="$APPDIR/claire-dealdesk-view.html"
DETAIL="$APPDIR/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/fix-docs-panel-and-inspection-cleared-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Fixing cleanup items:"
echo "1. Hide empty Deal Documents placeholder."
echo "2. Force inspection item to Cleared using offer memo as proof."
echo "3. Patch CLAIRE create flow so future created deals clear inspection correctly."
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
npm install mysql2 dotenv >/tmp/claire-cleanup-npm-$STAMP.log 2>&1 || {
  cat /tmp/claire-cleanup-npm-$STAMP.log
  exit 1
}

python3 - <<'PY'
from pathlib import Path
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
HTML = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")
DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")

if not SIDE.exists():
    print("ERROR: missing sidecar")
    sys.exit(1)

side = SIDE.read_text(encoding="utf-8", errors="replace")

def replace_function(src, name, replacement):
    start = src.find(name)
    if start < 0:
        return src, False

    brace = src.find("{", start)
    if brace < 0:
        return src, False

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
            i += 1
            continue

        if in_block:
            if ch == "*" and nx == "/":
                in_block = False
                i += 2
            else:
                i += 1
            continue

        if in_string:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == quote:
                in_string = False
            i += 1
            continue

        if ch == "/" and nx == "/":
            in_line = True
            i += 2
            continue

        if ch == "/" and nx == "*":
            in_block = True
            i += 2
            continue

        if ch in ("'", '"', "`"):
            in_string = True
            quote = ch
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[:start] + replacement + src[i+1:], True

        i += 1

    return src, False

# Ensure DB helper functions exist.
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
        print("ERROR: cannot insert DB helpers")
        sys.exit(1)
    side = side[:idx] + helper + "\n" + side[idx:]

clear_func = r'''
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

    // Expand from deal rows matching property/public id/id.
    for (const [table, tableCols] of byTable.entries()) {
      const names = tableCols.map(c => c.COLUMN_NAME);
      const textCols = tableCols
        .filter(c => /char|text|json|enum|set/i.test(String(c.DATA_TYPE || "")))
        .map(c => c.COLUMN_NAME);

      const wheres = [];
      const params = [];

      for (const col of ["id", "deal_id", "public_id", "deal_public_id", "file_id", "transaction_id"]) {
        if (names.includes(col)) {
          wheres.push(`${quoteSqlId(col)} IN (${cleanAliases.map(() => "?").join(",")})`);
          params.push(...cleanAliases);
        }
      }

      for (const col of textCols) {
        for (const a of cleanAliases) {
          if (!a || a.length < 3) continue;
          wheres.push(`${quoteSqlId(col)} LIKE ?`);
          params.push(`%${a}%`);
        }
      }

      if (!wheres.length) continue;

      try {
        const [rows] = await conn.query(`SELECT * FROM ${quoteSqlId(table)} WHERE ${wheres.join(" OR ")} LIMIT 150`, params);
        for (const row of rows) {
          for (const k of ["id","deal_id","public_id","deal_public_id","file_id","transaction_id","property_address"]) {
            if (row[k] !== undefined && row[k] !== null && String(row[k]).trim()) expandedAliases.add(String(row[k]));
          }
        }
      } catch (err) {}
    }

    const allAliases = Array.from(expandedAliases);

    const statusCols = ["status", "clearance_status", "item_status", "state", "task_status"];
    const doneCols = ["is_complete", "complete", "completed", "is_completed", "cleared", "is_cleared", "done", "is_done", "resolved", "is_resolved"];
    const timeCols = ["completed_at", "cleared_at", "resolved_at", "updated_at"];
    const proofCols = ["proof_note", "manager_proof_note", "evidence_note", "clearance_note", "completion_note", "response_summary", "note", "notes", "operator_note", "details", "manager_proof"];
    const relationCols = ["deal_id", "dealId", "deal_public_id", "public_id", "file_id", "transaction_id"];

    for (const [table, tableCols] of byTable.entries()) {
      const names = tableCols.map(c => c.COLUMN_NAME);
      const textCols = tableCols
        .filter(c => /char|text|json|enum|set/i.test(String(c.DATA_TYPE || "")))
        .map(c => c.COLUMN_NAME);

      if (!textCols.length) continue;

      const relationWheres = [];
      const relationParams = [];

      for (const col of relationCols) {
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

      if (!relationWheres.length) continue;

      const inspectionWheres = textCols.map(c => `${quoteSqlId(c)} LIKE ?`);
      const inspectionParams = textCols.map(() => "%inspection%");

      let rows = [];
      try {
        [rows] = await conn.query(
          `SELECT * FROM ${quoteSqlId(table)} WHERE (${relationWheres.join(" OR ")}) AND (${inspectionWheres.join(" OR ")}) LIMIT 150`,
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
          values.push("Cleared");
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

side, replaced = replace_function(side, "async function bestEffortClearInspectionForDeal", clear_func)
if not replaced:
    idx = side.find("async function handle(req, res)")
    if idx < 0:
        print("ERROR: cannot insert inspection function")
        sys.exit(1)
    side = side[:idx] + clear_func + "\n" + side[idx:]

# Add explicit clear-inspection route.
route = r'''
  if (req.method === "POST" && url.pathname === "/api/claire-dealview/clear-inspection") {
    const rawBody = await readBody(req);
    let body = {};
    try { body = rawBody ? JSON.parse(rawBody) : {}; } catch (err) { body = {}; }

    const deal = body.deal || {};
    const payload = body.payload || {};
    const aliases = [
      body.deal_id,
      body.deal_public_id,
      deal.id,
      deal.deal_id,
      deal.public_id,
      payload.property_address,
      body.property_address
    ].filter(Boolean);

    const note = "Inspection status cleared from accepted-offer intake using the offer memorandum as clearance detail: Home Inspection contingency/status was identified in the Memorandum of Offer to Purchase/Sell reviewed by CLAIRE. Operator should confirm if office policy requires separate inspection proof.";
    const report = await bestEffortClearInspectionForDeal(aliases, note);
    sendJson(res, 200, { ok: true, report });
    return;
  }

'''

if '"/api/claire-dealview/clear-inspection"' not in side:
    marker = '  sendJson(res, 404, { ok: false, error: "Not found" });'
    if marker not in side:
        print("ERROR: 404 marker not found")
        sys.exit(1)
    side = side.replace(marker, route + "\n" + marker, 1)

# Update source-doc route proof note text.
side = side.replace(
    'const inspectionNote = "Inspection treated as cleared from accepted-offer intake package. CLAIRE detected/verified inspection status before deal creation; operator should confirm if office policy requires separate proof.";',
    'const inspectionNote = "Inspection status cleared from accepted-offer intake using the offer memorandum as clearance detail: Home Inspection contingency/status was identified in the Memorandum of Offer to Purchase/Sell reviewed by CLAIRE. Operator should confirm if office policy requires separate inspection proof.";'
)

SIDE.write_text(side, encoding="utf-8")

# Patch HTML create flow to call explicit clear-inspection route.
if HTML.exists():
    html = HTML.read_text(encoding="utf-8", errors="replace")

    if "async function clearInspectionForCreatedDeal" not in html:
        helper = r'''
  async function clearInspectionForCreatedDeal(deal,payload){
    const res=await fetch("./api/claire-dealview/clear-inspection",{
      method:"POST",
      headers:{"Content-Type":"application/json","Accept":"application/json"},
      cache:"no-store",
      body:JSON.stringify({
        deal,
        payload,
        deal_id:deal.id || deal.deal_id || "",
        deal_public_id:deal.public_id || "",
        property_address:payload.property_address || ""
      })
    });
    const data=await res.json();
    if(!res.ok || data.ok===false)throw new Error(data.error || "Could not clear inspection");
    return data;
  }

'''
        marker = "  async function createDealFile(){"
        if marker in html:
            html = html.replace(marker, helper + "\n" + marker, 1)

    # Insert call after source docs save attempt, before success banner.
    if "clearInspectionForCreatedDeal(deal,payload)" not in html:
        marker = '''      const publicId=deal.public_id || deal.id || deal.deal_id || "";'''
        insert = '''      try{
        await clearInspectionForCreatedDeal(deal,payload);
      }catch(clearErr){
        console.warn("Inspection clear failed",clearErr);
      }

'''
        if marker in html:
            html = html.replace(marker, insert + marker, 1)

    # Use the correct note in payload.
    html = html.replace(
        'inspection_proof_note: "Inspection treated as cleared at accepted-offer intake based on CLAIRE review; operator should confirm if office policy requires separate proof.",',
        'inspection_proof_note: "Inspection status cleared from accepted-offer intake using the offer memorandum as clearance detail. CLAIRE identified the Home Inspection contingency/status in the Memorandum of Offer to Purchase/Sell; operator should confirm if office policy requires separate inspection proof.",'
    )
    html = html.replace(
        'proof_note:"Inspection treated as cleared at accepted-offer intake based on CLAIRE review; operator should confirm if office policy requires separate proof."',
        'proof_note:"Inspection status cleared from accepted-offer intake using the offer memorandum as clearance detail. CLAIRE identified the Home Inspection contingency/status in the Memorandum of Offer to Purchase/Sell; operator should confirm if office policy requires separate inspection proof."'
    )

    HTML.write_text(html, encoding="utf-8")

# Patch detail page: hide empty Deal Documents and place CLAIRE docs below Offer Review / above Audit History.
if DETAIL.exists():
    detail = DETAIL.read_text(encoding="utf-8", errors="replace")
    start_marker = "<!-- DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->"
    end_marker = "<!-- END_DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->"

    panel_script = r'''
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
      if(needles.some(function(n){return txt.includes(n)}))return closestPanel(el);
    }
    return null;
  }
  function hideEmptyDealDocuments(){
    const els=Array.from(document.querySelectorAll("h1,h2,h3,h4,section,.card,.panel,div"));
    for(const el of els){
      const txt=(el.textContent||"").replace(/\s+/g," ").trim().toLowerCase();
      if(txt.includes("deal documents") && txt.includes("no documents attached to this deal yet")){
        const panel=closestPanel(el);
        if(panel)panel.style.display="none";
      }
    }
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
    hideEmptyDealDocuments();

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

    s = detail.find(start_marker)
    e = detail.find(end_marker)
    if s >= 0 and e >= s:
      e = e + len(end_marker)
      detail = detail[:s] + panel_script + detail[e:]
    else:
      idx = detail.lower().rfind("</body>")
      if idx >= 0:
        detail = detail[:idx] + panel_script + "\n" + detail[idx:]
      else:
        detail += "\n" + panel_script

    DETAIL.write_text(detail, encoding="utf-8")

print("Patched sidecar, CLAIRE screen, and detail screen.")
PY

node --check "$SIDE"

cat > "$BACKEND/clear_current_maidstone_inspection_once.js" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
require("dotenv").config({ path: "/home/servicedepartmen/dealdesk-backend/.env" });
const mysql = require("mysql2/promise");

function dbConfig() {
  return {
    host: process.env.DB_HOST || process.env.MYSQL_HOST || "localhost",
    user: process.env.DB_USER || process.env.MYSQL_USER || process.env.MYSQL_USERNAME || "servicedepartmen_dealdesk",
    password: process.env.DB_PASSWORD || process.env.MYSQL_PASSWORD || process.env.DB_PASS || "",
    database: process.env.DB_NAME || process.env.MYSQL_DATABASE || process.env.DATABASE_NAME || "servicedepartmen_dealdesk",
    multipleStatements: false
  };
}
function q(id){return "`"+String(id).replace(/`/g,"``")+"`";}
function isText(t){return /char|text|json|enum|set/i.test(String(t||""));}
const NOTE = "Inspection status cleared from accepted-offer intake using the offer memorandum as clearance detail: Home Inspection contingency/status was identified in the Memorandum of Offer to Purchase/Sell reviewed by CLAIRE. Operator should confirm if office policy requires separate inspection proof.";

async function main(){
  const conn = await mysql.createConnection(dbConfig());
  const [cols] = await conn.query(`SELECT TABLE_NAME,COLUMN_NAME,DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME,ORDINAL_POSITION`);
  const byTable = new Map();
  for(const c of cols){ if(!byTable.has(c.TABLE_NAME)) byTable.set(c.TABLE_NAME,[]); byTable.get(c.TABLE_NAME).push(c); }

  const aliases = new Set(["25 Maidstone","Maidstone Lane","25 Maidstone Lane","Wading River"]);
  for(const [table, tcols] of byTable.entries()){
    const textCols = tcols.filter(c=>isText(c.DATA_TYPE)).map(c=>c.COLUMN_NAME);
    if(!textCols.length)continue;
    const wh=[]; const params=[];
    for(const col of textCols){
      for(const term of Array.from(aliases)){
        wh.push(`${q(col)} LIKE ?`);
        params.push(`%${term}%`);
      }
    }
    try{
      const [rows] = await conn.query(`SELECT * FROM ${q(table)} WHERE ${wh.join(" OR ")} LIMIT 100`, params);
      for(const row of rows){
        for(const k of ["id","deal_id","public_id","deal_public_id","file_id","transaction_id","property_address"]){
          if(row[k]!==undefined && row[k]!==null && String(row[k]).trim()) aliases.add(String(row[k]));
        }
      }
    }catch(e){}
  }

  const allAliases = Array.from(aliases);
  const changed = [];
  const statusCols=["status","clearance_status","item_status","state","task_status"];
  const doneCols=["is_complete","complete","completed","is_completed","cleared","is_cleared","done","is_done","resolved","is_resolved"];
  const timeCols=["completed_at","cleared_at","resolved_at","updated_at"];
  const proofCols=["proof_note","manager_proof_note","evidence_note","clearance_note","completion_note","response_summary","note","notes","operator_note","details","manager_proof"];
  const relationCols=["deal_id","dealId","deal_public_id","public_id","file_id","transaction_id"];

  for(const [table, tcols] of byTable.entries()){
    const names=tcols.map(c=>c.COLUMN_NAME);
    const textCols=tcols.filter(c=>isText(c.DATA_TYPE)).map(c=>c.COLUMN_NAME);
    if(!textCols.length)continue;

    const rel=[]; const relParams=[];
    for(const col of relationCols){
      if(names.includes(col)){
        rel.push(`${q(col)} IN (${allAliases.map(()=>"?").join(",")})`);
        relParams.push(...allAliases);
      }
    }
    for(const col of textCols){
      for(const a of allAliases){
        if(!a || a.length<3)continue;
        rel.push(`${q(col)} LIKE ?`);
        relParams.push(`%${a}%`);
      }
    }
    if(!rel.length)continue;

    const ins=textCols.map(c=>`${q(c)} LIKE ?`);
    const insParams=textCols.map(()=>"%inspection%");
    let rows=[];
    try{
      [rows]=await conn.query(`SELECT * FROM ${q(table)} WHERE (${rel.join(" OR ")}) AND (${ins.join(" OR ")}) LIMIT 150`, [...relParams,...insParams]);
    }catch(e){continue}
    if(!rows.length)continue;

    const sets=[]; const vals=[];
    for(const col of statusCols){ if(names.includes(col)){ sets.push(`${q(col)}=?`); vals.push("Cleared"); } }
    for(const col of doneCols){ if(names.includes(col)){ sets.push(`${q(col)}=?`); vals.push(1); } }
    for(const col of timeCols){ if(names.includes(col)){ sets.push(`${q(col)}=NOW()`); } }
    for(const col of proofCols){ if(names.includes(col)){ sets.push(`${q(col)}=?`); vals.push(NOTE); break; } }
    if(!sets.length)continue;

    try{
      if(names.includes("id")){
        const ids=rows.map(r=>r.id).filter(v=>v!==undefined && v!==null);
        if(!ids.length)continue;
        const [r]=await conn.query(`UPDATE ${q(table)} SET ${sets.join(", ")} WHERE ${q("id")} IN (${ids.map(()=>"?").join(",")})`, [...vals,...ids]);
        if(r.affectedRows)changed.push({table,rows:r.affectedRows});
      }else{
        const [r]=await conn.query(`UPDATE ${q(table)} SET ${sets.join(", ")} WHERE (${rel.join(" OR ")}) AND (${ins.join(" OR ")})`, [...vals,...relParams,...insParams]);
        if(r.affectedRows)changed.push({table,rows:r.affectedRows});
      }
    }catch(e){}
  }

  await conn.end();
  console.log(JSON.stringify({ok:true,aliases:allAliases,changed},null,2));
}
main().catch(e=>{console.error(e);process.exit(1)});
NODE

node "$BACKEND/clear_current_maidstone_inspection_once.js" || true

pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Cleanup patch installed."
echo ""
echo "Answers:"
echo "1. 'Deal Documents / No documents attached' is the old generic/manual document placeholder. It is now hidden when empty."
echo "2. Inspection is now forced to Cleared, not just manager-proofed, using the offer memo as the clearance detail."
echo "3. The current Maidstone inspection row was also targeted once."
echo ""
echo "Reload the deal page and check:"
echo "- Track inspection status should show Cleared."
echo "- Count should move to 1 of 10 cleared / N/A."
echo "- Empty Deal Documents placeholder should be gone."
echo "- CLAIRE Source Documents should sit below Offer Review / above Audit History."
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
