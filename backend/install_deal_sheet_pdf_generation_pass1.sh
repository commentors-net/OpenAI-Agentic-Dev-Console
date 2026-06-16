#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
CLAIRE_HTML="$APPDIR/claire-dealdesk-view.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/deal-sheet-pdf-pass1-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing Pass 1: generate deal sheet PDF when CLAIRE creates a deal file..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

for f in "$SIDE" "$CLAIRE_HTML"; do
  if [ -f "$f" ]; then
    cp -f "$f" "$BACKUP_DIR/$(basename "$f").before-$STAMP.bak"
  fi
done

cd "$BACKEND"
npm install pdfkit >/tmp/deal-sheet-pdf-npm-$STAMP.log 2>&1 || {
  cat /tmp/deal-sheet-pdf-npm-$STAMP.log
  exit 1
}

python3 - <<'PY'
from pathlib import Path
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
HTML = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")

if not SIDE.exists():
    print("ERROR: Missing sidecar.")
    sys.exit(1)
if not HTML.exists():
    print("ERROR: Missing CLAIRE dealdesk view html.")
    sys.exit(1)

def insert_before_handle(src, block):
    idx = src.find("async function handle(req, res)")
    if idx < 0:
        return src, False
    return src[:idx] + block + "\n" + src[idx:], True

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

side = SIDE.read_text(encoding="utf-8", errors="replace")

# Require PDFKit.
if 'const PDFDocument = require("pdfkit");' not in side:
    if 'const path = require("path");' in side:
        side = side.replace('const path = require("path");', 'const path = require("path");\nconst PDFDocument = require("pdfkit");', 1)
    else:
        side = 'const PDFDocument = require("pdfkit");\n' + side

# Use unique constants so we do not collide with earlier source-doc patches.
if "CLAIRE_PDF_PUBLIC_ROOT" not in side:
    marker = 'const MAX_ATTACHMENT_BYTES = Number(process.env.CLAIRE_MAX_ATTACHMENT_BYTES || 25 * 1024 * 1024);'
    consts = r'''

const CLAIRE_PDF_PUBLIC_ROOT = "/home/servicedepartmen/public_html/dealdesk";
const CLAIRE_PDF_SOURCE_ROOT = path.join(CLAIRE_PDF_PUBLIC_ROOT, "source-docs");
const CLAIRE_PDF_MANIFEST_ROOT = path.join(CLAIRE_PDF_SOURCE_ROOT, "manifests");
try { fs.mkdirSync(CLAIRE_PDF_SOURCE_ROOT, { recursive: true }); fs.mkdirSync(CLAIRE_PDF_MANIFEST_ROOT, { recursive: true }); } catch (err) {}
'''
    if marker in side:
        side = side.replace(marker, marker + consts, 1)
    else:
        side = consts + "\n" + side

