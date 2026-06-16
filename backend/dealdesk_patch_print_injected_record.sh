#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
PRINT="$APPDIR/print.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/print-injected-record-final-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing print.html injected-record fix..."
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
import re
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
PRINT = Path("/home/servicedepartmen/public_html/dealdesk/print.html")

print_html = PRINT.read_text(encoding="utf-8", errors="replace")

marker = "DEALDESK_PRINT_INJECTED_RECORD_SUPPORT_FINAL"
if marker not in print_html:
    needle = "var response = await fetch('./api/deals/' + encodeURIComponent(id), {"
    if needle not in print_html:
        print("ERROR: Could not find print.html fetch line. Need Claude/manual patch.")
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
    print("Patched print.html to use injected deal record before API fetch.")
else:
    print("print.html already has injected-record support.")

side = SIDE.read_text(encoding="utf-8", errors="replace")

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
        nxt = src[i+1] if i + 1 < len(src) else ""

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

# Confirm required imports without putting anything before shebang.
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

  const deal = opts.deal || {};
  const payload = opts.payload || {};
  const sourceRecord = opts.record || {};

  // Build a wide record so print.html can use whichever field names it already expects.
  const record = Object.assign({}, payload, deal, sourceRecord, {
    id: sourceRecord.id || deal.id || payload.id || dealPublicId,
    deal_id: sourceRecord.deal_id || deal.deal_id || payload.deal_id || dealPublicId,
    public_id: sourceRecord.public_id || deal.public_id || payload.public_id || dealPublicId,
    property_address: property || sourceRecord.property_address || deal.property_address || payload.property_address || ""
  });

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

    const pageText = await page.evaluate(() => document.body ? document.body.innerText : "");
    if (/Could not load printable deal sheet|Could not load accepted offer file|Missing accepted offer file ID|unauthorized|login|invalid auth/i.test(pageText)) {
      throw new Error("Local print.html loaded, but it did not use the injected deal record.");
    }

    const textLen = String(pageText || "").trim().length;
    if (textLen < 100) {
      throw new Error("Local print.html rendered too little content, so the PDF would likely be blank. Body text length: " + textLen);
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
    render_mode: "local_print_html_injected_record_final",
    generated_at: new Date().toISOString()
  };
}'''

start, end = find_function(side, "ddAutoRenderPrintPageToPdf")
side = side[:start] + new_render + side[end:]

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
elif "ddAutoRenderPrintPageToPdf({" in side and "deal," not in side[side.find("ddAutoRenderPrintPageToPdf({"):side.find("ddAutoRenderPrintPageToPdf({")+500]:
    print("WARNING: ddAutoRenderPrintPageToPdf call was not standard. It may already be patched.")

# Make shebang exactly first line.
lines = side.splitlines()
lines = [line for line in lines if line.strip() != "#!/usr/bin/env node"]
side = "#!/usr/bin/env node\n" + "\n".join(lines) + "\n"

SIDE.write_text(side, encoding="utf-8")
print("Patched sidecar to inject deal record into local print.html.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "Installed injected-record print fix."
echo ""
echo "CHECK PRINT.HTML"
grep -n "DEALDESK_PRINT_INJECTED_RECORD_SUPPORT_FINAL\|__DEALDESK_PRINT_RECORD__\|dealdesk_print_record" "$PRINT" || echo "NO PRINT INJECT MATCHES"

echo ""
echo "CHECK SIDECAR"
grep -n "local_print_html_injected_record_final\|__DEALDESK_PRINT_RECORD__\|dealdesk_print_record" "$SIDE" || echo "NO SIDECAR INJECT MATCHES"

echo ""
echo "PM2"
pm2 status "$PM2_NAME"

echo ""
echo "Next test:"
echo "1. Go back to CLAIRE."
echo "2. Recreate the deal from the accepted-offer email."
echo "3. Saved PDF should use the same print.html renderer, but with injected deal data."
echo "4. If it fails or is still blank, copy only that result."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
