#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
READER="$APPDIR/claire-dealdesk-view.html"
DETAIL="$APPDIR/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/auto-print-email-final-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Deal Desk auto print/save/email install starting..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

for f in "$SIDE" "$READER" "$DETAIL"; do
  if [ -f "$f" ]; then
    cp -f "$f" "$BACKUP_DIR/$(basename "$f").before-$STAMP.bak"
  else
    echo "Missing required file: $f"
    exit 1
  fi
done

cd "$BACKEND"

echo "Installing puppeteer and nodemailer..."
npm install puppeteer nodemailer

cat > /tmp/dealdesk_auto_print_email_patch.py <<'PY'
from pathlib import Path
import sys

BACKEND = Path("/home/servicedepartmen/dealdesk-backend")
APPDIR = Path("/home/servicedepartmen/public_html/dealdesk")
SIDE = BACKEND / "claire_dealview_sidecar.js"
READER = APPDIR / "claire-dealdesk-view.html"
DETAIL = APPDIR / "detail.html"

if not SIDE.exists() or not READER.exists() or not DETAIL.exists():
    print("ERROR: missing required file")
    print("SIDE", SIDE.exists(), SIDE)
    print("READER", READER.exists(), READER)
    print("DETAIL", DETAIL.exists(), DETAIL)
    sys.exit(1)

def insert_before_handle(src, block):
    idx = src.find("async function handle(req, res)")
    if idx < 0:
        raise RuntimeError("Could not find async function handle(req, res) in sidecar.")
    return src[:idx] + block + "\n" + src[idx:]

def insert_before_404(src, block):
    marker = "sendJson(res, 404"
    idx = src.find(marker)
    if idx < 0:
        raise RuntimeError("Could not find sendJson(res, 404 route marker in sidecar.")
    line_start = src.rfind("\n", 0, idx) + 1
    return src[:line_start] + "  " + block + "\n\n" + src[line_start:]

side = SIDE.read_text(encoding="utf-8", errors="replace")

required = [
    'const fs = require("fs");',
    'const path = require("path");',
    'const puppeteer = require("puppeteer");',
    'const nodemailer = require("nodemailer");'
]

for req in required:
    module_name = req.split('require("', 1)[1].split('"', 1)[0]
    already = (f'require("{module_name}")' in side) or (f"require('{module_name}')" in side)
    if not already:
        side = req + "\n" + side

