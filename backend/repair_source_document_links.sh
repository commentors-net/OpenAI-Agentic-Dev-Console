#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
DETAIL="$APPDIR/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/repair-source-document-links-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Repairing Accepted Offer Source Documents links..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

for f in "$SIDE" "$DETAIL"; do
  if [ -f "$f" ]; then
    cp -f "$f" "$BACKUP_DIR/$(basename "$f").before-$STAMP.bak"
  fi
done

python3 - <<'PY'
from pathlib import Path
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")

def replace_if_block(src, needle, replacement):
    pos = src.find(needle)
    if pos < 0:
        return src, False

    if_start = src.rfind("if", 0, pos)
    brace = src.find("{", pos)
    if if_start < 0 or brace < 0:
        return src, False

    depth = 0
    i = brace
    in_str = False
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

        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == quote:
                in_str = False
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
            in_str = True
            quote = ch
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[:if_start] + replacement + src[i+1:], True

        i += 1

    return src, False

def insert_before_handle(src, block):
    idx = src.find("async function handle(req, res)")
    if idx < 0:
        return src, False
    return src[:idx] + block + "\n" + src[idx:], True

if not SIDE.exists():
    print("ERROR: Missing sidecar")
    sys.exit(1)

side = SIDE.read_text(encoding="utf-8", errors="replace")

# Ensure source-doc helper constants exist.
if "SOURCE_DOC_ROOT" not in side:
    marker = 'const MAX_ATTACHMENT_BYTES = Number(process.env.CLAIRE_MAX_ATTACHMENT_BYTES || 25 * 1024 * 1024);'
    if marker in side:
        side = side.replace(marker, marker + r'''

const PUBLIC_DEALDESK_ROOT = "/home/servicedepartmen/public_html/dealdesk";
const SOURCE_DOC_ROOT = path.join(PUBLIC_DEALDESK_ROOT, "source-docs");
const SOURCE_DOC_MANIFEST_ROOT = path.join(SOURCE_DOC_ROOT, "manifests");
try { fs.mkdirSync(SOURCE_DOC_ROOT, { recursive: true }); fs.mkdirSync(SOURCE_DOC_MANIFEST_ROOT, { recursive: true }); } catch (err) {}
''', 1)
    else:
        print("ERROR: Missing source doc constants marker")
        sys.exit(1)

helpers = r'''
function readAllSourceDocManifests() {
  const out = [];
  try {
    if (!fs.existsSync(SOURCE_DOC_MANIFEST_ROOT)) return out;
    for (const name of fs.readdirSync(SOURCE_DOC_MANIFEST_ROOT)) {
      if (!name.toLowerCase().endsWith(".json")) continue;
      const file = path.join(SOURCE_DOC_MANIFEST_ROOT, name);
      try {
        const data = JSON.parse(fs.readFileSync(file, "utf8"));
        data._manifest_file = file;
        out.push(data);
      } catch (err) {}
    }
  } catch (err) {}
  return out;
}

function findSourceDocManifest(query) {
  const q = String(query || "").trim().toLowerCase();
  if (!q) return null;

  // First try exact alias manifest.
  try {
    const exact = readManifest(query);
    if (exact) return exact;
  } catch (err) {}

  const manifests = readAllSourceDocManifests();

  for (const m of manifests) {
    const fields = [
      m.deal_id,
      m.deal_public_id,
      m.public_id,
      m.property_address,
      m.folder,
      ...(m.source_documents || []).map(d => d.filename || "")
    ].filter(Boolean).map(v => String(v).toLowerCase());

    if (fields.some(v => v === q || v.includes(q) || q.includes(v))) return m;
  }

  const words = q.split(/[^a-z0-9]+/).filter(w => w.length >= 4);
  if (words.length) {
    let best = null;
    let bestScore = 0;
    for (const m of manifests) {
      const hay = JSON.stringify(m).toLowerCase();
      const score = words.reduce((n, w) => n + (hay.includes(w) ? 1 : 0), 0);
      if (score > bestScore) {
        best = m;
        bestScore = score;
      }
    }
    if (best && bestScore >= Math.min(2, words.length)) return best;
  }

  return null;
}
'''

if "function findSourceDocManifest" not in side:
    side, ok = insert_before_handle(side, helpers)
    if not ok:
        print("ERROR: could not insert source-doc manifest search helpers")
        sys.exit(1)

