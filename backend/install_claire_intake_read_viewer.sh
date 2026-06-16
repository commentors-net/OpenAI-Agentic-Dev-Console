#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
CLAIRE_HTML="$APPDIR/claire-dealdesk-view.html"
DETAIL="$APPDIR/detail.html"
VIEWER="$APPDIR/claire-intake-read.html"
MANIFEST_ROOT="$APPDIR/source-docs/manifests"
CACHE_ROOT="$BACKEND/cache/claire-dealview"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/claire-intake-read-viewer-$STAMP"

mkdir -p "$BACKUP_DIR" "$MANIFEST_ROOT"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing CLAIRE Intake Read / Notes viewer..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

for f in "$SIDE" "$CLAIRE_HTML" "$DETAIL" "$VIEWER"; do
  if [ -f "$f" ]; then cp -f "$f" "$BACKUP_DIR/$(basename "$f").before-$STAMP.bak"; fi
done

cat > "$BACKEND/backfill_claire_result_into_manifests.js" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const MANIFEST_ROOT = "/home/servicedepartmen/public_html/dealdesk/source-docs/manifests";
const CACHE_ROOT = "/home/servicedepartmen/dealdesk-backend/cache/claire-dealview";
function readJson(file){ try{return JSON.parse(fs.readFileSync(file,"utf8"));}catch(e){return null;} }
function listJson(dir){ if(!fs.existsSync(dir))return []; return fs.readdirSync(dir).filter(n=>n.toLowerCase().endsWith(".json")).map(n=>path.join(dir,n)); }
const cacheByUid = new Map();
for(const file of listJson(CACHE_ROOT)){
  const data=readJson(file);
  if(data && data.uid && data.result) cacheByUid.set(String(data.uid), {result:data.result, raw_output:data.raw_output||"", cache_file:file});
}
let changed=0, inspected=0;
for(const file of listJson(MANIFEST_ROOT)){
  const m=readJson(file); if(!m)continue; inspected++;
  if(m.claire_result)continue;
  const cached=m.uid ? cacheByUid.get(String(m.uid)) : null;
  if(cached){
    m.claire_result=cached.result;
    m.claire_raw_output=cached.raw_output;
    m.claire_backup_note="Full CLAIRE intake read backfilled from sidecar cache.";
    m.claire_cache_file=cached.cache_file;
    m.updated_at=new Date().toISOString();
    fs.writeFileSync(file, JSON.stringify(m,null,2));
    changed++;
  }
}
console.log(JSON.stringify({ok:true, inspected, changed, cache_entries:cacheByUid.size}, null, 2));
NODE

node "$BACKEND/backfill_claire_result_into_manifests.js" || true

python3 - <<'PY'
from pathlib import Path

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
CLAIRE_HTML = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")
DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")

if SIDE.exists():
    side = SIDE.read_text(encoding="utf-8", errors="replace")
    if "claire_result: body.claire_result || null" not in side:
        target = "inspection_prefill: body.inspection_prefill || null"
        idx = side.find(target)
        if idx >= 0:
            end = side.find("\n", idx)
            old = side[idx:end]
            new = old.rstrip().rstrip(",") + ',\n    claire_result: body.claire_result || null,\n    claire_raw_output: body.claire_raw_output || null,\n    claire_backup_note: "Full CLAIRE intake read preserved here; Additional Terms remains short."'
            side = side[:idx] + new + side[end:]
            print("Added claire_result to future source-doc manifests.")
        else:
            print("WARNING: could not find manifest save block.")
    SIDE.write_text(side, encoding="utf-8")

if CLAIRE_HTML.exists():
    html = CLAIRE_HTML.read_text(encoding="utf-8", errors="replace")
    if "claire_result: normalizeClaireResult((lastResult&&lastResult.result)||{})" not in html:
        target = "property_address:payload.property_address,"
        if target in html:
            html = html.replace(target, target + "\n      claire_result: normalizeClaireResult((lastResult&&lastResult.result)||{}),\n      claire_raw_output: (lastResult&&lastResult.raw_output)||'',", 1)
            print("Added CLAIRE result to future save-source-doc requests.")
    CLAIRE_HTML.write_text(html, encoding="utf-8")

