#!/usr/bin/env bash
set -euo pipefail

DETAIL="/home/servicedepartmen/public_html/dealdesk/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/home/servicedepartmen/dealdesk-backend/backups/move-generated-docs-section-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Moving Generated / Sent Documents below Accepted Offer Source Documents..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

if [ ! -f "$DETAIL" ]; then
  echo "Missing detail page: $DETAIL"
  exit 1
fi

cp -f "$DETAIL" "$BACKUP_DIR/detail.html.before-$STAMP.bak"

python3 - <<'PY'
from pathlib import Path
import sys

DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")
html = DETAIL.read_text(encoding="utf-8", errors="replace")

start = "<!-- DEALDESK_MOVE_GENERATED_SENT_DOCS_AFTER_SOURCE_DOCS_V1 -->"
end = "<!-- END_DEALDESK_MOVE_GENERATED_SENT_DOCS_AFTER_SOURCE_DOCS_V1 -->"

while True:
    s = html.find(start)
    e = html.find(end)
    if s >= 0 and e >= s:
        html = html[:s] + html[e + len(end):]
    else:
        break

script = r'''
<!-- DEALDESK_MOVE_GENERATED_SENT_DOCS_AFTER_SOURCE_DOCS_V1 -->
<script>
(function(){
  if (window.__dealdeskMoveGeneratedSentDocsAfterSourceDocsV1) return;
  window.__dealdeskMoveGeneratedSentDocsAfterSourceDocsV1 = true;

  function closestPanel(el){
    return el && (
      el.closest('section,.card,.panel,.deal-section,.detail-section,[class*="card"],[class*="panel"],[class*="section"]') ||
      el.parentElement
    );
  }

  function findPanelByHeadingText(text){
    var wanted = String(text || '').toLowerCase();
    var nodes = Array.from(document.querySelectorAll('h1,h2,h3,h4,section,.card,.panel,div'));
    for (var i = 0; i < nodes.length; i++) {
      var t = (nodes[i].textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
      if (t.indexOf(wanted) !== -1) return closestPanel(nodes[i]);
    }
    return null;
  }

  function moveGeneratedAfterSourceDocs(){
    var generated =
      document.getElementById('generatedSentDocumentsPanel') ||
      findPanelByHeadingText('Generated / Sent Documents');

    var source =
      document.getElementById('accepted-offer-source-documents') ||
      findPanelByHeadingText('Accepted Offer Source Documents');

    if (!generated || !source || generated === source) return false;
    if (!source.parentNode) return false;

    if (source.nextSibling !== generated) {
      source.parentNode.insertBefore(generated, source.nextSibling);
    }

    return true;
  }

  function runForAwhile(){
    moveGeneratedAfterSourceDocs();
    var tries = 0;
    var timer = setInterval(function(){
      tries += 1;
      moveGeneratedAfterSourceDocs();
      if (tries >= 40) clearInterval(timer);
    }, 250);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', runForAwhile);
  } else {
    runForAwhile();
  }

  try {
    var observer = new MutationObserver(function(){
      moveGeneratedAfterSourceDocs();
    });
    observer.observe(document.body, { childList: true, subtree: true });
    setTimeout(function(){ observer.disconnect(); }, 12000);
  } catch (err) {}
})();
</script>
<!-- END_DEALDESK_MOVE_GENERATED_SENT_DOCS_AFTER_SOURCE_DOCS_V1 -->
'''

idx = html.lower().rfind("</body>")
if idx >= 0:
    html = html[:idx] + script + "\n" + html[idx:]
else:
    html += "\n" + script

DETAIL.write_text(html, encoding="utf-8")
print("Patched detail.html with section-order mover.")
PY

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK PATCH"
grep -n "DEALDESK_MOVE_GENERATED_SENT_DOCS_AFTER_SOURCE_DOCS_V1\|moveGeneratedAfterSourceDocs" "$DETAIL" || echo "NO MOVE PATCH FOUND"

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Done. Hard refresh the deal detail page."
echo "Generated / Sent Documents should now sit directly below Accepted Offer Source Documents."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