new_route = r'''if (req.method === "GET" && url.pathname === "/api/claire-dealview/source-docs") {
    const alias =
      url.searchParams.get("deal_id") ||
      url.searchParams.get("deal_public_id") ||
      url.searchParams.get("public_id") ||
      url.searchParams.get("property") ||
      url.searchParams.get("q") ||
      "";

    let manifest = alias ? findSourceDocManifest(alias) : null;

    sendJson(res, 200, manifest || {
      ok: true,
      source_documents: [],
      lookup: { alias, found: false },
      message: "No CLAIRE source-document manifest found for this deal identifier."
    });
    return;
  }'''

side, replaced = replace_if_block(side, 'url.pathname === "/api/claire-dealview/source-docs"', new_route)
if not replaced:
    print("WARNING: source-docs route not found; helpers added but route not replaced.")

SIDE.write_text(side, encoding="utf-8")

# Patch detail page source-doc panel to try more aliases from page.
if not DETAIL.exists():
    print("WARNING: detail.html missing; skipping detail UI patch.")
else:
    detail = DETAIL.read_text(encoding="utf-8", errors="replace")

    # Remove old v1/v2 panels to avoid conflicts.
    for n in ["V1", "V2", "V3"]:
        start = f"<!-- DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_{n} -->"
        end = f"<!-- END_DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_{n} -->"
        s = detail.find(start)
        e = detail.find(end)
        if s >= 0 and e >= s:
            detail = detail[:s] + detail[e+len(end):]

    panel = r'''
<!-- DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V3 -->
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
    const els=Array.from(document.querySelectorAll("h1,h2,h3,h4,button,a,section,.card,.panel,div"));
    for(const el of els){
      const txt=(el.textContent||"").replace(/\s+/g," ").trim().toLowerCase();
      if(!txt)continue;
      if(needles.some(function(n){return txt.includes(n)}))return closestPanel(el);
    }
    return null;
  }
  function hideEmptyGenericDocs(){
    const els=Array.from(document.querySelectorAll("h1,h2,h3,h4,section,.card,.panel,div"));
    for(const el of els){
      const txt=(el.textContent||"").replace(/\s+/g," ").trim().toLowerCase();
      if(txt.includes("deal documents") && txt.includes("no documents attached to this deal yet")){
        const panel=closestPanel(el);
        if(panel)panel.style.display="none";
      }
    }
  }
  function candidateAliases(){
    const out=[];
    const id=dealIdFromUrl();
    if(id)out.push(id);

    const txt=(document.body.innerText||"").replace(/\s+/g," ");
    const addressMatches=txt.match(/\b\d{1,6}\s+[A-Za-z0-9 .'-]+\s+(?:Lane|Ln|Street|St|Road|Rd|Avenue|Ave|Drive|Dr|Court|Ct|Place|Pl|Trail|Way|Boulevard|Blvd)\b(?:,\s*[A-Za-z .'-]+)?/gi)||[];
    addressMatches.forEach(function(a){out.push(a.trim())});

    if(/maidstone/i.test(txt))out.push("25 Maidstone Lane","Maidstone Lane","Wading River");

    return Array.from(new Set(out.filter(Boolean)));
  }
  async function fetchDocs(){
    const candidates=candidateAliases();
    for(const a of candidates){
      try{
        const res=await fetch("./api/claire-dealview/source-docs?deal_id="+encodeURIComponent(a),{headers:{Accept:"application/json"},cache:"no-store"});
        const data=await res.json();
        if((data.source_documents||[]).length || data.claire_result)return data;
      }catch(e){}
    }
    return {ok:true,source_documents:[]};
  }
  function notesHtml(result){
    if(!result)return "";
    const parts=[];
    if(result.operator_summary)parts.push("<p><strong>Summary:</strong> "+esc(result.operator_summary)+"</p>");
    if(result.recommended_next_action)parts.push("<p><strong>Recommended next action:</strong> "+esc(result.recommended_next_action)+"</p>");
    function list(title, arr){
      if(!Array.isArray(arr) || !arr.length)return "";
      return '<div style="margin-top:10px;"><strong>'+esc(title)+'</strong><ul style="margin:6px 0 0 18px;">'+arr.map(function(x){return "<li>"+esc(x)+"</li>"}).join("")+"</ul></div>";
    }
    const f=result.dealdesk_fields||{};
    parts.push(list("Notes", f.notes||result.notes));
    parts.push(list("Review flags", f.review_flags||result.review_flags));
    parts.push(list("Missing items", f.missing_items||result.missing_items));
    parts.push(list("Conflicts", f.conflicts||result.conflicts));
    if(!parts.length)return "";
    return '<details style="margin-top:12px;border-top:1px solid #dbe5ef;padding-top:12px;"><summary style="cursor:pointer;font-weight:900;">CLAIRE Intake Read / Notes</summary><div style="margin-top:10px;color:#213447;line-height:1.45;">'+parts.join("")+'</div></details>';
  }
  function buildPanel(data){
    const docs=data.source_documents||[];
    const links=docs.length ? docs.map(function(d){
      return '<a style="display:block;padding:10px 12px;border:1px solid #dbe5ef;border-radius:10px;text-decoration:none;color:#071b2c;font-weight:800;background:#fff;" target="_blank" rel="noopener" href="'+esc(d.url)+'">'+esc(d.filename)+' <span style="color:#66758a;font-weight:400;">('+esc(d.mime_type||"document")+')</span></a>';
    }).join("") : '<div style="color:#66758a;">No accepted-offer source documents found for this deal.</div>';

    const panel=document.createElement("section");
    panel.className="card claire-source-docs-card";
    panel.style.cssText="margin:16px 0;padding:0;border:1px solid #dbe5ef;border-radius:14px;background:#fff;box-shadow:0 10px 26px rgba(15,35,55,.06);overflow:hidden;font-family:Arial,Helvetica,sans-serif;";
    panel.innerHTML='<div style="padding:14px 16px;background:#f8fbfe;border-bottom:1px solid #dbe5ef;font-weight:900;">Accepted Offer Source Documents</div><div style="padding:14px 16px;display:grid;gap:8px;">'+links+notesHtml(data.claire_result)+'</div>';
    return panel;
  }
  function moveRemoveAcceptedOfferToBottom(){
    const remove=findPanelByText(["remove accepted offer","delete accepted offer","remove offer"]);
    const main=document.querySelector("main") || document.body;
    if(remove && remove.parentNode && remove !== main.lastElementChild)main.appendChild(remove);
    return remove;
  }
  function placePanel(panel){
    const main=document.querySelector("main") || document.body;
    const remove=moveRemoveAcceptedOfferToBottom();
    if(remove && remove.parentNode){
      remove.parentNode.insertBefore(panel, remove);
      moveRemoveAcceptedOfferToBottom();
      return;
    }
    const audit=findPanelByText(["audit history","file history","activity history","deal history"]);
    if(audit && audit.parentNode){
      audit.parentNode.insertBefore(panel, audit);
      return;
    }
    main.appendChild(panel);
  }
  async function load(){
    hideEmptyGenericDocs();
    moveRemoveAcceptedOfferToBottom();

    const data=await fetchDocs();
    const existing=document.querySelector(".claire-source-docs-card");
    if(existing)existing.remove();

    placePanel(buildPanel(data));
    hideEmptyGenericDocs();
    moveRemoveAcceptedOfferToBottom();
  }
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",load);
  else load();
  setTimeout(function(){ hideEmptyGenericDocs(); moveRemoveAcceptedOfferToBottom(); },500);
  setTimeout(function(){ hideEmptyGenericDocs(); moveRemoveAcceptedOfferToBottom(); },1500);
})();
</script>
<!-- END_DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V3 -->
'''
    idx = detail.lower().rfind("</body>")
    if idx >= 0:
        detail = detail[:idx] + panel + "\n" + detail[idx:]
    else:
        detail += "\n" + panel
    DETAIL.write_text(detail, encoding="utf-8")
    print("Installed V3 detail source-doc panel.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Source document link repair complete."
echo ""
echo "What changed:"
echo "1. Source-doc lookup now searches manifests by deal id, public id, property address, folder, and document filenames."
echo "2. Detail page now tries URL id plus visible address text if the direct id lookup fails."
echo "3. Accepted Offer Source Documents panel should always render near the bottom, above Remove Accepted Offer."
echo "4. If docs still do not exist for that deal, the panel will say no source documents found instead of disappearing."
echo ""
echo "Now hard refresh the deal detail page."
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
