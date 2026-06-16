#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
HTML="$APPDIR/claire-dealdesk-view.html"
DETAIL="$APPDIR/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/source-docs-notes-speed-polish-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Polishing Source Documents, CLAIRE notes, remove-button placement, and safe cache..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

for f in "$SIDE" "$HTML" "$DETAIL"; do
  if [ -f "$f" ]; then
    cp -f "$f" "$BACKUP_DIR/$(basename "$f").before-$STAMP.bak"
  fi
done

python3 - <<'PY'
from pathlib import Path
import sys

BACKEND = Path("/home/servicedepartmen/dealdesk-backend")
SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
HTML = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")
DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")

def insert_before_handle(src, block):
    idx = src.find("async function handle(req, res)")
    if idx < 0:
        return src, False
    return src[:idx] + block + "\n" + src[idx:], True

def patch_sidecar():
    if not SIDE.exists():
        print("WARNING: Sidecar missing; skipping sidecar patch.")
        return

    text = SIDE.read_text(encoding="utf-8", errors="replace")

    # Preserve the full CLAIRE readout in the source-doc manifest.
    if "claire_result: body.claire_result || null" not in text:
        candidates = [
            "inspection_prefill: body.inspection_prefill || null\n  };",
            "inspection_prefill: body.inspection_prefill || null,\n  };",
            "inspection_prefill: body.inspection_prefill || null,\n    claire_result:"
        ]
        if candidates[0] in text:
            text = text.replace(
                candidates[0],
                'inspection_prefill: body.inspection_prefill || null,\n    claire_result: body.claire_result || null,\n    claire_backup_note: "Full CLAIRE intake read preserved here. Additional Terms stays short."\n  };',
                1
            )
            print("Added full CLAIRE readout to source-doc manifest.")
        elif candidates[1] in text:
            text = text.replace(
                candidates[1],
                'inspection_prefill: body.inspection_prefill || null,\n    claire_result: body.claire_result || null,\n    claire_backup_note: "Full CLAIRE intake read preserved here. Additional Terms stays short.",\n  };',
                1
            )
            print("Added full CLAIRE readout to source-doc manifest.")
        else:
            print("WARNING: Could not find manifest block to add full CLAIRE readout.")

    # Safe cache: if not already present, add cache helpers and patch the exact read block only.
    if "function readCachedResult" not in text and "CACHE_DIR" not in text:
        if 'const crypto = require("crypto");' not in text:
            if 'const path = require("path");' in text:
                text = text.replace('const path = require("path");', 'const path = require("path");\nconst crypto = require("crypto");', 1)
            else:
                print("WARNING: Could not add crypto require.")

        marker = 'const MAX_ATTACHMENT_BYTES = Number(process.env.CLAIRE_MAX_ATTACHMENT_BYTES || 25 * 1024 * 1024);'
        if marker in text:
            text = text.replace(marker, marker + r'''

const CACHE_DIR = path.join(BACKEND, "cache", "claire-dealview");
const CACHE_TTL_MS = Number(process.env.CLAIRE_DEALVIEW_CACHE_TTL_MS || 24 * 60 * 60 * 1000);
try { fs.mkdirSync(CACHE_DIR, { recursive: true }); } catch (err) {}
''', 1)
        else:
            print("WARNING: Could not find MAX_ATTACHMENT_BYTES marker for cache constants.")

        helpers = r'''
function cacheKeyForParsedEmail(uid, parsed) {
  const attachments = (parsed.attachments || []).map(att => ({
    filename: att.filename || "",
    type: att.contentType || "",
    size: att.size || (att.content ? att.content.length : 0)
  }));
  const basis = JSON.stringify({
    uid: String(uid || ""),
    model: MODEL,
    subject: parsed.subject || "",
    date: parsed.date ? new Date(parsed.date).toISOString() : "",
    attachments
  });
  return crypto.createHash("sha256").update(basis).digest("hex");
}

function cachePathForKey(key) {
  return path.join(CACHE_DIR, key + ".json");
}

function readCachedResult(key) {
  const file = cachePathForKey(key);
  if (!fs.existsSync(file)) return null;
  const stat = fs.statSync(file);
  if (Date.now() - stat.mtimeMs > CACHE_TTL_MS) return null;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeCachedResult(key, payload) {
  const file = cachePathForKey(key);
  fs.writeFileSync(file, JSON.stringify(payload, null, 2), "utf8");
}
'''
        text, ok = insert_before_handle(text, helpers)
        if ok:
            print("Added safe read cache helpers.")
        else:
            print("WARNING: Could not insert cache helpers.")

        old_block = '''    const parsed = await fetchParsedEmail(uid);
    const modelResult = await askModelStructured(parsed);
    sendJson(res, 200, {
      ok: true,
      uid,
      source_email: {
        from: parsed.from?.text || "",
        to: parsed.to?.text || "",
        subject: parsed.subject || "",
        date: parsed.date ? new Date(parsed.date).toISOString() : "",
        attachments: attachmentSummary(parsed)
      },
      result: modelResult.structured,
      raw_output: modelResult.raw_output
    });
    return;'''

        new_block = '''    const force = url.searchParams.get("force") === "1" || url.searchParams.get("refresh") === "1";
    const parsed = await fetchParsedEmail(uid);
    const key = cacheKeyForParsedEmail(uid, parsed);

    if (!force) {
      const cached = readCachedResult(key);
      if (cached) {
        cached.cached = true;
        cached.cache_key = key;
        sendJson(res, 200, cached);
        return;
      }
    }

    const modelResult = await askModelStructured(parsed);
    const payload = {
      ok: true,
      uid,
      cached: false,
      cache_key: key,
      source_email: {
        from: parsed.from?.text || "",
        to: parsed.to?.text || "",
        subject: parsed.subject || "",
        date: parsed.date ? new Date(parsed.date).toISOString() : "",
        attachments: attachmentSummary(parsed)
      },
      result: modelResult.structured,
      raw_output: modelResult.raw_output
    };

    writeCachedResult(key, payload);
    sendJson(res, 200, payload);
    return;'''
        if old_block in text:
            text = text.replace(old_block, new_block, 1)
            print("Added safe read cache to read route.")
        else:
            print("WARNING: Exact read route block not found. Cache helpers added only; read route unchanged.")
    else:
        print("Read cache appears already installed; leaving reader untouched.")

    SIDE.write_text(text, encoding="utf-8")

