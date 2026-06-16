#!/usr/bin/env bash
set -euo pipefail

APPDIR="/home/servicedepartmen/public_html/dealdesk"
BACKEND="/home/servicedepartmen/dealdesk-backend"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$APPDIR/backups/claire-integrate-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Adding CLAIRE Deal Desk View into Deal Desk navigation..."
echo "Appdir: $APPDIR"
echo "Backup: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

if [ ! -f "$APPDIR/claire-dealdesk-view.html" ]; then
  echo "ERROR: Missing $APPDIR/claire-dealdesk-view.html"
  echo "Install the working CLAIRE Deal Desk View first."
  exit 1
fi

DD_CLAIRE_BACKUP_DIR="$BACKUP_DIR" python3 - <<'PY'
from pathlib import Path
import shutil

APPDIR = Path("/home/servicedepartmen/public_html/dealdesk")
import os
BACKUP_DIR = Path(os.environ.get("DD_CLAIRE_BACKUP_DIR", "/home/servicedepartmen/public_html/dealdesk/backups/claire-integrate-manual"))
BACKUP_DIR.mkdir(parents=True, exist_ok=True)

STAMP = "__STAMP__"

marker = "DEALDESK_CLAIRE_INTEGRATION_V1"

launcher = f"""
<!-- {marker} -->
<style id="dealdesk-claire-integration-style">
  .dd-claire-launcher {{
    position: fixed;
    right: 18px;
    bottom: 18px;
    z-index: 2147483000;
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 12px 16px;
    border-radius: 999px;
    background: #071b2c;
    color: #ffffff !important;
    text-decoration: none !important;
    font-family: Arial, Helvetica, sans-serif;
    font-size: 14px;
    font-weight: 800;
    box-shadow: 0 12px 32px rgba(7, 27, 44, .28);
    border: 2px solid #14b8a6;
  }}
  .dd-claire-launcher:hover {{
    transform: translateY(-1px);
    box-shadow: 0 16px 38px rgba(7, 27, 44, .34);
  }}
  .dd-claire-launcher span {{
    display: inline-block;
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: #14b8a6;
  }}
  @media print {{
    .dd-claire-launcher {{ display: none !important; }}
  }}
</style>
<a class="dd-claire-launcher" href="./claire-dealdesk-view.html" title="Open CLAIRE Deal Desk View">
  <span></span>
  CLAIRE Intake Reader
</a>
<!-- END_{marker} -->
"""

top_nav = f"""
<!-- {marker}_TOPNAV -->
<style id="dealdesk-claire-topnav-style">
  .dd-claire-topnav {{
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    padding: 12px 18px;
    background: #ffffff;
    border-bottom: 1px solid #dbe5ef;
    font-family: Arial, Helvetica, sans-serif;
  }}
  .dd-claire-topnav .left,
  .dd-claire-topnav .right {{
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    align-items: center;
  }}
  .dd-claire-topnav a {{
    display: inline-flex;
    align-items: center;
    padding: 9px 12px;
    border-radius: 10px;
    background: #e6eef7;
    color: #102a43 !important;
    text-decoration: none !important;
    font-weight: 800;
    font-size: 13px;
  }}
  .dd-claire-topnav a.primary {{
    background: #071b2c;
    color: #ffffff !important;
    border: 2px solid #14b8a6;
  }}
  .dd-claire-topnav .label {{
    font-weight: 900;
    color: #344054;
    font-size: 13px;
  }}
  @media print {{
    .dd-claire-topnav {{ display: none !important; }}
  }}
</style>
<div class="dd-claire-topnav">
  <div class="left">
    <span class="label">CLAIRE Deal Desk View</span>
    <a href="./dashboard.html">Command Center</a>
    <a href="./input.html">New Accepted Offer</a>
    <a href="./index.html">Home</a>
  </div>
  <div class="right">
    <a class="primary" href="./claire-dealdesk-view.html">Refresh CLAIRE View</a>
  </div>
</div>
<!-- END_{marker}_TOPNAV -->
"""

def backup(path: Path):
    if path.exists():
        shutil.copy2(path, BACKUP_DIR / path.name)

def inject_before_body(path: Path, snippet: str):
    if not path.exists():
        return False
    text = path.read_text(encoding="utf-8", errors="replace")
    if marker in text:
        return False
    backup(path)
    lower = text.lower()
    idx = lower.rfind("</body>")
    if idx >= 0:
        text = text[:idx] + snippet + "\n" + text[idx:]
    else:
        text += "\n" + snippet + "\n"
    path.write_text(text, encoding="utf-8")
    return True

def inject_after_header(path: Path, snippet: str):
    if not path.exists():
        return False
    text = path.read_text(encoding="utf-8", errors="replace")
    if f"{marker}_TOPNAV" in text:
        return False
    backup(path)
    lower = text.lower()
    idx = lower.find("</header>")
    if idx >= 0:
        idx += len("</header>")
        text = text[:idx] + "\n" + snippet + "\n" + text[idx:]
    else:
        body_idx = lower.find("<body")
        if body_idx >= 0:
            close = text.find(">", body_idx)
            if close >= 0:
                text = text[:close+1] + "\n" + snippet + "\n" + text[close+1:]
            else:
                text = snippet + "\n" + text
        else:
            text = snippet + "\n" + text
    path.write_text(text, encoding="utf-8")
    return True

# Add launcher to normal Deal Desk pages.
candidates = [
    "index.html",
    "dashboard.html",
    "input.html",
    "detail.html",
    "contacts-finder.html",
    "contacts-finder-command-center-exact.html",
]

changed = []
for name in candidates:
    p = APPDIR / name
    if inject_before_body(p, launcher):
        changed.append(name)

# Add navigation to the CLAIRE page itself.
if inject_after_header(APPDIR / "claire-dealdesk-view.html", top_nav):
    changed.append("claire-dealdesk-view.html")

# Create short alias.
alias = APPDIR / "claire.html"
backup(alias)
alias.write_text("""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>CLAIRE Intake Reader</title>
  <meta http-equiv="refresh" content="0; url=./claire-dealdesk-view.html">
  <script>location.replace("./claire-dealdesk-view.html");</script>
</head>
<body>
  <p><a href="./claire-dealdesk-view.html">Open CLAIRE Intake Reader</a></p>
</body>
</html>
""", encoding="utf-8")
changed.append("claire.html")

print("Changed files:")
for c in changed:
    print("-", c)

if not changed:
    print("- none")
PY

# Replace placeholder in generated Python backup path if needed
# The Python block used a literal placeholder because heredoc is quoted; fix backup folder names created by it.
BAD="$APPDIR/backups/claire-integrate-__STAMP__"
if [ -d "$BAD" ]; then
  find "$BAD" -maxdepth 1 -type f -exec cp -f {} "$BACKUP_DIR"/ \;
  rm -rf "$BAD"
fi

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "CLAIRE is now linked inside Deal Desk."
echo ""
echo "Open main Deal Desk:"
echo "https://servicedepartment.ai/dealdesk/"
echo ""
echo "Open CLAIRE directly:"
echo "https://servicedepartment.ai/dealdesk/claire.html"
echo "https://servicedepartment.ai/dealdesk/claire-dealdesk-view.html"
echo ""
echo "Backups:"
echo "$BACKUP_DIR"
echo ""
echo "No server.js changes. No MySQL writes. No deal creation yet."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
