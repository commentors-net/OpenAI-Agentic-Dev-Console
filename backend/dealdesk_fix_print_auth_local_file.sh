#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/print-auth-local-file-fix-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing one-fix auth bypass for print.html PDF rendering..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

if [ ! -f "$SIDE" ]; then
  echo "Missing sidecar: $SIDE"
  exit 1
fi

cp -f "$SIDE" "$BACKUP_DIR/claire_dealview_sidecar.js.before-$STAMP.bak"

python3 - <<'PY'
from pathlib import Path
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
s = SIDE.read_text(encoding="utf-8", errors="replace")

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
  const record = Object.assign({}, payload, deal, opts.record || {}, {
    id: deal.id || payload.id || dealPublicId,
    deal_id: deal.deal_id || payload.deal_id || dealPublicId,
    public_id: deal.public_id || payload.public_id || dealPublicId,
    property_address: property || deal.property_address || payload.property_address || ""
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

    await page.setRequestInterception(true);
    page.on("request", async request => {
      const url = request.url();
      const lower = url.toLowerCase();

      // The public HTTPS print URL fails because Puppeteer has no browser auth.
      // This renders the local print.html file and answers its API calls with
      // the deal record that was just created by CLAIRE.
      if (
        lower.includes("/api/deals") ||
        lower.includes("/api/accepted") ||
        lower.includes("/dealdesk/api/deals") ||
        (lower.startsWith("file://") && lower.includes("/api/"))
      ) {
        if (lower.includes("documents")) {
          await request.respond({
            status: 200,
            contentType: "application/json",
            body: JSON.stringify({ ok: true, documents: [], files: [], items: [] })
          });
          return;
        }

        await request.respond({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({
            ok: true,
            deal: record,
            record: record,
            data: record,
            accepted_offer: record
          })
        });
        return;
      }

      await request.continue();
    });

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

    // Give any late client-side rendering a moment to finish.
    await new Promise(resolve => setTimeout(resolve, 1000));

    const pageText = await page.evaluate(() => document.body ? document.body.innerText : "");
    if (/Could not load accepted offer file|Missing accepted offer file ID|unauthorized|login|invalid auth/i.test(pageText)) {
      throw new Error("Local print.html loaded, but it still did not render the deal sheet. The print page may not accept the standard deal API JSON shape.");
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
    render_mode: "local_print_html_with_intercepted_deal_json",
    generated_at: new Date().toISOString()
  };
}'''

start, end = find_function(s, "ddAutoRenderPrintPageToPdf")
s = s[:start] + new_render + s[end:]

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

if old_call in s:
    s = s.replace(old_call, new_call, 1)
else:
    # Do not fail if a previous attempt already changed the call.
    if "ddAutoRenderPrintPageToPdf({" not in s:
      raise RuntimeError("Could not find ddAutoRenderPrintPageToPdf call.")
    if "render_mode: \"local_print_html_with_intercepted_deal_json\"" not in s:
      print("WARNING: render function replaced, but call block was not the expected shape.")

# Make sure shebang stays first.
lines = s.splitlines()
lines = [line for line in lines if line.strip() != "#!/usr/bin/env node"]
s = "#!/usr/bin/env node\n" + "\n".join(lines) + "\n"

SIDE.write_text(s, encoding="utf-8")
print("Patched ddAutoRenderPrintPageToPdf to use local print.html and intercepted deal JSON.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "Installed local print.html render fix."
echo ""
echo "CHECK RENDER MODE"
grep -n "local_print_html_with_intercepted_deal_json\|file://.*print.html\|setRequestInterception" "$SIDE" || echo "NO LOCAL PRINT RENDER MATCHES"

echo ""
echo "PM2"
pm2 status "$PM2_NAME"

echo ""
echo "Next test:"
echo "1. Go back to CLAIRE."
echo "2. Recreate the deal from the accepted-offer email."
echo "3. Watch the print/save/email status."
echo "4. If it fails, copy only the new failure message."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