def replace_js_function(src, name, replacement):
    start = src.find(name)
    if start < 0:
        return src, False
    brace = src.find("{", start)
    if brace < 0:
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
                return src[:start] + replacement + src[i+1:], True

        i += 1

    return src, False

def patch_claire_html():
    if not HTML.exists():
        print("WARNING: CLAIRE HTML missing; skipping.")
        return

    html = HTML.read_text(encoding="utf-8", errors="replace")

    # Add full CLAIRE readout to the source-doc save body.
    if "claire_result: normalizeClaireResult((lastResult&&lastResult.result)||{})" not in html:
        target = "property_address:payload.property_address,"
        if target in html:
            html = html.replace(
                target,
                target + "\n      claire_result: normalizeClaireResult((lastResult&&lastResult.result)||{}),",
                1
            )
            print("Added full CLAIRE readout to save-source-doc body.")
        else:
            print("WARNING: Could not add full CLAIRE readout to save-source-doc body.")

    # Keep Additional Terms compact.
    compact_make_terms = r'''function makeAdditionalTerms(r,f){
    const issues=[];
    const sellerAttorney=((f.attorneys||{}).seller_attorney)||{};
    const rf=(f.review_flags||[]).join(" ").toLowerCase();
    const conflicts=(f.conflicts||[]).join(" ").toLowerCase();

    if(!sellerAttorney.name && !sellerAttorney.email && !sellerAttorney.phone)issues.push("seller attorney missing");
    if(rf.includes("seller signature") || rf.includes("seller acceptance") || rf.includes("acceptance"))issues.push("seller acceptance not confirmed");
    if(conflicts.includes("pre-approval") || conflicts.includes("preapproval") || conflicts.includes("gutierrez") || conflicts.includes("legal purchaser"))issues.push("verify purchaser/pre-approval name");
    if(!issues.length && f.next_action)issues.push(String(f.next_action).replace(/\s+/g," ").trim());
    if(!issues.length)issues.push("review CLAIRE source documents before attorney package");

    let line="CLAIRE intake note: "+issues.slice(0,2).join("; ")+".";
    if(line.length>240)line=line.slice(0,237)+"...";
    return line;
  }'''
    html, ok = replace_js_function(html, "function makeAdditionalTerms", compact_make_terms)
    if ok:
        print("Ensured compact Additional Terms function.")
    else:
        print("WARNING: makeAdditionalTerms function not found.")

    html = html.replace('inspection_status: "Complete",', 'inspection_status: "Open",')
    html = html.replace('inspection_status:"Complete",', 'inspection_status:"Open",')

    HTML.write_text(html, encoding="utf-8")