helpers = r'''
const DD_AUTO_DOC_ROOT = "/home/servicedepartmen/public_html/dealdesk/generated-docs";
const DD_AUTO_MANIFEST_ROOT = path.join(DD_AUTO_DOC_ROOT, "manifests");
try { fs.mkdirSync(DD_AUTO_DOC_ROOT, { recursive: true }); fs.mkdirSync(DD_AUTO_MANIFEST_ROOT, { recursive: true }); } catch (err) {}

function ddAutoReadBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk.toString("utf8");
      if (body.length > 5000000) {
        reject(new Error("Request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function ddAutoSlug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 90) || "deal";
}

function ddAutoPublicUrl(rel) {
  return "./generated-docs/" + rel.split(path.sep).map(encodeURIComponent).join("/");
}

function ddAutoManifestPath(alias) {
  return path.join(DD_AUTO_MANIFEST_ROOT, ddAutoSlug(alias) + ".json");
}

function ddAutoReadJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (err) { return null; }
}

function ddAutoWriteJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
}

function ddAutoFindManifest(aliases) {
  const clean = (aliases || []).filter(Boolean).map(String);
  for (const alias of clean) {
    const direct = ddAutoManifestPath(alias);
    if (fs.existsSync(direct)) return ddAutoReadJson(direct);
  }

  if (!fs.existsSync(DD_AUTO_MANIFEST_ROOT)) return null;

  const lowered = clean.map(x => x.toLowerCase()).filter(Boolean);
  for (const name of fs.readdirSync(DD_AUTO_MANIFEST_ROOT)) {
    if (!name.toLowerCase().endsWith(".json")) continue;
    const file = path.join(DD_AUTO_MANIFEST_ROOT, name);
    const data = ddAutoReadJson(file);
    if (!data) continue;
    const hay = JSON.stringify(data).toLowerCase();
    if (lowered.some(q => q && hay.includes(q))) return data;
  }

  return null;
}

function ddAutoWriteManifest(manifest, aliases) {
  const unique = Array.from(new Set((aliases || []).filter(Boolean).map(String)));
  if (!unique.length) unique.push(manifest.folder || manifest.property_address || "deal");
  for (const alias of unique) ddAutoWriteJson(ddAutoManifestPath(alias), manifest);
}

function ddAutoTransporter() {
  const host = process.env.DEALDESK_SMTP_HOST || process.env.SMTP_HOST || "";
  const user = process.env.DEALDESK_SMTP_USER || process.env.SMTP_USER || "";
  const pass = process.env.DEALDESK_SMTP_PASS || process.env.SMTP_PASS || "";
  const port = Number(process.env.DEALDESK_SMTP_PORT || process.env.SMTP_PORT || 587);
  const secure = String(process.env.DEALDESK_SMTP_SECURE || process.env.SMTP_SECURE || "").toLowerCase() === "true";

  if (host && user && pass) {
    return nodemailer.createTransport({ host, port, secure, auth: { user, pass } });
  }

  for (const p of [process.env.SENDMAIL_PATH, "/usr/sbin/sendmail", "/usr/lib/sendmail"].filter(Boolean)) {
    try {
      if (fs.existsSync(p)) {
        return nodemailer.createTransport({ sendmail: true, path: p, newline: "unix" });
      }
    } catch (err) {}
  }

  throw new Error("No email transport configured.");
}

async function ddAutoRenderPrintPageToPdf(opts) {
  const dealPublicId = String(opts.deal_public_id || opts.deal_id || "").trim();
  const property = String(opts.property_address || "accepted-offer").trim();

  if (!dealPublicId) throw new Error("Missing deal public id for print.html.");

  const baseUrl = (process.env.DEALDESK_PUBLIC_BASE_URL || "https://servicedepartment.ai/dealdesk").replace(/\/+$/, "");
  const printUrl = baseUrl + "/print.html?id=" + encodeURIComponent(dealPublicId);

  const folder = ddAutoSlug(dealPublicId || property);
  const folderPath = path.join(DD_AUTO_DOC_ROOT, folder);
  fs.mkdirSync(folderPath, { recursive: true });

  const filename = "deal-sheet-" + ddAutoSlug(property).slice(0, 70) + ".pdf";
  const absolutePath = path.join(folderPath, filename);

  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"]
  });

  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1100, height: 1400, deviceScaleFactor: 1 });
    await page.goto(printUrl, { waitUntil: "networkidle0", timeout: 120000 });
    await page.emulateMediaType("print");

    const pageText = await page.evaluate(() => document.body ? document.body.innerText : "");
    if (/Could not load accepted offer file|Missing accepted offer file ID|unauthorized|login/i.test(pageText)) {
      throw new Error("print.html did not render the accepted-offer deal sheet.");
    }

    await page.pdf({
      path: absolutePath,
      format: "Letter",
      printBackground: true,
      margin: { top: "0.25in", bottom: "0.25in", left: "0.25in", right: "0.25in" }
    });
  } finally {
    await browser.close();
  }

  const stat = fs.statSync(absolutePath);
  const rel = path.join(folder, filename);

  return {
    filename,
    stored_filename: filename,
    relative_path: rel,
    url: ddAutoPublicUrl(rel),
    absolute_path: absolutePath,
    mime_type: "application/pdf",
    size_bytes: stat.size,
    category: "generated_print_deal_sheet",
    print_url: printUrl,
    generated_at: new Date().toISOString()
  };
}

async function ddAutoSendDealSheetEmail(opts) {
  const transporter = ddAutoTransporter();
  const to = process.env.DEALSHEETS_TO || "dealsheets@servicedepartment.ai";
  const from = process.env.DEALSHEETS_FROM || "Deal Desk <dealsheets@servicedepartment.ai>";
  const subject = String(opts.property_address || "Deal Sheet").trim() || "Deal Sheet";

  const info = await transporter.sendMail({
    from,
    to,
    subject,
    text: [
      "Deal Sheet PDF generated by Deal Desk.",
      "",
      "Property: " + subject,
      "Generated: " + new Date().toLocaleString("en-US")
    ].join("\n"),
    attachments: [
      {
        filename: opts.pdf.filename,
        path: opts.pdf.absolute_path,
        contentType: "application/pdf"
      }
    ]
  });

  return {
    to,
    from,
    subject,
    message_id: info.messageId || "",
    response: info.response || "",
    sent_at: new Date().toISOString()
  };
}

async function ddAutoPrintSaveSend(body) {
  const deal = body.deal || {};
  const payload = body.payload || {};

  const property = body.property_address || payload.property_address || deal.property_address || "Accepted Offer";
  const dealPublicId = String(body.deal_public_id || deal.public_id || deal.id || deal.deal_id || "").trim();
  const dealId = String(body.deal_id || deal.id || deal.deal_id || "").trim();

  const pdf = await ddAutoRenderPrintPageToPdf({
    deal_public_id: dealPublicId,
    deal_id: dealId,
    property_address: property
  });

  const email = await ddAutoSendDealSheetEmail({
    property_address: property,
    pdf
  });

  const safePdf = Object.assign({}, pdf, { absolute_path: undefined });

  const manifest = ddAutoFindManifest([dealPublicId, dealId, property]) || {
    ok: true,
    created_at: new Date().toISOString(),
    deal_id: dealId,
    deal_public_id: dealPublicId,
    property_address: property,
    folder: ddAutoSlug(dealPublicId || dealId || property),
    documents: []
  };

  manifest.ok = true;
  manifest.updated_at = new Date().toISOString();
  manifest.deal_id = manifest.deal_id || dealId;
  manifest.deal_public_id = manifest.deal_public_id || dealPublicId;
  manifest.property_address = manifest.property_address || property;
  manifest.last_email = email;

  const docs = Array.isArray(manifest.documents) ? manifest.documents : [];
  manifest.documents = [
    Object.assign({}, safePdf, {
      email_status: "sent",
      email_sent_at: email.sent_at,
      email_to: email.to,
      email_subject: email.subject
    }),
    ...docs.filter(d => d.relative_path !== pdf.relative_path)
  ];

  ddAutoWriteManifest(manifest, [dealPublicId, dealId, property, manifest.folder]);

  return { pdf: safePdf, email, manifest };
}
'''