helpers = r'''
function clairePdfReadBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk.toString("utf8");
      if (body.length > 5_000_000) {
        reject(new Error("Request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function clairePdfSafeSlug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 90) || "deal";
}

function clairePdfSafeFile(value) {
  return String(value || "deal-sheet.pdf")
    .replace(/[\/\\:*?"<>|]+/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 140) || "deal-sheet.pdf";
}

function clairePdfPublicUrl(rel) {
  return "./source-docs/" + rel.split(path.sep).map(encodeURIComponent).join("/");
}

function clairePdfManifestPath(alias) {
  return path.join(CLAIRE_PDF_MANIFEST_ROOT, clairePdfSafeSlug(alias) + ".json");
}

function clairePdfReadJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (err) { return null; }
}

function clairePdfWriteJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
}

function clairePdfReadManifestByAlias(alias) {
  const direct = clairePdfManifestPath(alias);
  if (fs.existsSync(direct)) return clairePdfReadJson(direct);

  if (!fs.existsSync(CLAIRE_PDF_MANIFEST_ROOT)) return null;
  const q = String(alias || "").toLowerCase().trim();
  if (!q) return null;

  for (const name of fs.readdirSync(CLAIRE_PDF_MANIFEST_ROOT)) {
    if (!name.toLowerCase().endsWith(".json")) continue;
    const file = path.join(CLAIRE_PDF_MANIFEST_ROOT, name);
    const data = clairePdfReadJson(file);
    if (!data) continue;
    const hay = JSON.stringify({
      deal_id: data.deal_id,
      deal_public_id: data.deal_public_id,
      property_address: data.property_address,
      folder: data.folder,
      source_documents: data.source_documents
    }).toLowerCase();
    if (hay.includes(q) || q.includes(String(data.property_address || "").toLowerCase())) return data;
  }
  return null;
}

function clairePdfWriteManifestAliases(manifest, aliases) {
  const unique = Array.from(new Set((aliases || []).filter(Boolean).map(String)));
  if (!unique.length) unique.push(manifest.folder || manifest.property_address || "deal");
  for (const alias of unique) {
    clairePdfWriteJson(clairePdfManifestPath(alias), manifest);
  }
}

function clairePdfAddLine(doc, label, value) {
  if (value === undefined || value === null || String(value).trim() === "") return;
  doc.font("Helvetica-Bold").fontSize(9).text(label + ": ", { continued: true });
  doc.font("Helvetica").fontSize(9).text(String(value));
}

function clairePdfMoney(value) {
  return String(value || "").trim();
}

function clairePdfPartiesFromPayload(payload) {
  return [
    ["Seller", payload.seller_name],
    ["Purchaser", payload.purchaser_name],
    ["Seller Attorney", [payload.seller_attorney_name, payload.seller_attorney_email, payload.seller_attorney_phone].filter(Boolean).join(" | ")],
    ["Purchaser Attorney", [payload.purchaser_attorney_name, payload.purchaser_attorney_email, payload.purchaser_attorney_phone].filter(Boolean).join(" | ")],
    ["Listing Agent", [payload.seller_agent_name, payload.seller_agent_broker, payload.seller_agent_email, payload.seller_agent_phone].filter(Boolean).join(" | ")],
    ["Buyer Agent", [payload.purchaser_agent_name, payload.purchaser_agent_broker, payload.purchaser_agent_email, payload.purchaser_agent_phone].filter(Boolean).join(" | ")],
    ["Lender / Loan Officer", [payload.lender_company, payload.lender_name, payload.lender_email, payload.lender_phone].filter(Boolean).join(" | ")]
  ];
}

async function clairePdfGenerateDealSheet(filePath, body) {
  const payload = body.payload || {};
  const deal = body.deal || {};
  const claire = body.claire_result || {};
  const property = payload.property_address || deal.property_address || body.property_address || "Accepted Offer";

  await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: "LETTER", margin: 42, info: { Title: "Deal Sheet - " + property } });
    const stream = fs.createWriteStream(filePath);
    doc.pipe(stream);

    doc.font("Helvetica-Bold").fontSize(18).text("Deal Sheet", { align: "center" });
    doc.font("Helvetica").fontSize(10).text("Accepted Offer to Close", { align: "center" });
    doc.moveDown(1);

    doc.font("Helvetica-Bold").fontSize(13).text(property);
    doc.font("Helvetica").fontSize(9).fillColor("#555").text("Generated by CLAIRE Deal Desk intake on " + new Date().toLocaleString("en-US"));
    doc.fillColor("#000");
    doc.moveDown(0.8);

    doc.font("Helvetica-Bold").fontSize(11).text("Offer Review");
    doc.moveDown(0.25);
    clairePdfAddLine(doc, "MLS", payload.mls_number);
    clairePdfAddLine(doc, "Status", payload.transaction_status || deal.transaction_status || "Accepted Offer Intake Started");
    clairePdfAddLine(doc, "Purchase Price", clairePdfMoney(payload.purchase_price || payload.total_price));
    clairePdfAddLine(doc, "Seller Concession", payload.seller_concession);
    clairePdfAddLine(doc, "Deposit / Down Payment", payload.contract_deposit);
    clairePdfAddLine(doc, "Mortgage Amount", payload.mortgage_amount);
    clairePdfAddLine(doc, "Closing Date / Terms", payload.closing_date_text);
    doc.moveDown(0.8);

    doc.font("Helvetica-Bold").fontSize(11).text("Parties and Contacts");
    doc.moveDown(0.25);
    for (const [label, value] of clairePdfPartiesFromPayload(payload)) clairePdfAddLine(doc, label, value);
    doc.moveDown(0.8);

    doc.font("Helvetica-Bold").fontSize(11).text("CLAIRE Intake Note");
    doc.moveDown(0.25);
    const addTerms = payload.additional_terms || "";
    if (addTerms) doc.font("Helvetica").fontSize(9).text(addTerms, { width: 510 });
    else doc.font("Helvetica").fontSize(9).text("No short CLAIRE intake note supplied.");
    doc.moveDown(0.8);

    const f = claire.dealdesk_fields || {};
    const flags = []
      .concat(Array.isArray(f.review_flags) ? f.review_flags : [])
      .concat(Array.isArray(f.missing_items) ? f.missing_items : [])
      .slice(0, 10);

    doc.font("Helvetica-Bold").fontSize(11).text("Review Flags / Missing Items");
    doc.moveDown(0.25);
    if (flags.length) {
      for (const flag of flags) doc.font("Helvetica").fontSize(9).text("- " + flag, { width: 510 });
    } else {
      doc.font("Helvetica").fontSize(9).text("No major flags saved with intake.");
    }

    const docs = body.source_documents || [];
    doc.moveDown(0.8);
    doc.font("Helvetica-Bold").fontSize(11).text("Source Documents");
    doc.moveDown(0.25);
    if (docs.length) {
      for (const d of docs) doc.font("Helvetica").fontSize(9).text("- " + (d.filename || d.stored_filename || "Source document"));
    } else {
      doc.font("Helvetica").fontSize(9).text("Source documents are saved separately in the Deal Desk source-documents panel.");
    }

    doc.moveDown(1);
    doc.font("Helvetica-Oblique").fontSize(8).fillColor("#555")
      .text("Internal Deal Desk working document. Verify all terms against fully executed contract and attorney communications.", { align: "center" });

    doc.end();
    stream.on("finish", resolve);
    stream.on("error", reject);
  });
}

function clairePdfRebuildIndex() {
  const outFile = path.join(CLAIRE_PDF_SOURCE_ROOT, "source-documents-index.json");
  const docs = [];

  function encRel(rel) {
    return "./source-docs/" + rel.split(path.sep).map(encodeURIComponent).join("/");
  }

  function walk(dir) {
    if (!fs.existsSync(dir)) return;
    for (const name of fs.readdirSync(dir)) {
      const full = path.join(dir, name);
      const rel = path.relative(CLAIRE_PDF_SOURCE_ROOT, full);
      if (!rel || rel === "source-documents-index.json") continue;
      if (rel.startsWith("manifests" + path.sep)) continue;
      const st = fs.statSync(full);
      if (st.isDirectory()) walk(full);
      else {
        const ext = path.extname(name).toLowerCase();
        if (![".pdf", ".png", ".jpg", ".jpeg", ".webp", ".txt", ".doc", ".docx"].includes(ext)) continue;
        docs.push({
          filename: name,
          folder: rel.split(path.sep)[0] || "",
          relative_path: rel,
          url: encRel(rel),
          size_bytes: st.size,
          modified_at: st.mtime.toISOString()
        });
      }
    }
  }

  fs.mkdirSync(CLAIRE_PDF_SOURCE_ROOT, { recursive: true });
  walk(CLAIRE_PDF_SOURCE_ROOT);
  docs.sort((a, b) => a.relative_path.localeCompare(b.relative_path));
  clairePdfWriteJson(outFile, { ok: true, generated_at: new Date().toISOString(), source_documents: docs });
  return docs;
}

async function clairePdfSaveDealSheet(body) {
  const payload = body.payload || {};
  const deal = body.deal || {};
  const property = payload.property_address || deal.property_address || body.property_address || "accepted-offer";
  const dealId = String(body.deal_id || deal.id || deal.deal_id || "").trim();
  const publicId = String(body.deal_public_id || deal.public_id || "").trim();

  let existing = null;
  for (const alias of [publicId, dealId, property]) {
    if (!alias) continue;
    existing = clairePdfReadManifestByAlias(alias);
    if (existing) break;
  }

  const folder = (existing && existing.folder) || clairePdfSafeSlug(publicId || dealId || property);
  const folderPath = path.join(CLAIRE_PDF_SOURCE_ROOT, folder);
  fs.mkdirSync(folderPath, { recursive: true });

  const pdfFilename = "deal-sheet-" + clairePdfSafeSlug(property).slice(0, 70) + ".pdf";
  const stored = clairePdfSafeFile(pdfFilename);
  const outPath = path.join(folderPath, stored);

  await clairePdfGenerateDealSheet(outPath, body);

  const stat = fs.statSync(outPath);
  const rel = path.join(folder, stored);
  const pdfEntry = {
    number: 0,
    filename: stored,
    stored_filename: stored,
    url: clairePdfPublicUrl(rel),
    mime_type: "application/pdf",
    size_bytes: stat.size,
    category: "generated_deal_sheet",
    generated_at: new Date().toISOString()
  };

  const manifest = existing || {
    ok: true,
    created_at: new Date().toISOString(),
    deal_id: dealId,
    deal_public_id: publicId,
    property_address: property,
    folder,
    source_documents: []
  };

  manifest.ok = true;
  manifest.deal_id = manifest.deal_id || dealId;
  manifest.deal_public_id = manifest.deal_public_id || publicId;
  manifest.property_address = manifest.property_address || property;
  manifest.folder = manifest.folder || folder;
  manifest.updated_at = new Date().toISOString();
  manifest.deal_sheet_pdf = pdfEntry;
  manifest.claire_result = manifest.claire_result || body.claire_result || null;
  manifest.claire_raw_output = manifest.claire_raw_output || body.claire_raw_output || null;

  const docs = Array.isArray(manifest.source_documents) ? manifest.source_documents : [];
  const filtered = docs.filter(d => d.category !== "generated_deal_sheet" && d.stored_filename !== stored && d.filename !== stored);
  manifest.source_documents = [pdfEntry, ...filtered];

  clairePdfWriteManifestAliases(manifest, [dealId, publicId, property, folder]);
  clairePdfRebuildIndex();

  return { manifest, pdf: pdfEntry };
}
'''

