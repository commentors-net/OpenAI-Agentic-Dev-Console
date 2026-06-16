#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
SIDE="$BACKEND/claire_dealview_sidecar.js"
GEN_ROOT="/home/servicedepartmen/public_html/dealdesk/generated-docs"
MANIFEST_DIR="$GEN_ROOT/manifests"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/generated-docs-strict-record-binding-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Fixing Generated / Sent Documents so PDFs bind only to the current deal record ID..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

if [ ! -f "$SIDE" ]; then
  echo "Missing sidecar: $SIDE"
  exit 1
fi

cp -f "$SIDE" "$BACKUP_DIR/claire_dealview_sidecar.js.before-$STAMP.bak"

if [ -d "$MANIFEST_DIR" ]; then
  mkdir -p "$BACKUP_DIR/manifests"
  cp -f "$MANIFEST_DIR"/*.json "$BACKUP_DIR/manifests/" 2>/dev/null || true
fi

python3 - <<'PY'
from pathlib import Path
import json
import re
import sys
import time

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
GEN_ROOT = Path("/home/servicedepartmen/public_html/dealdesk/generated-docs")
MANIFEST_DIR = GEN_ROOT / "manifests"

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)

def find_function(src, name):
    for marker in (f"function {name}", f"async function {name}"):
        start = src.find(marker)
        if start >= 0:
            break
    else:
        raise RuntimeError(f"Could not find function {name}")

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

side = SIDE.read_text(encoding="utf-8", errors="replace")

strict_find = r'''function ddAutoFindManifest(aliases) {
  const clean = Array.from(new Set((aliases || [])
    .filter(Boolean)
    .map(v => String(v).trim())
    .filter(Boolean)));

  // Strict record binding:
  // Generated / Sent Documents must be found only by the exact deal record id
  // or an exact alias intentionally written for that same deal.
  // Do NOT scan all manifests by property text, because that cross-links
  // generated PDFs from older retry deals into newly-created deals.
  for (const alias of clean) {
    const direct = ddAutoManifestPath(alias);
    if (fs.existsSync(direct)) return ddAutoReadJson(direct);
  }

  return null;
}'''

try:
    start, end = find_function(side, "ddAutoFindManifest")
    side = side[:start] + strict_find + side[end:]
except Exception as e:
    print("ERROR replacing ddAutoFindManifest:", e)
    sys.exit(1)

side = side.replace("ddAutoFindManifest([dealPublicId, dealId, property])", "ddAutoFindManifest([dealPublicId, dealId])")
side = side.replace("ddAutoWriteManifest(manifest, [dealPublicId, dealId, property, manifest.folder])", "ddAutoWriteManifest(manifest, [dealPublicId, dealId, manifest.folder])")
side = side.replace("ddAutoWriteManifest(manifest, [dealPublicId, dealId, property])", "ddAutoWriteManifest(manifest, [dealPublicId, dealId])")

old_docs_block = '''const docs = Array.isArray(manifest.documents) ? manifest.documents : [];
  manifest.documents = [
    Object.assign({}, safePdf, {
      email_status: "sent",
      email_sent_at: email.sent_at,
      email_to: email.to,
      email_subject: email.subject
    }),
    ...docs.filter(d => d.relative_path !== pdf.relative_path)
  ];'''

new_docs_block = '''const docs = Array.isArray(manifest.documents) ? manifest.documents : [];
  const pdfFolder = String(pdf.relative_path || "").split(path.sep)[0] || "";
  const currentGeneratedPdf = Object.assign({}, safePdf, {
      email_status: "sent",
      email_sent_at: email.sent_at,
      email_to: email.to,
      email_subject: email.subject
    });

  // Strict record binding:
  // Keep non-generated docs, but never carry generated Deal Sheet PDFs
  // from a different deal folder into this record's manifest.
  const cleanedExistingDocs = docs.filter(d => {
    const rel = String((d && d.relative_path) || "");
    const fn = String((d && d.filename) || "");
    const cat = String((d && d.category) || "");
    const isPdf = rel.toLowerCase().endsWith(".pdf") || fn.toLowerCase().endsWith(".pdf");
    const isGeneratedDealSheet = cat === "generated_print_deal_sheet" || rel.toLowerCase().includes("deal-sheet") || fn.toLowerCase().includes("deal-sheet");
    if (!(isPdf && isGeneratedDealSheet)) return true;
    if (!pdfFolder) return false;
    return rel.startsWith(pdfFolder + path.sep) && rel !== pdf.relative_path;
  });

  manifest.documents = [
    currentGeneratedPdf,
    ...cleanedExistingDocs
  ];'''

if old_docs_block in side:
    side = side.replace(old_docs_block, new_docs_block, 1)
else:
    print("WARNING: standard generated-doc preservation block was not found. Alias binding was still patched.")

lines = side.splitlines()
lines = [line for line in lines if line.strip() != "#!/usr/bin/env node"]
side = "#!/usr/bin/env node\n" + "\n".join(lines) + "\n"
SIDE.write_text(side, encoding="utf-8")
print("Patched sidecar strict generated-doc manifest binding.")

cleaned = []
if MANIFEST_DIR.exists():
    for mf in sorted(MANIFEST_DIR.glob("*.json")):
        stem = mf.stem
        if not UUID_RE.match(stem):
            continue

        try:
            data = json.loads(mf.read_text())
        except Exception:
            continue

        docs = data.get("documents") or []
        if not isinstance(docs, list):
            continue

        changed = False
        new_docs = []
        generated_for_this_manifest = []

        for d in docs:
            if not isinstance(d, dict):
                new_docs.append(d)
                continue

            rel = str(d.get("relative_path") or "")
            fn = str(d.get("filename") or "")
            cat = str(d.get("category") or "")
            lower_rel = rel.lower()
            lower_fn = fn.lower()

            is_pdf = lower_rel.endswith(".pdf") or lower_fn.endswith(".pdf")
            is_generated = cat == "generated_print_deal_sheet" or "deal-sheet" in lower_rel or "deal-sheet" in lower_fn

            if is_pdf and is_generated:
                first_folder = rel.split("/", 1)[0].split("\\", 1)[0]
                if first_folder == stem:
                    generated_for_this_manifest.append(d)
                else:
                    changed = True
                continue

            new_docs.append(d)

        if generated_for_this_manifest:
            def ts_key(d):
                return str(d.get("generated_at") or d.get("email_sent_at") or "")
            generated_for_this_manifest.sort(key=ts_key, reverse=True)
            new_docs.insert(0, generated_for_this_manifest[0])
            if len(generated_for_this_manifest) > 1:
                changed = True

        if changed:
            data["documents"] = new_docs
            data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            mf.write_text(json.dumps(data, indent=2), encoding="utf-8")
            cleaned.append(str(mf))

print("Cleaned UUID manifests:", len(cleaned))
for item in cleaned[:40]:
    print(" -", item)
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "Installed strict generated-doc record binding."
echo ""
echo "CHECK SIDECAR PATCH"
grep -n "Strict record binding\|ddAutoFindManifest(aliases)\|cleanedExistingDocs" "$SIDE" || echo "NO STRICT BINDING MATCHES"

echo ""
echo "PM2"
pm2 status "$PM2_NAME"

echo ""
echo "Done. Hard refresh the detail page."
echo "Going forward, generated Deal Sheet PDFs should show only for the current deal record id."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