if "async function ddAutoPrintSaveSend" not in side:
    side = insert_before_handle(side, helpers)

routes = r'''if (req.method === "POST" && url.pathname === "/api/claire-dealview/print-deal-sheet-send") {
    const raw = await ddAutoReadBody(req);
    let body = {};
    try { body = raw ? JSON.parse(raw) : {}; } catch (err) { throw new Error("Bad JSON body."); }

    const result = await ddAutoPrintSaveSend(body);
    sendJson(res, 200, { ok: true, pdf: result.pdf, email: result.email, manifest: result.manifest });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/claire-dealview/generated-docs") {
    const alias = url.searchParams.get("deal_id") || url.searchParams.get("deal_public_id") || url.searchParams.get("public_id") || url.searchParams.get("property") || url.searchParams.get("q") || "";
    const manifest = ddAutoFindManifest([alias]);
    sendJson(res, 200, manifest || { ok: true, documents: [], lookup: { alias, found: false } });
    return;
  }'''

if "/api/claire-dealview/print-deal-sheet-send" not in side:
    side = insert_before_404(side, routes)

SIDE.write_text(side, encoding="utf-8")

reader = READER.read_text(encoding="utf-8", errors="replace")

start = "<!-- DEALDESK_AUTO_PRINT_SEND_DEAL_SHEET_ON_CREATE_FINAL -->"
end = "<!-- END_DEALDESK_AUTO_PRINT_SEND_DEAL_SHEET_ON_CREATE_FINAL -->"
while True:
    s = reader.find(start)
    e = reader.find(end)
    if s >= 0 and e >= s:
        reader = reader[:s] + reader[e + len(end):]
    else:
        break