if DETAIL.exists():
    detail = DETAIL.read_text(encoding="utf-8", errors="replace")
    start = "<!-- DEALDESK_CLAIRE_INTAKE_READ_LINK_V1 -->"
    end = "<!-- END_DEALDESK_CLAIRE_INTAKE_READ_LINK_V1 -->"
    while True:
        s = detail.find(start); e = detail.find(end)
        if s >= 0 and e >= s:
            detail = detail[:s] + detail[e+len(end):]
        else:
            break
    snippet = r'''
<!-- DEALDESK_CLAIRE_INTAKE_READ_LINK_V1 -->
<script>
(function(){
  function dealIdFromUrl(){
    const u=new URL(location.href);
    return u.searchParams.get("id") || u.searchParams.get("deal_id") || u.searchParams.get("public_id") || "";
  }
  function closestPanel(el){return el && (el.closest("section,.card,.panel,.deal-section,.detail-section,[class*='card'],[class*='panel'],[class*='section']") || el.parentElement)}
  function findPanelByText(needles){
    const els=Array.from(document.querySelectorAll("h1,h2,h3,h4,button,a,section,.card,.panel,div"));
    for(const el of els){
      const txt=(el.textContent||"").replace(/\s+/g," ").trim().toLowerCase();
      if(txt && needles.some(n=>txt.includes(n)))return closestPanel(el);
    }
    return null;
  }
  function addLink(){
    const id=dealIdFromUrl(); if(!id)return;
    if(document.getElementById("claire-intake-read-link-card"))return;
    const card=document.createElement("section");
    card.id="claire-intake-read-link-card";
    card.className="card";
    card.style.cssText="margin:16px 0;padding:14px 16px;border:1px solid #dbe5ef;border-radius:14px;background:#fff;font-family:Arial,Helvetica,sans-serif;";
    card.innerHTML='<div style="font-weight:900;margin-bottom:6px;">CLAIRE Intake Read</div><div style="color:#526274;margin-bottom:10px;">Full CLAIRE document read, notes, flags, missing items, and conflicts preserved from intake.</div><a style="display:inline-block;padding:10px 12px;border-radius:10px;background:#0f766e;color:white;text-decoration:none;font-weight:900;" href="./claire-intake-read.html?id='+encodeURIComponent(id)+'">View CLAIRE Intake Read / Notes</a>';
    const source=document.querySelector(".claire-pdf-source-links-card,.claire-source-docs-card,#accepted-offer-source-documents");
    if(source && source.parentNode){source.insertAdjacentElement("afterend",card);return;}
    const remove=findPanelByText(["remove accepted offer","delete accepted offer","remove offer"]);
    if(remove && remove.parentNode){remove.parentNode.insertBefore(card,remove);return;}
    (document.querySelector("main")||document.body).appendChild(card);
  }
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",addLink); else addLink();
  setTimeout(addLink,1000);
})();
</script>
<!-- END_DEALDESK_CLAIRE_INTAKE_READ_LINK_V1 -->
'''
    idx = detail.lower().rfind("</body>")
    detail = detail[:idx] + snippet + "\n" + detail[idx:] if idx >= 0 else detail + "\n" + snippet
    DETAIL.write_text(detail, encoding="utf-8")
    print("Added viewer link to detail page.")
PY