if "async function clairePdfSaveDealSheet" not in side:
    side, ok = insert_before_handle(side, helpers)
    if not ok:
        print("ERROR: Could not insert PDF helper functions before handle().")
        sys.exit(1)

route = r'''if (req.method === "POST" && url.pathname === "/api/claire-dealview/generate-deal-sheet-pdf") {
    const raw = await clairePdfReadBody(req);
    let body = {};
    try { body = raw ? JSON.parse(raw) : {}; } catch (err) { throw new Error("Bad JSON body."); }

    const result = await clairePdfSaveDealSheet(body);
    sendJson(res, 200, { ok: true, pdf: result.pdf, manifest: result.manifest });
    return;
  }'''

if '"/api/claire-dealview/generate-deal-sheet-pdf"' not in side:
    marker = 'sendJson(res, 404'
    idx = side.find(marker)
    if idx < 0:
        print("ERROR: Could not find 404 sendJson marker for route insertion.")
        sys.exit(1)
    # Find the start of the line containing marker and insert route before it.
    line_start = side.rfind("\n", 0, idx) + 1
    side = side[:line_start] + "  " + route + "\n\n" + side[line_start:]

SIDE.write_text(side, encoding="utf-8")

html = HTML.read_text(encoding="utf-8", errors="replace")