reader_script = r'''
<!-- DEALDESK_AUTO_PRINT_SEND_DEAL_SHEET_ON_CREATE_FINAL -->
<script>
(function(){
  if (window.__dealdeskAutoPrintSendFinalInstalled) return;
  window.__dealdeskAutoPrintSendFinalInstalled = true;

  function esc(v){return String(v==null?'':v).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]})}

  function statusBox(){
    var box=document.getElementById('dealdeskAutoPrintSendStatus');
    if(box)return box;
    box=document.createElement('div');
    box.id='dealdeskAutoPrintSendStatus';
    box.style.cssText='margin:12px 0;padding:12px;border-radius:12px;border:1px solid #dbe5ef;background:#f8fafc;color:#071b2c;font-weight:800;';
    var target=document.querySelector('#dealTab') || document.querySelector('main') || document.body;
    target.insertBefore(box,target.firstChild);
    return box;
  }

  async function printAndSendDealSheet(deal,payload){
    var property=(payload&&payload.property_address)||(deal&&deal.property_address)||'Deal Sheet';
    var box=statusBox();
    box.innerHTML='Creating the print Deal Sheet PDF and emailing it to dealsheets@servicedepartment.ai...';

    var res=await fetch('./api/claire-dealview/print-deal-sheet-send',{
      method:'POST',
      headers:{'Content-Type':'application/json','Accept':'application/json'},
      cache:'no-store',
      body:JSON.stringify({
        deal:deal||{},
        payload:payload||{},
        deal_id:(deal&&(deal.id||deal.deal_id))||'',
        deal_public_id:(deal&&(deal.public_id||deal.id||deal.deal_id))||'',
        property_address:property
      })
    });

    var data=await res.json();

    if(!res.ok || data.ok===false){
      throw new Error(data.error||'Could not print/save/email Deal Sheet PDF');
    }

    box.innerHTML='<span style="color:#0f766e;">Deal Sheet PDF printed, saved, and emailed.</span><br>' +
      '<a href="'+esc(data.pdf&&data.pdf.url)+'" target="_blank" rel="noopener">Open saved Deal Sheet PDF</a><br>' +
      '<span style="color:#64748b;">Sent to '+esc(data.email&&data.email.to)+' | Subject: '+esc(data.email&&data.email.subject)+'</span>';
  }

  var originalFetch=window.fetch;

  window.fetch=async function(input,init){
    var method=String((init&&init.method)||'GET').toUpperCase();
    var url=String(input&&input.url?input.url:input);
    var normalized=url.replace(location.origin,'').replace(/^\.\//,'');
    var bodyText=(init&&init.body&&typeof init.body==='string')?init.body:'';
    var payload=null;

    if(method==='POST' && /(^|\/)api\/deals\/?$/.test(normalized)){
      try{payload=bodyText?JSON.parse(bodyText):null;}catch(e){}
    }

    var response=await originalFetch.apply(this,arguments);

    if(payload && response && response.clone){
      response.clone().json().then(function(data){
        if(data && data.ok && data.deal){
          setTimeout(function(){
            printAndSendDealSheet(data.deal,payload).catch(function(err){
              var box=statusBox();
              box.innerHTML='<span style="color:#b91c1c;">Deal file created, but print/save/email failed:</span><br>'+esc(err.message||err);
            });
          },1500);
        }
      }).catch(function(){});
    }

    return response;
  };
})();
</script>
<!-- END_DEALDESK_AUTO_PRINT_SEND_DEAL_SHEET_ON_CREATE_FINAL -->
'''

idx = reader.lower().rfind("</body>")
reader = reader[:idx] + reader_script + "\n" + reader[idx:] if idx >= 0 else reader + "\n" + reader_script
READER.write_text(reader, encoding="utf-8")

detail = DETAIL.read_text(encoding="utf-8", errors="replace")

start = "<!-- DEALDESK_GENERATED_SENT_DOCUMENTS_PANEL_FINAL -->"
end = "<!-- END_DEALDESK_GENERATED_SENT_DOCUMENTS_PANEL_FINAL -->"
while True:
    s = detail.find(start)
    e = detail.find(end)
    if s >= 0 and e >= s:
        detail = detail[:s] + detail[e + len(end):]
    else:
        break