cat > "$VIEWER" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CLAIRE Intake Read / Notes</title>
<style>
:root{--ink:#071b2c;--muted:#66758a;--line:#dbe5ef;--bg:#f4f7fb;--card:#fff;--teal:#0f766e}
body{margin:0;background:var(--bg);font-family:Arial,Helvetica,sans-serif;color:var(--ink)}
.wrap{max-width:1180px;margin:0 auto;padding:24px}.top{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;margin-bottom:18px}
h1{margin:0;font-size:28px}.sub{color:var(--muted);margin-top:6px;line-height:1.4}.btn{display:inline-block;border:1px solid var(--line);background:white;color:var(--ink);text-decoration:none;border-radius:10px;padding:10px 12px;font-weight:800}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:0 10px 26px rgba(15,35,55,.06);overflow:hidden;margin:16px 0}.hd{padding:14px 16px;background:#f8fbfe;border-bottom:1px solid var(--line);font-weight:900}.bd{padding:16px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}@media(max-width:850px){.grid{grid-template-columns:1fr}.top{display:block}.top .btn{margin-top:12px}}
ul{margin:8px 0 0 20px;padding:0}li{margin:5px 0;line-height:1.4}.doc{display:block;padding:11px 12px;border:1px solid var(--line);border-radius:10px;text-decoration:none;color:var(--ink);font-weight:800;margin:8px 0;background:white}.muted{color:var(--muted)}
pre{white-space:pre-wrap;word-break:break-word;background:#071b2c;color:#eaf2f8;border-radius:12px;padding:14px;max-height:520px;overflow:auto}.pill{display:inline-block;border:1px solid #99f6e4;background:#ecfdf5;color:#115e59;border-radius:999px;padding:4px 8px;font-size:12px;font-weight:900;margin-left:8px}.warn{border-color:#f7d08a;background:#fff8e6}
</style>
</head>
<body><div class="wrap">
<div class="top"><div><h1>CLAIRE Intake Read / Notes</h1><div class="sub">Full document read preserved from the accepted-offer email. Additional Terms stays short; this page keeps the deeper read.</div></div><a id="backLink" class="btn" href="./dashboard.html">Back to Deal Desk</a></div>
<div id="status" class="card"><div class="bd muted">Loading CLAIRE intake read...</div></div><div id="content"></div>
</div>
<script>
const $=id=>document.getElementById(id);
function esc(s){return String(s||"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[c]))}
function param(name){return new URL(location.href).searchParams.get(name)||""}
function dealId(){return param("id")||param("deal_id")||param("public_id")||param("property")||""}
function list(title, arr){if(!Array.isArray(arr)||!arr.length)return "";return `<div class="card"><div class="hd">${esc(title)} <span class="pill">${arr.length}</span></div><div class="bd"><ul>${arr.map(x=>`<li>${esc(x)}</li>`).join("")}</ul></div></div>`}
function kv(title, obj){if(!obj||typeof obj!=="object")return "";const rows=Object.entries(obj).filter(([k,v])=>v!==null&&v!==undefined&&String(v).trim()!==""&&typeof v!=="object");if(!rows.length)return "";return `<div class="card"><div class="hd">${esc(title)}</div><div class="bd">${rows.map(([k,v])=>`<div><strong>${esc(k.replaceAll("_"," "))}:</strong> ${esc(v)}</div>`).join("")}</div></div>`}
function docsHtml(docs){docs=docs||[];if(!docs.length)return `<div class="card warn"><div class="hd">Source Documents</div><div class="bd">No PDF source documents found in this manifest.</div></div>`;return `<div class="card"><div class="hd">Source Documents</div><div class="bd">${docs.map(d=>`<a class="doc" target="_blank" rel="noopener" href="${esc(d.url)}">${esc(d.filename||d.stored_filename||"Document")}</a>`).join("")}</div></div>`}
function readHtml(data){
  const r=data.claire_result||data.result||{}; const f=r.dealdesk_fields||{}; let html=docsHtml(data.source_documents||[]);
  if(!data.claire_result&&!data.result){html+=`<div class="card warn"><div class="hd">Full CLAIRE Read Not Found</div><div class="bd">The PDFs may exist, but the verbose CLAIRE read was not saved into this deal's manifest. For future deals this page will preserve it automatically. For this one, use the CLAIRE reader Raw JSON tab if the read is still on screen.</div></div><div class="card"><div class="hd">Manifest JSON</div><div class="bd"><pre>${esc(JSON.stringify(data,null,2))}</pre></div></div>`;return html;}
  html+=`<div class="card"><div class="hd">Executive Read</div><div class="bd">${r.operator_summary?`<p><strong>Summary:</strong> ${esc(r.operator_summary)}</p>`:""}${r.recommended_next_action?`<p><strong>Recommended next action:</strong> ${esc(r.recommended_next_action)}</p>`:""}</div></div>`;
  html+=`<div class="grid"><div>${list("Notes",f.notes||r.notes)}${list("Missing Items",f.missing_items||r.missing_items)}</div><div>${list("Review Flags",f.review_flags||r.review_flags)}${list("Conflicts",f.conflicts||r.conflicts)}</div></div>`;
  html+=`<div class="grid"><div>${kv("Property",f.property)}${kv("Seller",f.seller)}${kv("Purchaser",f.purchaser)}${kv("Financial Terms",f.financial_terms)}</div><div>${kv("Attorneys",f.attorneys)}${kv("Financing",f.financing)}${kv("Listing Side",f.listing_side)}${kv("Buyer Side",f.buyer_side)}</div></div>`;
  html+=`<div class="card"><div class="hd">Raw CLAIRE JSON</div><div class="bd"><details><summary style="cursor:pointer;font-weight:900;">Open raw JSON</summary><pre>${esc(JSON.stringify(r,null,2))}</pre></details></div></div>`;
  return html;
}
async function load(){
  const id=dealId(); $("backLink").href=id?`./detail.html?id=${encodeURIComponent(id)}`:"./dashboard.html";
  if(!id){$("status").innerHTML='<div class="bd">No deal id supplied. Open this page from a deal detail screen.</div>';return}
  try{const res=await fetch(`./api/claire-dealview/source-docs?deal_id=${encodeURIComponent(id)}`,{headers:{Accept:"application/json"},cache:"no-store"});const data=await res.json();$("status").style.display="none";$("content").innerHTML=readHtml(data)}
  catch(e){$("status").innerHTML='<div class="bd">Could not load CLAIRE intake read: '+esc(e.message||e)+'</div>'}
}
load();
</script></body></html>
HTML

node --check "$SIDE" 2>/dev/null || {
  echo "WARNING: node --check failed. Restoring sidecar backup."
  cp -f "$BACKUP_DIR/claire_dealview_sidecar.js.before-$STAMP.bak" "$SIDE"
  node --check "$SIDE"
}

pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "CLAIRE Intake Read viewer installed."
echo ""
echo "Where the verbose read lives:"
echo "1. For newly created deals, in the source-doc manifest under claire_result."
echo "2. On the detail page, use the new View CLAIRE Intake Read / Notes link."
echo "3. Direct URL format:"
echo "https://servicedepartment.ai/dealdesk/claire-intake-read.html?id=DEAL_ID"
echo ""
echo "Backfill attempted from cache by email UID."
echo "If an existing deal says Full CLAIRE Read Not Found, it was created before the read was preserved."
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