helper_js = r'''
  async function generateDealSheetPdfForCreatedDeal(deal,payload,saveResult){
    const body={
      deal,
      payload,
      deal_id: deal.id || deal.deal_id || "",
      deal_public_id: deal.public_id || "",
      property_address: payload.property_address || deal.property_address || "",
      source_documents: (saveResult && saveResult.manifest && saveResult.manifest.source_documents) || [],
      claire_result: normalizeClaireResult((lastResult&&lastResult.result)||{}),
      claire_raw_output: (lastResult&&lastResult.raw_output)||""
    };

    const res=await fetch("./api/claire-dealview/generate-deal-sheet-pdf",{
      method:"POST",
      headers:{"Content-Type":"application/json","Accept":"application/json"},
      cache:"no-store",
      body:JSON.stringify(body)
    });

    const data=await res.json();
    if(!res.ok || data.ok===false)throw new Error(data.error || "Could not generate deal sheet PDF");
    return data;
  }

'''

if "async function generateDealSheetPdfForCreatedDeal" not in html:
    marker = "  async function createDealFile(){"
    if marker in html:
        html = html.replace(marker, helper_js + "\n" + marker, 1)
    else:
        print("ERROR: Could not find createDealFile() in CLAIRE HTML.")
        sys.exit(1)