detail_script = r'''
<!-- DEALDESK_GENERATED_SENT_DOCUMENTS_PANEL_FINAL -->
<script>
(function(){
  if(window.__dealdeskGeneratedSentDocsPanelFinal)return;
  window.__dealdeskGeneratedSentDocsPanelFinal=true;

  function esc(v){return String(v==null?'':v).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]})}
  function dealId(){var p=new URLSearchParams(location.search);return p.get('id')||p.get('deal_id')||p.get('public_id')||''}
  function closestPanel(el){return el&&(el.closest('section,.card,.panel,.deal-section,.detail-section,[class*="card"],[class*="panel"],[class*="section"]')||el.parentElement)}
  function findPanelByText(needles){
    var els=Array.from(document.querySelectorAll('h1,h2,h3,h4,button,a,section,.card,.panel,div'));
    for(var i=0;i<els.length;i++){
      var txt=(els[i].textContent||'').replace(/\s+/g,' ').trim().toLowerCase();
      if(txt && needles.some(function(n){return txt.includes(n)}))return closestPanel(els[i]);
    }
    return null;
  }

  function buildPanel(data){
    var docs=data.documents||[];
    var html='';

    if(!docs.length){
      html='<div class="note">No generated/sent documents yet. This section will show the printed Deal Sheet PDF after CLAIRE creates the deal and emails it.</div>';
    }else{
      html='<div style="display:grid;gap:10px;">'+docs.map(function(d){
        return '<div style="display:flex;justify-content:space-between;align-items:center;gap:10px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:12px;padding:12px;">'+
          '<div style="min-width:0;">'+
            '<strong style="display:block;overflow-wrap:anywhere;">'+esc(d.filename||'Generated document')+'</strong>'+
            '<span style="display:block;color:#64748b;font-size:12px;margin-top:3px;">'+
              'Status: '+esc(d.email_status||'created')+
              (d.email_to?' | Sent to: '+esc(d.email_to):'')+
              (d.email_subject?' | Subject: '+esc(d.email_subject):'')+
            '</span>'+
          '</div>'+
          '<a href="'+esc(d.url)+'" target="_blank" rel="noopener" style="background:#0f766e;color:white;text-decoration:none;border-radius:10px;padding:9px 12px;font-weight:900;white-space:nowrap;">View PDF</a>'+
        '</div>';
      }).join('')+'</div>';
    }

    var panel=document.createElement('section');
    panel.id='generatedSentDocumentsPanel';
    panel.className='card full';
    panel.innerHTML='<h2>Generated / Sent Documents</h2><p class="note">Documents Deal Desk creates from the accepted-offer file and sends automatically.</p>'+html;
    return panel;
  }

  async function loadGeneratedDocs(){
    var id=dealId();
    if(!id)return;

    try{
      var res=await fetch('./api/claire-dealview/generated-docs?deal_id='+encodeURIComponent(id),{headers:{Accept:'application/json'},cache:'no-store'});
      var data=await res.json();

      var old=document.getElementById('generatedSentDocumentsPanel');
      if(old)old.remove();

      var panel=buildPanel(data||{});

      var remove=findPanelByText(['remove accepted offer','delete accepted offer','remove offer']);
      if(remove&&remove.parentNode){
        remove.parentNode.insertBefore(panel,remove);
        return;
      }

      var audit=findPanelByText(['audit history','file history','activity history','deal history']);
      if(audit&&audit.parentNode){
        audit.parentNode.insertBefore(panel,audit.nextSibling);
        return;
      }

      (document.querySelector('#app')||document.querySelector('main')||document.body).appendChild(panel);
    }catch(e){}
  }

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',loadGeneratedDocs);
  else loadGeneratedDocs();

  setTimeout(loadGeneratedDocs,1500);
  setTimeout(loadGeneratedDocs,3500);
})();
</script>
<!-- END_DEALDESK_GENERATED_SENT_DOCUMENTS_PANEL_FINAL -->
'''

idx = detail.lower().rfind("</body>")
detail = detail[:idx] + detail_script + "\n" + detail[idx:] if idx >= 0 else detail + "\n" + detail_script
DETAIL.write_text(detail, encoding="utf-8")

print("Patched sidecar, CLAIRE reader, and detail page.")
PY

python3 /tmp/dealdesk_auto_print_email_patch.py

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK SIDECAR"
grep -n "print-deal-sheet-send\|generated-docs\|ddAutoPrintSaveSend" "$SIDE" || echo "NO SIDECAR MATCHES"

echo ""
echo "CHECK READER"
grep -n "DEALDESK_AUTO_PRINT_SEND_DEAL_SHEET_ON_CREATE_FINAL\|printAndSendDealSheet" "$READER" || echo "NO READER MATCHES"

echo ""
echo "CHECK DETAIL"
grep -n "DEALDESK_GENERATED_SENT_DOCUMENTS_PANEL_FINAL\|Generated / Sent Documents" "$DETAIL" || echo "NO DETAIL MATCHES"

echo ""
echo "PM2"
pm2 status "$PM2_NAME"

echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
