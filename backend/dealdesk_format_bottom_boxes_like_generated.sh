#!/usr/bin/env bash
set -euo pipefail

DETAIL="/home/servicedepartmen/public_html/dealdesk/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/home/servicedepartmen/dealdesk-backend/backups/format-bottom-boxes-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Formatting CLAIRE Intake Read and Lender / Financing boxes to match Generated / Sent Documents..."
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

DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")
html = DETAIL.read_text(encoding="utf-8", errors="replace")

start = "<!-- DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1 -->"
end = "<!-- END_DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1 -->"

while True:
    s = html.find(start)
    e = html.find(end)
    if s >= 0 and e >= s:
        html = html[:s] + html[e + len(end):]
    else:
        break

script = r'''
<!-- DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1 -->
<style>
  .dealdesk-generated-style-box {
    background: #ffffff !important;
    border: 1px solid #e2e8f0 !important;
    border-radius: 18px !important;
    padding: 18px !important;
    box-shadow: 0 10px 24px rgba(15, 23, 42, 0.06) !important;
    margin: 16px 0 !important;
  }

  .dealdesk-generated-style-box h2 {
    margin: 0 0 6px 0 !important;
    font-size: 20px !important;
    line-height: 1.2 !important;
    color: #0f172a !important;
    font-weight: 900 !important;
  }

  .dealdesk-generated-style-box .note,
  .dealdesk-generated-style-box p.note {
    margin: 0 0 12px 0 !important;
    color: #64748b !important;
    font-size: 13px !important;
    line-height: 1.45 !important;
    font-weight: 600 !important;
  }

  .dealdesk-generated-style-box a {
    text-decoration: none;
  }

  .dealdesk-generated-style-box .dealdesk-box-item,
  .dealdesk-generated-style-box .dealdesk-box-row-card {
    background: #f8fafc !important;
    border: 1px solid #e2e8f0 !important;
    border-radius: 12px !important;
    padding: 12px !important;
  }

  .dealdesk-generated-style-box .dealdesk-box-action {
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    background: #0f766e !important;
    color: #ffffff !important;
    text-decoration: none !important;
    border-radius: 10px !important;
    padding: 9px 12px !important;
    font-weight: 900 !important;
    white-space: nowrap !important;
    border: 0 !important;
  }
</style>

<script>
(function(){
  if (window.__dealdeskFormatBottomBoxesLikeGeneratedV1) return;
  window.__dealdeskFormatBottomBoxesLikeGeneratedV1 = true;

  function closestPanel(el){
    return el && (
      el.closest('section,.card,.panel,.deal-section,.detail-section,[class*="card"],[class*="panel"],[class*="section"]') ||
      el.parentElement
    );
  }

  function findPanelByText(needle){
    var wanted = String(needle || '').toLowerCase();
    var nodes = Array.from(document.querySelectorAll('h1,h2,h3,h4,section,.card,.panel,div'));
    for (var i = 0; i < nodes.length; i++) {
      var txt = (nodes[i].textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
      if (txt.indexOf(wanted) !== -1) return closestPanel(nodes[i]);
    }
    return null;
  }

  function styleLikeGenerated(panel){
    if (!panel) return;
    panel.classList.add('dealdesk-generated-style-box');

    if (!panel.classList.contains('card')) panel.classList.add('card');
    if (!panel.classList.contains('full')) panel.classList.add('full');
  }

  function styleClaireIntake(panel){
    if (!panel) return;
    styleLikeGenerated(panel);

    var links = Array.from(panel.querySelectorAll('a,button'));
    links.forEach(function(a){
      var txt = (a.textContent || '').toLowerCase();
      if (txt.indexOf('view') !== -1 || txt.indexOf('read') !== -1 || txt.indexOf('claire') !== -1 || a.tagName === 'BUTTON') {
        a.classList.add('dealdesk-box-action');
      }
    });

    var looseDivs = Array.from(panel.querySelectorAll('div'));
    looseDivs.forEach(function(d){
      var txt = (d.textContent || '').trim();
      if (txt && txt.length > 20 && !d.querySelector('h1,h2,h3,h4') && !d.classList.contains('dealdesk-generated-style-box')) {
        if (d.parentElement === panel || d.parentElement && d.parentElement.parentElement === panel) {
          d.classList.add('dealdesk-box-item');
        }
      }
    });
  }

  function styleLender(panel){
    if (!panel) return;
    styleLikeGenerated(panel);

    // The lender panel has field rows. Keep the grid rows, but place them inside the same
    // soft card treatment used by Generated / Sent Documents.
    var rows = Array.from(panel.querySelectorAll('div')).filter(function(d){
      var style = d.getAttribute('style') || '';
      return style.indexOf('grid-template-columns') !== -1 || style.indexOf('border-bottom') !== -1;
    });

    rows.forEach(function(row){
      row.style.background = '#f8fafc';
      row.style.border = '1px solid #e2e8f0';
      row.style.borderRadius = '12px';
      row.style.padding = '10px 12px';
      row.style.margin = '8px 0';
      row.style.boxSizing = 'border-box';
    });
  }

  function run(){
    var generated =
      document.getElementById('generatedSentDocumentsPanel') ||
      findPanelByText('Generated / Sent Documents');

    styleLikeGenerated(generated);

    var claire =
      document.getElementById('claireIntakeReadPanel') ||
      document.getElementById('claire-intake-read-panel') ||
      findPanelByText('CLAIRE Intake Read');

    var lender =
      document.getElementById('lenderFinancingPanel') ||
      findPanelByText('Lender / Financing');

    styleClaireIntake(claire);
    styleLender(lender);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }

  var tries = 0;
  var timer = setInterval(function(){
    tries += 1;
    run();
    if (tries >= 40) clearInterval(timer);
  }, 250);

  try {
    var observer = new MutationObserver(run);
    observer.observe(document.body, { childList: true, subtree: true });
    setTimeout(function(){ observer.disconnect(); }, 12000);
  } catch (err) {}
})();
</script>
<!-- END_DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1 -->
'''

idx = html.lower().rfind("</body>")
if idx >= 0:
    html = html[:idx] + script + "\n" + html[idx:]
else:
    html += "\n" + script

DETAIL.write_text(html, encoding="utf-8")
print("Patched detail.html bottom-box formatting.")
PY

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK PATCH"
grep -n "DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1\|dealdesk-generated-style-box\|styleClaireIntake\|styleLender" "$DETAIL" || echo "NO FORMAT PATCH FOUND"

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Done. Hard refresh the deal detail page."
echo "CLAIRE Intake Read and Lender / Financing should now match the Generated / Sent Documents box style."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
