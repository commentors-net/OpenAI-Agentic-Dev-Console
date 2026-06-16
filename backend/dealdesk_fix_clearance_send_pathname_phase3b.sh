#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
SIDE="$BACKEND/claire_dealview_sidecar.js"
PM2_NAME="dealdesk-claire-dealview"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKEND/backups/fix-clearance-send-pathname-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Fixing Phase 3 send proxy bug: pathname is not defined..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

if [ ! -f "$SIDE" ]; then
  echo "Missing CLAIRE sidecar: $SIDE"
  exit 1
fi

cp -f "$SIDE" "$BACKUP_DIR/claire_dealview_sidecar.js.before-$STAMP.bak"

python3 - <<'PY'
from pathlib import Path
import re
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
side = SIDE.read_text(encoding="utf-8", errors="replace")

old = "if (req.method === 'POST' && pathname === '/api/claire-dealview/send-clearance-email') {"
new = "if (req.method === 'POST' && (typeof pathname !== 'undefined' ? pathname : new URL(req.url, 'http://127.0.0.1').pathname) === '/api/claire-dealview/send-clearance-email') {"

if old in side:
    side = side.replace(old, new, 1)
elif new in side:
    print("Safe pathname condition already installed.")
else:
    # More flexible repair if whitespace changed.
    pattern = re.compile(
        r"if\s*\(\s*req\.method\s*===\s*['\"]POST['\"]\s*&&\s*pathname\s*===\s*['\"]/api/claire-dealview/send-clearance-email['\"]\s*\)\s*\{"
    )
    side, count = pattern.subn(new, side, count=1)
    if count == 0:
        print("ERROR: Could not find the unsafe send-clearance-email pathname condition.")
        sys.exit(1)

# Keep shebang first if present.
lines = side.splitlines()
shebang = ""
out = []
for line in lines:
    if line.strip() == "#!/usr/bin/env node":
        shebang = "#!/usr/bin/env node"
    else:
        out.append(line)
side = (shebang + "\n" if shebang else "") + "\n".join(out) + "\n"

SIDE.write_text(side, encoding="utf-8")
print("Patched unsafe pathname reference in send-clearance-email route.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK PATCH"
grep -n "send-clearance-email\|typeof pathname\|DEALDESK_CLEARANCE_EMAIL_SEND_PROXY_V1" "$SIDE" | head -n 80 || echo "NO SEND PROXY PATCH FOUND"

echo ""
echo "LOCAL ROUTE TEST - should return JSON now, not 'pathname is not defined'"
curl -s -i -X POST "http://127.0.0.1:3022/api/claire-dealview/send-clearance-email" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  --data '{"email_id":"TEST-NONEXISTENT","from_email":"teamscher@servicedepartment.ai"}' \
  | head -n 40

echo ""
echo "PM2"
pm2 status "$PM2_NAME"

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Done. Hard refresh the detail page and click Send Email again from the same clearance box."
echo "If it errors now, paste the exact in-box error. It should be the real backend send-route result, not pathname/Apache HTML."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
