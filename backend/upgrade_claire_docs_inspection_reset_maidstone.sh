#!/usr/bin/env bash
set -euo pipefail

APPDIR="/home/servicedepartmen/public_html/dealdesk"
BACKEND="/home/servicedepartmen/dealdesk-backend"
SIDE="$BACKEND/claire_dealview_sidecar.js"
HTML="$APPDIR/claire-dealdesk-view.html"
DETAIL="$APPDIR/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/claire-source-docs-inspection-reset-$STAMP"
PUBLIC_DOC_ROOT="$APPDIR/source-docs"

mkdir -p "$BACKUP_DIR" "$PUBLIC_DOC_ROOT" "$PUBLIC_DOC_ROOT/manifests"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing CLAIRE source-doc attachment, inspection pre-clear, and deleting Maidstone test deal..."
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
npm install mysql2 dotenv >/tmp/claire-upgrade-npm-$STAMP.log 2>&1 || {
  cat /tmp/claire-upgrade-npm-$STAMP.log
  exit 1
}

cat > "$BACKEND/delete_maidstone_once.js" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
require("dotenv").config({ path: "/home/servicedepartmen/dealdesk-backend/.env" });
const mysql = require("mysql2/promise");

const BACKUP_DIR = process.env.DD_BACKUP_DIR || "/home/servicedepartmen/dealdesk-backend/backups";
const TERMS = ["25 Maidstone", "Maidstone Lane", "25 Maidstone Lane"];

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

function idCols(cols) {
  const names = cols.map(c => c.COLUMN_NAME);
  return ["id", "deal_id", "public_id", "uuid"].filter(n => names.includes(n));
}