def patch_detail():
    if not DETAIL.exists():
        print("WARNING: detail.html missing; skipping detail patch.")
        return

    detail = DETAIL.read_text(encoding="utf-8", errors="replace")
    start_marker = "<!-- DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V2 -->"
    end_marker = "<!-- END_DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V2 -->"

    # Remove old V1 panel if present.
    old_start = "<!-- DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->"
    old_end = "<!-- END_DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V1 -->"
    s = detail.find(old_start)
    e = detail.find(old_end)
    if s >= 0 and e >= s:
        e += len(old_end)
        detail = detail[:s] + detail[e:]

    panel_script = r'''
<!-- DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V2 -->
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
  function sourceDocsPanel(data){
    const docs=data.source_documents||[];
    const docLinks=docs.length ? docs.map(function(d){
      return '<a style="display:block;padding:10px 12px;border:1px solid #dbe5ef;border-radius:10px;text-decoration:none;color:#071b2c;font-weight:800;background:#fff;" target="_blank" rel="noopener" href="'+esc(d.url)+'">'+esc(d.filename)+' <span style="color:#66758a;font-weight:400;">('+esc(d.mime_type||"document")+')</span></a>';
    }).join("") : '<div style="color:#66758a;">No accepted-offer source documents saved yet.</div>';

    const fullRead=notesHtml(data.claire_result);

    const panel=document.createElement("section");
    panel.className="card claire-source-docs-card";
    panel.style.cssText="margin:16px 0;padding:0;border:1px solid #dbe5ef;border-radius:14px;background:#fff;box-shadow:0 10px 26px rgba(15,35,55,.06);overflow:hidden;font-family:Arial,Helvetica,sans-serif;";
    panel.innerHTML='<div style="padding:14px 16px;background:#f8fbfe;border-bottom:1px solid #dbe5ef;font-weight:900;">Accepted Offer Source Documents</div><div style="padding:14px 16px;display:grid;gap:8px;">'+docLinks+fullRead+'</div>';
    return panel;
  }
  function moveRemoveAcceptedOfferToBottom(){
    const remove=findPanelByText(["remove accepted offer","delete accepted offer","remove offer"]);
    const main=document.querySelector("main") || document.body;
    if(remove && remove.parentNode && remove !== main.lastElementChild){
      main.appendChild(remove);
    }
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
  async function loadClaireSourceDocs(){
    hideEmptyGenericDocs();
    moveRemoveAcceptedOfferToBottom();

    const id=dealIdFromUrl();
    if(!id)return;

    try{
      const res=await fetch("./api/claire-dealview/source-docs?deal_id="+encodeURIComponent(id),{headers:{Accept:"application/json"},cache:"no-store"});
      const data=await res.json();

      const existing=document.querySelector(".claire-source-docs-card");
      if(existing)existing.remove();

      if(!(data.source_documents||[]).length && !data.claire_result)return;

      placePanel(sourceDocsPanel(data));
      hideEmptyGenericDocs();
      moveRemoveAcceptedOfferToBottom();
    }catch(e){}
  }
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",loadClaireSourceDocs);
  else loadClaireSourceDocs();

  setTimeout(function(){ hideEmptyGenericDocs(); moveRemoveAcceptedOfferToBottom(); },500);
  setTimeout(function(){ hideEmptyGenericDocs(); moveRemoveAcceptedOfferToBottom(); },1500);
})();
</script>
<!-- END_DEALDESK_CLAIRE_SOURCE_DOCS_PANEL_V2 -->
'''

    s = detail.find(start_marker)
    e = detail.find(end_marker)
    if s >= 0 and e >= s:
        e += len(end_marker)
        detail = detail[:s] + panel_script + detail[e:]
    else:
        idx = detail.lower().rfind("</body>")
        if idx >= 0:
            detail = detail[:idx] + panel_script + "\n" + detail[idx:]
        else:
            detail += "\n" + panel_script

    DETAIL.write_text(detail, encoding="utf-8")
    print("Patched detail source-doc/notes panel and remove-button placement.")

patch_sidecar()
patch_claire_html()
patch_detail()
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Polish complete."
echo ""
echo "What changed:"
echo "1. Empty generic Deal Documents panel is hidden."
echo "2. CLAIRE panel is now named Accepted Offer Source Documents."
echo "3. Source Documents panel is placed directly above Remove Accepted Offer."
echo "4. Remove Accepted Offer is moved to the bottom of the deal detail page."
echo "5. Full CLAIRE notes/readout are saved into the source-doc manifest for newly created deals."
echo "6. The deal detail page shows those notes under a collapsible CLAIRE Intake Read / Notes section."
echo "7. Safe read cache is installed if it was missing. First read may still take time; repeat reads should be much faster."
echo ""
echo "Test:"
echo "- Recreate/open the deal."
echo "- Look above Remove Accepted Offer for Accepted Offer Source Documents."
echo "- Open CLAIRE Intake Read / Notes to see the full valuable read."
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
