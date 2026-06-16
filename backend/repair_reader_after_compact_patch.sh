#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
HTML="$APPDIR/claire-dealdesk-view.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/repair-reader-after-compact-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Repairing CLAIRE reader after compact/speed patch..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

if [ -f "$SIDE" ]; then
  cp -f "$SIDE" "$BACKUP_DIR/claire_dealview_sidecar.js.broken-$STAMP.bak"
fi
if [ -f "$HTML" ]; then
  cp -f "$HTML" "$BACKUP_DIR/claire-dealdesk-view.html.before-repair-$STAMP.bak"
fi

# Restore sidecar from the backup taken before the compact-output patch, because that patch touched the reader prompt.
LATEST_SIDE_BACKUP="$(ls -1t "$BACKEND"/backups/compact-additional-terms-reset-maidstone-*/claire_dealview_sidecar.js.before-*.bak 2>/dev/null | head -n 1 || true)"

if [ -z "$LATEST_SIDE_BACKUP" ]; then
  echo "ERROR: Could not find compact patch sidecar backup."
  echo "Run this and paste output:"
  echo "ls -1t $BACKEND/backups/*/claire_dealview_sidecar.js*.bak | head -20"
  exit 1
fi

cp -f "$LATEST_SIDE_BACKUP" "$SIDE"

python3 - <<'PY'
from pathlib import Path
import sys

HTML = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")

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

if not HTML.exists():
    print("ERROR: Missing CLAIRE HTML")
    sys.exit(1)

html = HTML.read_text(encoding="utf-8", errors="replace")

# Keep the safe part: compact Additional Terms on the create-deal payload.
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

html, replaced = replace_js_function(html, "function makeAdditionalTerms", compact_make_terms)
if not replaced:
    print("WARNING: makeAdditionalTerms function not found; compact terms not patched.")

# Keep inspection as Open/contingency only in payload.
html = html.replace('inspection_status: "Complete",', 'inspection_status: "Open",')
html = html.replace('inspection_status:"Complete",', 'inspection_status:"Open",')

HTML.write_text(html, encoding="utf-8")
print("Safe compact Additional Terms patch applied to HTML only.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Reader repair complete."
echo ""
echo "Restored sidecar from:"
echo "$LATEST_SIDE_BACKUP"
echo ""
echo "Kept safe change:"
echo "- Additional Terms is compacted in the Create Deal File screen only."
echo ""
echo "Removed risky change:"
echo "- Compact model prompt / reader-side speed patch that likely caused the read failure."
echo ""
echo "Test:"
echo "1. Open https://servicedepartment.ai/dealdesk/claire-dealdesk-view.html"
echo "2. Select the Maidstone email"
echo "3. Click Read Selected Email"
echo "4. Then Create Deal File"
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