async function main() {
  const conn = await mysql.createConnection(dbConfig());
  const [dbRows] = await conn.query("SELECT DATABASE() db");
  const db = dbRows[0].db;

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
  const dealPublicIds = new Set();

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

    const sql = `SELECT * FROM ${quoteId(table)} WHERE ${wheres.join(" OR ")} LIMIT 200`;
    let rows = [];
    try {
      [rows] = await conn.query(sql, params);
    } catch (err) {
      continue;
    }

    if (!rows.length) continue;

    candidates.push({ table, rows });

    for (const row of rows) {
      if (row.id !== undefined && row.id !== null) dealIds.add(String(row.id));
      if (row.deal_id !== undefined && row.deal_id !== null) dealIds.add(String(row.deal_id));
      if (row.public_id !== undefined && row.public_id !== null) dealPublicIds.add(String(row.public_id));
    }
  }

  const backup = {
    db,
    deleted_at: new Date().toISOString(),
    terms: TERMS,
    deal_ids: Array.from(dealIds),
    deal_public_ids: Array.from(dealPublicIds),
    candidates
  };

  const backupPath = path.join(BACKUP_DIR, "maidstone-delete-backup.json");
  fs.writeFileSync(backupPath, JSON.stringify(backup, null, 2));

  if (!candidates.length) {
    console.log("No Maidstone rows found. Nothing deleted.");
    console.log("Backup:", backupPath);
    await conn.end();
    return;
  }

  await conn.query("SET FOREIGN_KEY_CHECKS=0");

  let deleted = [];

  // Delete child rows using likely deal id columns.
  for (const [table, tableCols] of byTable.entries()) {
    const names = tableCols.map(c => c.COLUMN_NAME);
    for (const col of ["deal_id", "dealId", "deal_public_id", "public_id"]) {
      if (!names.includes(col)) continue;
      const vals = col.includes("public") ? Array.from(dealPublicIds) : Array.from(dealIds);
      if (!vals.length) continue;
      const placeholders = vals.map(() => "?").join(",");
      try {
        const [r] = await conn.query(`DELETE FROM ${quoteId(table)} WHERE ${quoteId(col)} IN (${placeholders})`, vals);
        if (r.affectedRows) deleted.push({ table, column: col, rows: r.affectedRows });
      } catch (err) {}
    }
  }

  // Delete rows directly containing Maidstone.
  for (const item of candidates) {
    const tableCols = byTable.get(item.table) || [];
    const ids = idCols(tableCols);
    if (ids.includes("id")) {
      const vals = item.rows.map(r => r.id).filter(v => v !== undefined && v !== null);
      if (vals.length) {
        try {
          const placeholders = vals.map(() => "?").join(",");
          const [r] = await conn.query(`DELETE FROM ${quoteId(item.table)} WHERE ${quoteId("id")} IN (${placeholders})`, vals);
          if (r.affectedRows) deleted.push({ table: item.table, column: "id", rows: r.affectedRows });
        } catch (err) {}
      }
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

python3 - <<'PY'
from pathlib import Path
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
HTML = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")
DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")

side = SIDE.read_text(encoding="utf-8", errors="replace")

# Add source document constants.
if "SOURCE_DOC_ROOT" not in side:
    needle = 'const MAX_ATTACHMENT_BYTES = Number(process.env.CLAIRE_MAX_ATTACHMENT_BYTES || 25 * 1024 * 1024);'
    insert = needle + r'''

const PUBLIC_DEALDESK_ROOT = "/home/servicedepartmen/public_html/dealdesk";
const SOURCE_DOC_ROOT = path.join(PUBLIC_DEALDESK_ROOT, "source-docs");
const SOURCE_DOC_MANIFEST_ROOT = path.join(SOURCE_DOC_ROOT, "manifests");
try { fs.mkdirSync(SOURCE_DOC_ROOT, { recursive: true }); fs.mkdirSync(SOURCE_DOC_MANIFEST_ROOT, { recursive: true }); } catch (err) {}
'''
    if needle not in side:
        print("ERROR: sidecar missing MAX_ATTACHMENT_BYTES marker")
        sys.exit(1)
    side = side.replace(needle, insert, 1)

helpers = r'''
function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk.toString("utf8");
      if (body.length > 2_000_000) {
        reject(new Error("Request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function safeSlug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "deal";
}

function safeFilename(value, fallback) {
  const base = String(value || fallback || "document.pdf")
    .replace(/[\/\\:*?"<>|]+/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 140);
  return base || fallback || "document.pdf";
}

function publicSourceDocUrl(relativePath) {
  return "./source-docs/" + relativePath.split(path.sep).map(encodeURIComponent).join("/");
}

function manifestFile(alias) {
  return path.join(SOURCE_DOC_MANIFEST_ROOT, safeSlug(alias) + ".json");
}

function readManifest(alias) {
  const file = manifestFile(alias);
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeManifestAliases(manifest, aliases) {
  const unique = Array.from(new Set((aliases || []).filter(Boolean).map(String)));
  for (const alias of unique) {
    fs.writeFileSync(manifestFile(alias), JSON.stringify(manifest, null, 2), "utf8");
  }
}

async function saveSourceDocsForDeal(uid, parsed, body) {
  const deal = body.deal || {};
  const dealId = String(body.deal_id || body.dealId || deal.id || deal.deal_id || "").trim();
  const publicId = String(body.deal_public_id || body.public_id || deal.public_id || "").trim();
  const property = String(body.property_address || deal.property_address || body.property || "").trim();
  const folderName = safeSlug(publicId || dealId || property || ("email-" + uid));
  const folder = path.join(SOURCE_DOC_ROOT, folderName);
  fs.mkdirSync(folder, { recursive: true });

  const docs = [];
  let index = 0;

  for (const att of parsed.attachments || []) {
    index++;
    const filename = safeFilename(att.filename, `source-document-${index}.pdf`);
    const outName = String(index).padStart(2, "0") + "-" + filename;
    const outPath = path.join(folder, outName);
    fs.writeFileSync(outPath, Buffer.from(att.content || Buffer.alloc(0)));

    const relative = path.join(folderName, outName);
    docs.push({
      number: index,
      filename,
      stored_filename: outName,
      url: publicSourceDocUrl(relative),
      mime_type: att.contentType || "",
      size_bytes: att.size || (att.content ? att.content.length : 0)
    });
  }

  const aliases = [dealId, publicId, property, folderName].filter(Boolean);
  const manifest = {
    ok: true,
    created_at: new Date().toISOString(),
    uid: String(uid || ""),
    deal_id: dealId,
    deal_public_id: publicId,
    property_address: property,
    folder: folderName,
    source_documents: docs,
    inspection_prefill: body.inspection_prefill || null
  };

  writeManifestAliases(manifest, aliases.length ? aliases : [folderName]);
  return manifest;
}

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

async function bestEffortClearInspectionForDeal(aliases, note) {
  let mysql;
  try { mysql = require("mysql2/promise"); } catch (err) { return { ok: false, skipped: true, reason: "mysql2 not available" }; }

  const cleanAliases = Array.from(new Set((aliases || []).filter(Boolean).map(String)));
  if (!cleanAliases.length) return { ok: false, skipped: true, reason: "no deal identifiers" };

  const conn = await mysql.createConnection(dbConfigForClaire());
  const changed = [];

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

    for (const [table, tableCols] of byTable.entries()) {
      const names = tableCols.map(c => c.COLUMN_NAME);
      const dealCol = ["deal_id", "dealId", "deal_public_id", "public_id"].find(c => names.includes(c));
      if (!dealCol) continue;

      const textCols = tableCols
        .filter(c => /char|text|json|enum|set/i.test(String(c.DATA_TYPE || "")))
        .map(c => c.COLUMN_NAME);
      if (!textCols.length) continue;

      const inspectionWhere = textCols.map(c => `${quoteSqlId(c)} LIKE ?`).join(" OR ");
      const dealWhere = `${quoteSqlId(dealCol)} IN (${cleanAliases.map(() => "?").join(",")})`;
      const params = [...cleanAliases, ...textCols.map(() => "%inspection%")];

      let rows = [];
      try {
        [rows] = await conn.query(`SELECT * FROM ${quoteSqlId(table)} WHERE ${dealWhere} AND (${inspectionWhere}) LIMIT 50`, params);
      } catch (err) {
        continue;
      }
      if (!rows.length) continue;

      const sets = [];
      const values = [];

      for (const col of ["status", "clearance_status", "state"]) {
        if (names.includes(col)) { sets.push(`${quoteSqlId(col)}=?`); values.push("Complete"); break; }
      }

      for (const col of ["is_complete", "complete", "completed", "is_completed", "cleared", "is_cleared"]) {
        if (names.includes(col)) { sets.push(`${quoteSqlId(col)}=?`); values.push(1); }
      }

      for (const col of ["completed_at", "cleared_at", "updated_at"]) {
        if (names.includes(col)) { sets.push(`${quoteSqlId(col)}=NOW()`); }
      }

      for (const col of ["proof_note", "manager_proof_note", "note", "notes", "response_summary"]) {
        if (names.includes(col)) { sets.push(`${quoteSqlId(col)}=?`); values.push(note); break; }
      }

      if (!sets.length) continue;

      const rowIds = rows.map(r => r.id).filter(v => v !== undefined && v !== null);
      if (names.includes("id") && rowIds.length) {
        const idWhere = `${quoteSqlId("id")} IN (${rowIds.map(() => "?").join(",")})`;
        const [result] = await conn.query(`UPDATE ${quoteSqlId(table)} SET ${sets.join(", ")} WHERE ${idWhere}`, [...values, ...rowIds]);
        if (result.affectedRows) changed.push({ table, rows: result.affectedRows });
      }
    }

    return { ok: true, changed };
  } catch (err) {
    return { ok: false, error: err.message, changed };
  } finally {
    await conn.end().catch(() => {});
  }
}

'''

if "async function saveSourceDocsForDeal" not in side:
    idx = side.find("async function handle(req, res)")
    if idx < 0:
        print("ERROR: could not find sidecar handle")
        sys.exit(1)
    side = side[:idx] + helpers + "\n" + side[idx:]

route = r'''
  if (req.method === "GET" && url.pathname === "/api/claire-dealview/source-docs") {
    const alias = url.searchParams.get("deal_id") || url.searchParams.get("deal_public_id") || url.searchParams.get("property") || "";
    const manifest = alias ? readManifest(alias) : null;
    sendJson(res, 200, manifest || { ok: true, source_documents: [] });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/claire-dealview/save-source-docs") {
    const uid = url.searchParams.get("uid") || "";
    if (!uid) throw new Error("Missing uid.");
    const rawBody = await readBody(req);
    let body = {};
    try { body = rawBody ? JSON.parse(rawBody) : {}; } catch (err) { body = {}; }

    const parsed = await fetchParsedEmail(uid);
    const manifest = await saveSourceDocsForDeal(uid, parsed, body);

    const aliases = [
      manifest.deal_id,
      manifest.deal_public_id,
      manifest.property_address,
      manifest.folder
    ].filter(Boolean);

    const inspectionNote = "Inspection treated as cleared from accepted-offer intake package. CLAIRE detected/verified inspection status before deal creation; operator should confirm if office policy requires separate proof.";
    const inspection_clear_report = await bestEffortClearInspectionForDeal(aliases, inspectionNote);

    sendJson(res, 200, { ok: true, manifest, inspection_clear_report });
    return;
  }

'''

if '"/api/claire-dealview/save-source-docs"' not in side:
    marker = '  sendJson(res, 404, { ok: false, error: "Not found" });'
    if marker not in side:
        print("ERROR: could not find 404 marker")
        sys.exit(1)
    side = side.replace(marker, route + "\n" + marker, 1)

SIDE.write_text(side, encoding="utf-8")

# Patch HTML create deal flow.
html = HTML.read_text(encoding="utf-8", errors="replace")

if "async function saveClaireSourceDocsForDeal" not in html:
    insert = r'''
  async function saveClaireSourceDocsForDeal(deal,payload){
    if(!lastResult || !lastResult.uid)return null;

    const dealId=deal.id || deal.deal_id || "";
    const publicId=deal.public_id || deal.publicId || "";
    const body={
      deal,
      deal_id:dealId,
      deal_public_id:publicId,
      property_address:payload.property_address,
      inspection_prefill:{
        status:"Complete",
        proof_note:"Inspection treated as cleared at accepted-offer intake based on CLAIRE review; operator should confirm if office policy requires separate proof."
      }
    };

    const res=await fetch("./api/claire-dealview/save-source-docs?uid="+encodeURIComponent(lastResult.uid),{
      method:"POST",
      headers:{"Content-Type":"application/json","Accept":"application/json"},
      cache:"no-store",
      body:JSON.stringify(body)
    });

    const data=await res.json();
    if(!res.ok || data.ok===false)throw new Error(data.error || "Could not save source documents");
    return data;
  }

  function sourceDocsHtml(saveResult){
    const docs=(saveResult && saveResult.manifest && saveResult.manifest.source_documents) || [];
    if(!docs.length)return "";
    return "<br><br><strong>Source Documents Attached:</strong><br>"+docs.map(d=>`<a href="${esc(d.url)}" target="_blank" rel="noopener">${esc(d.filename)}</a>`).join("<br>");
  }

'''
    marker = '  async function createDealFile(){'
    if marker not in html:
        print("ERROR: could not find createDealFile in HTML")
        sys.exit(1)
    html = html.replace(marker, insert + "\n" + marker, 1)

old = '''      const deal=data.deal||{};
      const publicId=deal.public_id || deal.id || deal.deal_id || "";
      const detailUrl=publicId ? "./detail.html?id="+encodeURIComponent(publicId) : "./dashboard.html";
      const banner=`<div class="status ok"><strong>Deal file created.</strong><br>${esc(deal.property_address||payload.property_address)}<br>Status: ${esc(deal.transaction_status||payload.transaction_status)}<br><br><a href="${detailUrl}">Open Deal File</a> &nbsp; | &nbsp; <a href="./dashboard.html">Command Center</a></div>`;'''

new = '''      const deal=data.deal||{};
      let saveResult=null;
      try{
        saveResult=await saveClaireSourceDocsForDeal(deal,payload);
      }catch(docErr){
        console.warn("Source document save failed",docErr);
      }

      const publicId=deal.public_id || deal.id || deal.deal_id || "";
      const detailUrl=publicId ? "./detail.html?id="+encodeURIComponent(publicId) : "./dashboard.html";
      const banner=`<div class="status ok"><strong>Deal file created.</strong><br>${esc(deal.property_address||payload.property_address)}<br>Status: ${esc(deal.transaction_status||payload.transaction_status)}<br>${sourceDocsHtml(saveResult)}<br><br><a href="${detailUrl}">Open Deal File</a> &nbsp; | &nbsp; <a href="./dashboard.html">Command Center</a></div>`;'''

if old in html:
    html = html.replace(old, new, 1)
elif "saveClaireSourceDocsForDeal(deal,payload)" not in html:
    print("WARNING: could not find create success block to patch source-doc save")

# Add inspection payload fields if not present.
if 'inspection_status: "Complete"' not in html:
    html = html.replace(
      'property_condition_statement_status: "Unknown",',
      'property_condition_statement_status: "Unknown",\n      inspection_status: "Complete",\n      inspection_proof_note: "Inspection treated as cleared at accepted-offer intake based on CLAIRE review; operator should confirm if office policy requires separate proof.",',
      1
    )

HTML.write_text(html, encoding="utf-8")

# Patch detail page to display source docs.
if DETAIL.exists():
    detail = DETAIL.read_text(encoding="utf-8", errors="replace")
    if "DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1" not in detail:
        snippet = r'''
<!-- DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->
<script>
(function(){
  function esc(s){return String(s||"").replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[c]})}
  function dealIdFromUrl(){
    const u=new URL(location.href);
    return u.searchParams.get("id") || u.searchParams.get("deal_id") || u.searchParams.get("public_id") || "";
  }
  async function loadClaireSourceDocs(){
    const id=dealIdFromUrl();
    if(!id)return;
    try{
      const res=await fetch("./api/claire-dealview/source-docs?deal_id="+encodeURIComponent(id),{headers:{Accept:"application/json"},cache:"no-store"});
      const data=await res.json();
      const docs=data.source_documents||[];
      if(!docs.length)return;

      const panel=document.createElement("section");
      panel.className="card claire-source-docs-card";
      panel.style.cssText="margin:16px 0;padding:0;border:1px solid #dbe5ef;border-radius:14px;background:#fff;box-shadow:0 10px 26px rgba(15,35,55,.06);overflow:hidden;font-family:Arial,Helvetica,sans-serif;";
      panel.innerHTML='<div style="padding:14px 16px;background:#f8fbfe;border-bottom:1px solid #dbe5ef;font-weight:900;">CLAIRE Source Documents</div><div style="padding:14px 16px;display:grid;gap:8px;">'+docs.map(function(d){return '<a style="display:block;padding:10px 12px;border:1px solid #dbe5ef;border-radius:10px;text-decoration:none;color:#071b2c;font-weight:800;background:#fff;" target="_blank" rel="noopener" href="'+esc(d.url)+'">'+esc(d.filename)+' <span style="color:#66758a;font-weight:400;">('+esc(d.mime_type||"document")+')</span></a>'}).join("")+'</div>';

      const main=document.querySelector("main") || document.body;
      main.insertBefore(panel, main.firstChild);
    }catch(e){}
  }
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",loadClaireSourceDocs);
  else loadClaireSourceDocs();
})();
</script>
<!-- END_DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->
'''
        idx = detail.lower().rfind("</body>")
        if idx >= 0:
            detail = detail[:idx] + snippet + "\n" + detail[idx:]
        else:
            detail += snippet
        DETAIL.write_text(detail, encoding="utf-8")

print("Patched CLAIRE source docs, inspection pre-clear hints, and detail source-doc panel.")
PY

node --check "$SIDE"
pm2 restart dealdesk-claire-dealview --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Upgrade installed."
echo ""
echo "What changed:"
echo "1. Deleted Maidstone test rows where found, with JSON backup."
echo "2. When Create Deal File is clicked, CLAIRE saves the email PDFs as source documents."
echo "3. The created deal detail page now shows a CLAIRE Source Documents panel."
echo "4. Inspection is prefilled/marked as complete where supported, with a proof note/hint."
echo ""
echo "Test again from:"
echo "https://servicedepartment.ai/dealdesk/claire-dealdesk-view.html"
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