call_js = r'''
      let pdfResult=null;
      try{
        pdfResult=await generateDealSheetPdfForCreatedDeal(deal,payload,(typeof saveResult!=="undefined"?saveResult:null));
        if(pdfResult && pdfResult.pdf && pdfResult.pdf.url && $("dealTab")){
          $("dealTab").insertAdjacentHTML("afterbegin",`<div class="status ok"><strong>Deal Sheet PDF generated.</strong><br><a href="${esc(pdfResult.pdf.url)}" target="_blank" rel="noopener">Open Deal Sheet PDF</a></div>`);
        }
      }catch(pdfErr){
        console.warn("Deal sheet PDF generation failed",pdfErr);
        if($("dealTab"))$("dealTab").insertAdjacentHTML("afterbegin",`<div class="status warn"><strong>Deal file created, but PDF generation failed.</strong><br>${esc(pdfErr.message||pdfErr)}</div>`);
      }

'''

if "generateDealSheetPdfForCreatedDeal(deal,payload" not in html:
    # Preferred: after source docs are saved.
    target = '''      const publicId=deal.public_id || deal.id || deal.deal_id || "";'''
    if target in html:
        html = html.replace(target, call_js + target, 1)
    else:
        # Fallback after const deal=data.deal||{};
        target2 = "      const deal=data.deal||{};"
        if target2 in html:
            html = html.replace(target2, target2 + "\n" + call_js, 1)
        else:
            print("WARNING: Could not find ideal insertion point for PDF generation call.")

HTML.write_text(html, encoding="utf-8")
print("Patched sidecar and CLAIRE HTML for deal sheet PDF generation.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Pass 1 installed: Deal Sheet PDF generation."
echo ""
echo "Now test:"
echo "1. Open https://servicedepartment.ai/dealdesk/claire-dealdesk-view.html"
echo "2. Read the accepted-offer email"
echo "3. Click Create Deal File"
echo "4. Confirm a Deal Sheet PDF generated link appears"
echo "5. Open the deal detail screen and confirm the generated PDF appears in source documents"
echo ""
echo "No email is sent yet. Emailing the PDF to dealsheets@servicedepartment.ai is Pass 2 after PDF output is verified."
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
