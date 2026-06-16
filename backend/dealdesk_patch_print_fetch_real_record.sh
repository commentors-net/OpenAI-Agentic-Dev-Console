#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
PRINT="$APPDIR/print.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/print-fetch-real-api-record-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing final print fix: fetch real Deal Desk API record before rendering print.html..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

if [ ! -f "$SIDE" ]; then
  echo "Missing sidecar: $SIDE"
  exit 1
fi

if [ ! -f "$PRINT" ]; then
  echo "Missing print page: $PRINT"
  exit 1
fi

cp -f "$SIDE" "$BACKUP_DIR/claire_dealview_sidecar.js.before-$STAMP.bak"
cp -f "$PRINT" "$BACKUP_DIR/print.html.before-$STAMP.bak"

python3 - <<'PY'
from pathlib import Path
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
PRINT = Path("/home/servicedepartmen/public_html/dealdesk/print.html")

def find_function(src, name):
    marker = f"async function {name}"
    start = src.find(marker)
    if start < 0:
        raise RuntimeError(f"Could not find {marker}")
    brace = src.find("{", start)
    if brace < 0:
        raise RuntimeError(f"Could not find opening brace for {name}")
    depth = 0
    i = brace
    in_str = None
    esc = False
    in_line_comment = False
    in_block_comment = False

    while i < len(src):
        ch = src[i]
        nxt = src[i + 1] if i + 1 < len(src) else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue

        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue

        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == in_str:
                in_str = None
            i += 1
            continue

        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue

        if ch == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue

        if ch in ("'", '"', "`"):
            in_str = ch
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1

        i += 1

    raise RuntimeError(f"Could not find end of function {name}")

# Keep print.html injection support, because local print.html must be allowed to render injected record.
print_html = PRINT.read_text(encoding="utf-8", errors="replace")
inject_marker = "DEALDESK_PRINT_INJECTED_RECORD_SUPPORT_FINAL"
if inject_marker not in print_html:
    needle = "var response = await fetch('./api/deals/' + encodeURIComponent(id), {"
    if needle not in print_html:
        print("ERROR: Could not find print.html fetch line.")
        sys.exit(1)

    injected = r'''if (window.__DEALDESK_PRINT_RECORD__) {
          render(window.__DEALDESK_PRINT_RECORD__);
          return;
        }

        try {
          var injectedKey = 'dealdesk_print_record_' + id;
          var injectedRaw = sessionStorage.getItem(injectedKey) || localStorage.getItem(injectedKey);
          if (injectedRaw) {
            var injectedRecord = JSON.parse(injectedRaw);
            if (injectedRecord && typeof injectedRecord === 'object') {
              render(injectedRecord);
              return;
            }
          }
        } catch (err) {}

        /* DEALDESK_PRINT_INJECTED_RECORD_SUPPORT_FINAL */
        '''
    print_html = print_html.replace(needle, injected + needle, 1)
    PRINT.write_text(print_html, encoding="utf-8")
    print("Patched print.html injection support.")
else:
    print("print.html injection support already present.")

side = SIDE.read_text(encoding="utf-8", errors="replace")

# Preserve shebang and required imports.
for req in [
    'const fs = require("fs");',
    'const path = require("path");',
    'const puppeteer = require("puppeteer");'
]:
    module_name = req.split('require("', 1)[1].split('"', 1)[0]
    already = (f'require("{module_name}")' in side) or (f"require('{module_name}')" in side)
    if not already:
        if side.startswith("#!/usr/bin/env node\n"):
            side = "#!/usr/bin/env node\n" + req + "\n" + side[len("#!/usr/bin/env node\n"):]
        else:
            side = req + "\n" + side

helper_name = "ddAutoFetchRealDealRecord"
if helper_name not in side:
    insert = r'''
async function ddAutoFetchRealDealRecord(dealPublicId) {
  const id = String(dealPublicId || "").trim();
  if (!id) return null;

  const port = Number(process.env.DEALDESK_PORT || 3017);
  const candidates = [
    "http://127.0.0.1:" + port + "/api/dealdesk/deals/" + encodeURIComponent(id),
    "http://127.0.0.1:" + port + "/api/deals/" + encodeURIComponent(id)
  ];

  let lastError = "";

  for (const url of candidates) {
    try {
      const response = await fetch(url, {
        headers: { "Accept": "application/json" }
      });

      const text = await response.text();
      let data = null;

      try {
        data = text ? JSON.parse(text) : {};
      } catch (err) {
        lastError = "Non-JSON from " + url + ": " + text.slice(0, 140);
        continue;
      }

      if (response.ok && data && data.ok && data.record && data.record.deal) {
        return data.record;
      }

      lastError = "Bad response from " + url + ": " + JSON.stringify(data).slice(0, 240);
    } catch (err) {
      lastError = String(err && err.message ? err.message : err);
    }
  }

  console.warn("Could not fetch real Deal Desk record for print PDF:", lastError);
  return null;
}
'''
    start, end = find_function(side, "ddAutoRenderPrintPageToPdf")
    side = side[:start] + insert + "\n" + side[start:]
else:
    print("ddAutoFetchRealDealRecord already present.")

