#!/usr/bin/env bash
set -euo pipefail

DETAIL="/home/servicedepartmen/public_html/dealdesk/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/home/servicedepartmen/dealdesk-backend/backups/revert-bottom-box-formatting-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Reverting only the bottom-box formatting patch..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

if [ ! -f "$DETAIL" ]; then
  echo "Missing detail page: $DETAIL"
  exit 1
fi

cp -f "$DETAIL" "$BACKUP_DIR/detail.html.before-revert-$STAMP.bak"

python3 - <<'PY'
from pathlib import Path
import sys

DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")
html = DETAIL.read_text(encoding="utf-8", errors="replace")

start = "<!-- DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1 -->"
end = "<!-- END_DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1 -->"

removed = 0
while True:
    s = html.find(start)
    e = html.find(end)
    if s >= 0 and e >= s:
        html = html[:s] + html[e + len(end):]
        removed += 1
    else:
        break

DETAIL.write_text(html, encoding="utf-8")

print("Removed formatting patch blocks:", removed)
if removed == 0:
    print("NOTE: No DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1 block was found.")
    print("If the page is still broken, restore from the backup made by that patch:")
    print("/home/servicedepartmen/dealdesk-backend/backups/format-bottom-boxes-*")
PY

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "REVERT CHECK"
grep -n "DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1\|dealdesk-generated-style-box\|styleClaireIntake\|styleLender" "$DETAIL" || echo "Formatting patch removed."

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Hard refresh the detail page."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