new_render = r'''async function ddAutoRenderPrintPageToPdf(opts) {
  const dealPublicId = String(opts.deal_public_id || opts.deal_id || "").trim();
  const property = String(opts.property_address || "accepted-offer").trim();

  if (!dealPublicId) throw new Error("Missing deal public id for print.html.");

  const folder = ddAutoSlug(dealPublicId || property);
  const folderPath = path.join(DD_AUTO_DOC_ROOT, folder);
  fs.mkdirSync(folderPath, { recursive: true });

  const filename = "deal-sheet-" + ddAutoSlug(property).slice(0, 70) + ".pdf";
  const absolutePath = path.join(folderPath, filename);

  const printFilePath = "/home/servicedepartmen/public_html/dealdesk/print.html";
  if (!fs.existsSync(printFilePath)) {
    throw new Error("Local print.html was not found at " + printFilePath);
  }

  const printUrl = "file://" + printFilePath + "?id=" + encodeURIComponent(dealPublicId);

  const apiRecord = await ddAutoFetchRealDealRecord(dealPublicId);
  const deal = opts.deal || {};
  const payload = opts.payload || {};
  const sourceRecord = opts.record || {};

  // Use the exact full record returned by the main Deal Desk API whenever possible.
  // print.html expects record.deal, record.financials, and record.parties.
  const fallbackRecord = Object.assign({}, sourceRecord, {
    deal: Object.assign({}, sourceRecord.deal || {}, payload, deal, {
      id: deal.id || payload.id || dealPublicId,
      deal_id: deal.deal_id || payload.deal_id || dealPublicId,
      public_id: deal.public_id || payload.public_id || dealPublicId,
      property_address: property || deal.property_address || payload.property_address || ""
    }),
    financials: sourceRecord.financials || payload.financials || deal.financials || {},
    parties: sourceRecord.parties || payload.parties || deal.parties || []
  });

  const record = apiRecord || fallbackRecord;

  const browser = await puppeteer.launch({
    headless: true,
    args: [
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-dev-shm-usage",
      "--allow-file-access-from-files",
      "--disable-web-security"
    ]
  });

  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1100, height: 1400, deviceScaleFactor: 1 });

    await page.evaluateOnNewDocument((record, dealPublicId) => {
      window.__DEALDESK_PRINT_RECORD__ = record;
      window.__DEALDESK_PRINT_DEAL_ID__ = dealPublicId;
      try {
        localStorage.setItem("dealdesk_print_record_" + dealPublicId, JSON.stringify(record));
        sessionStorage.setItem("dealdesk_print_record_" + dealPublicId, JSON.stringify(record));
      } catch (err) {}
    }, record, dealPublicId);

    await page.goto(printUrl, { waitUntil: "networkidle0", timeout: 120000 });
    await page.emulateMediaType("print");

    await new Promise(resolve => setTimeout(resolve, 1500));

    const result = await page.evaluate(() => {
      const text = document.body ? document.body.innerText : "";
      const dealTitle = document.querySelector(".deal-title, h1") ? document.querySelector(".deal-title, h1").innerText : "";
      return {
        text,
        textLength: String(text || "").trim().length,
        dealTitle,
        hasMainSheet: !!document.querySelector("main.sheet, main.page"),
        hasProperty: /Property Address/i.test(text || "")
      };
    });

    if (/Could not load printable deal sheet|Could not load accepted offer file|Missing accepted offer file ID|unauthorized|login|invalid auth/i.test(result.text || "")) {
      throw new Error("Local print.html loaded, but it did not use the injected real Deal Desk API record.");
    }

    if (!result.hasMainSheet || !result.hasProperty || result.textLength < 250) {
      throw new Error("Local print.html rendered too little real deal content. Render check: " + JSON.stringify({
        textLength: result.textLength,
        dealTitle: result.dealTitle,
        hasMainSheet: result.hasMainSheet,
        hasProperty: result.hasProperty,
        usedApiRecord: !!apiRecord
      }));
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
    render_mode: "local_print_html_with_real_dealdesk_api_record",
    generated_at: new Date().toISOString()
  };
}'''

start, end = find_function(side, "ddAutoRenderPrintPageToPdf")
side = side[:start] + new_render + side[end:]

# Make sure the call passes deal/payload/record. If it already does, leave it.
old_call = '''const pdf = await ddAutoRenderPrintPageToPdf({
    deal_public_id: dealPublicId,
    deal_id: dealId,
    property_address: property
  });'''

new_call = '''const pdf = await ddAutoRenderPrintPageToPdf({
    deal_public_id: dealPublicId,
    deal_id: dealId,
    property_address: property,
    deal,
    payload,
    record: Object.assign({}, payload, deal, {
      id: deal.id || payload.id || dealPublicId,
      deal_id: deal.deal_id || payload.deal_id || dealId || dealPublicId,
      public_id: deal.public_id || payload.public_id || dealPublicId,
      property_address: property
    })
  });'''

if old_call in side:
    side = side.replace(old_call, new_call, 1)

# Keep shebang first and remove duplicate shebangs.
lines = side.splitlines()
lines = [line for line in lines if line.strip() != "#!/usr/bin/env node"]
side = "#!/usr/bin/env node\n" + "\n".join(lines) + "\n"

SIDE.write_text(side, encoding="utf-8")
print("Patched sidecar to fetch real Deal Desk API record and inject it into local print.html.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "Installed real-record print fix."
echo ""
echo "CHECK PRINT.HTML"
grep -n "DEALDESK_PRINT_INJECTED_RECORD_SUPPORT_FINAL\|__DEALDESK_PRINT_RECORD__\|dealdesk_print_record" "$PRINT" || echo "NO PRINT INJECT MATCHES"

echo ""
echo "CHECK SIDECAR"
grep -n "local_print_html_with_real_dealdesk_api_record\|ddAutoFetchRealDealRecord\|/api/dealdesk/deals" "$SIDE" || echo "NO REAL RECORD MATCHES"

echo ""
echo "PM2"
pm2 status "$PM2_NAME"

echo ""
echo "Next test:"
echo "1. Go back to CLAIRE."
echo "2. Recreate the deal from the accepted-offer email."
echo "3. The PDF should now use the same full record shape that print.html normally gets from ./api/deals."
echo "4. If it fails or is blank, copy only the new failure message."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
