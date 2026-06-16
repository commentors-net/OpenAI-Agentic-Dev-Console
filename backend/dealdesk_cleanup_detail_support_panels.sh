#!/usr/bin/env bash
set -euo pipefail

DETAIL="/home/servicedepartmen/public_html/dealdesk/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/home/servicedepartmen/dealdesk-backend/backups/detail-support-panels-cleanup-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Cleaning detail.html support panels into one CSS block and one structured JS module..."
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
import re
import sys

DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")
html = DETAIL.read_text(encoding="utf-8", errors="replace")

def remove_marker_block(text, start, end):
    count = 0
    while True:
        s = text.find(start)
        e = text.find(end)
        if s >= 0 and e >= s:
            text = text[:s] + text[e + len(end):]
            count += 1
        else:
            break
    return text, count

removed = {}

marker_blocks = [
    ("DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1",
     "<!-- DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1 -->",
     "<!-- END_DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1 -->"),
    ("DEALDESK_CLAIRE_PDF_SOURCE_LINKS_V1",
     "<!-- DEALDESK_CLAIRE_PDF_SOURCE_LINKS_V1 -->",
     "<!-- END_DEALDESK_CLAIRE_PDF_SOURCE_LINKS_V1 -->"),
    ("DEALDESK_CLAIRE_INTAKE_READ_LINK_V1",
     "<!-- DEALDESK_CLAIRE_INTAKE_READ_LINK_V1 -->",
     "<!-- END_DEALDESK_CLAIRE_INTAKE_READ_LINK_V1 -->"),
    ("DEALDESK_GENERATED_SENT_DOCUMENTS_PANEL_FINAL",
     "<!-- DEALDESK_GENERATED_SENT_DOCUMENTS_PANEL_FINAL -->",
     "<!-- END_DEALDESK_GENERATED_SENT_DOCUMENTS_PANEL_FINAL -->"),
    ("DEALDESK_MOVE_GENERATED_SENT_DOCS_AFTER_SOURCE_DOCS_V1",
     "<!-- DEALDESK_MOVE_GENERATED_SENT_DOCS_AFTER_SOURCE_DOCS_V1 -->",
     "<!-- END_DEALDESK_MOVE_GENERATED_SENT_DOCS_AFTER_SOURCE_DOCS_V1 -->"),
    ("DEALDESK_LENDER_FINANCING_PANEL_V1",
     "<!-- DEALDESK_LENDER_FINANCING_PANEL_V1 -->",
     "<!-- END_DEALDESK_LENDER_FINANCING_PANEL_V1 -->"),
    ("DEALDESK_SUPPORT_PANELS_CLEAN_V1",
     "<!-- DEALDESK_SUPPORT_PANELS_CLEAN_V1 -->",
     "<!-- END_DEALDESK_SUPPORT_PANELS_CLEAN_V1 -->"),
]

for name, start, end in marker_blocks:
    html, count = remove_marker_block(html, start, end)
    removed[name] = count

# Remove old generic deal documents panel script by id.
html, count = re.subn(
    r'\n*<script\s+id=["\']claire-deal-documents-panel-v1["\'][\s\S]*?</script>\s*',
    '\n',
    html,
    flags=re.I
)
removed["claire-deal-documents-panel-v1"] = count

# Remove old support-panels CSS if a previous clean version exists.
html, count = re.subn(
    r'\n*<style\s+id=["\']dealdesk-support-panels-style["\'][\s\S]*?</style>\s*',
    '\n',
    html,
    flags=re.I
)
removed["dealdesk-support-panels-style"] = count

support_css = r'''
<style id="dealdesk-support-panels-style">
  /*
    Deal detail support panels
    Single style source for bottom/support panels:
    - Accepted Offer Source Documents
    - Generated / Sent Documents
    - CLAIRE Intake Read
    - Lender / Financing
  */
  .dd-support-stack {
    grid-column: 1 / -1;
    display: grid;
    gap: 18px;
    margin: 0 0 18px;
  }

  .dd-support-card {
    background: var(--card, #ffffff);
    border: 1px solid var(--line, #dbe3ee);
    border-radius: 16px;
    padding: 20px;
    box-shadow: 0 6px 20px rgba(23,32,51,.04);
  }

  .dd-support-card h2 {
    margin: 0 0 8px;
    font-size: 21px;
    color: var(--ink, #172033);
  }

  .dd-support-note {
    color: var(--muted, #64748b);
    font-size: 14px;
    line-height: 1.45;
    margin: 0 0 14px;
  }

  .dd-support-list {
    display: grid;
    gap: 10px;
  }

  .dd-support-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    background: #f8fafc;
    border: 1px solid #e2e8f0;
    border-radius: 12px;
    padding: 12px;
  }

  .dd-support-item-main {
    min-width: 0;
  }

  .dd-support-item-title {
    display: block;
    color: #0f172a;
    font-weight: 900;
    overflow-wrap: anywhere;
  }

  .dd-support-item-meta {
    display: block;
    color: var(--muted, #64748b);
    font-size: 12px;
    margin-top: 3px;
    line-height: 1.35;
  }

  .dd-support-action {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--accent, #0f766e);
    color: #ffffff !important;
    text-decoration: none !important;
    border-radius: 10px;
    padding: 9px 12px;
    font-weight: 900;
    white-space: nowrap;
    border: 0;
  }

  .dd-support-empty {
    border: 1px dashed #cbd5e1;
    background: #f8fafc;
    border-radius: 12px;
    padding: 12px;
    color: var(--muted, #64748b);
    line-height: 1.45;
  }

  .dd-support-fields {
    display: grid;
    gap: 8px;
  }

  .dd-support-field {
    display: grid;
    grid-template-columns: 190px minmax(0, 1fr);
    gap: 12px;
    padding: 9px 0;
    border-bottom: 1px solid var(--line, #dbe3ee);
  }

  .dd-support-field:last-child {
    border-bottom: 0;
  }

  .dd-support-label {
    color: var(--muted, #64748b);
    font-size: 13px;
    font-weight: 800;
  }

  .dd-support-value {
    font-size: 14px;
    line-height: 1.45;
    overflow-wrap: anywhere;
    color: var(--ink, #172033);
  }

  @media (max-width: 850px) {
    .dd-support-item {
      display: block;
    }

    .dd-support-action {
      margin-top: 10px;
    }

    .dd-support-field {
      grid-template-columns: 1fr;
      gap: 3px;
    }
  }
</style>
'''

support_js = r'''
<!-- DEALDESK_SUPPORT_PANELS_CLEAN_V1 -->
<script>
(function(){
  if (window.__dealdeskSupportPanelsCleanV1) return;
  window.__dealdeskSupportPanelsCleanV1 = true;

  function esc(v) {
    return String(v == null ? '' : v).replace(/[&<>"']/g, function(c) {
      return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c];
    });
  }

  function value(v) {
    if (v === null || v === undefined) return '';
    return String(v).trim();
  }

  function first() {
    for (var i = 0; i < arguments.length; i++) {
      var v = value(arguments[i]);
      if (v) return v;
    }
    return '';
  }

  function money(v) {
    if (v === null || v === undefined || v === '') return '';
    var n = Number(String(v).replace(/[^0-9.-]/g, ''));
    if (!Number.isFinite(n)) return String(v);
    return n.toLocaleString('en-US', { style:'currency', currency:'USD', maximumFractionDigits:0 });
  }

  function getDealId() {
    var p = new URLSearchParams(location.search);
    return p.get('id') || p.get('deal_id') || p.get('public_id') || '';
  }

  async function fetchJson(url) {
    var res = await fetch(url, { headers:{ Accept:'application/json' }, cache:'no-store' });
    var data = await res.json();
    if (!res.ok || data.ok === false) throw new Error(data.error || ('HTTP ' + res.status));
    return data;
  }

  async function loadDealRecord(id) {
    try {
      var data = await fetchJson('./api/deals/' + encodeURIComponent(id));
      return data.record || data.deal || data;
    } catch (err) {
      return null;
    }
  }

  function roleKey(p) {
    return String((p && (p.role_key || p.role || p.roleKey || p.party_role)) || '').toLowerCase();
  }

  function findParty(record, role) {
    var parties = record && (record.parties || record.deal_parties || record.contacts || []);
    if (!Array.isArray(parties)) return {};
    role = String(role || '').toLowerCase();

    for (var i = 0; i < parties.length; i++) {
      var p = parties[i] || {};
      if (roleKey(p) === role) return p;
    }

    if (role === 'lender') {
      for (var j = 0; j < parties.length; j++) {
        var q = parties[j] || {};
        var hay = [
          q.display_name, q.name, q.full_name, q.company_name, q.broker_name,
          q.email, q.role_key, q.role
        ].join(' ').toLowerCase();

        if (hay.indexOf('lender') !== -1 || hay.indexOf('loan') !== -1 || hay.indexOf('mortgage') !== -1 || hay.indexOf('rate') !== -1 || hay.indexOf('affinity') !== -1) {
          return q;
        }
      }
    }

    return {};
  }

  function supportCard(id, title, note, bodyHtml) {
    var section = document.createElement('section');
    section.id = id;
    section.className = 'dd-support-card';
    section.innerHTML =
      '<h2>' + esc(title) + '</h2>' +
      (note ? '<p class="dd-support-note">' + esc(note) + '</p>' : '') +
      bodyHtml;
    return section;
  }

  function supportItem(title, meta, href, actionText) {
    return '<div class="dd-support-item">' +
      '<div class="dd-support-item-main">' +
        '<strong class="dd-support-item-title">' + esc(title || 'Document') + '</strong>' +
        '<span class="dd-support-item-meta">' + esc(meta || '') + '</span>' +
      '</div>' +
      (href ? '<a class="dd-support-action" href="' + esc(href) + '" target="_blank" rel="noopener">' + esc(actionText || 'View') + '</a>' : '') +
    '</div>';
  }

  function supportField(label, val) {
    val = value(val);
    return '<div class="dd-support-field">' +
      '<div class="dd-support-label">' + esc(label) + '</div>' +
      '<div class="dd-support-value">' + esc(val || '—') + '</div>' +
    '</div>';
  }

  async function buildSourceDocumentsPanel(id) {
    var docs = [];
    var claireResult = null;

    try {
      var data = await fetchJson('./api/claire-dealview/source-docs?deal_id=' + encodeURIComponent(id));
      docs = data.source_documents || [];
      claireResult = data.claire_result || null;
    } catch (err) {}

    var body = '';
    if (docs.length) {
      body = '<div class="dd-support-list">' + docs.map(function(d) {
        return supportItem(d.filename || 'Source document', 'PDF source document', d.url, 'View PDF');
      }).join('') + '</div>';
    } else {
      body = '<div class="dd-support-empty">No CLAIRE PDF source links found yet. Recreate the deal from the CLAIRE reader or save source documents again.</div>';
    }

    if (claireResult) {
      var f = claireResult.dealdesk_fields || {};
      var bits = [];
      function list(label, arr) {
        if (!Array.isArray(arr) || !arr.length) return;
        bits.push('<div class="dd-support-item"><div class="dd-support-item-main"><strong class="dd-support-item-title">' + esc(label) + '</strong><span class="dd-support-item-meta">' + esc(arr.join(' | ')) + '</span></div></div>');
      }
      list('Notes', f.notes || claireResult.notes);
      list('Review Flags', f.review_flags || claireResult.review_flags);
      list('Missing Items', f.missing_items || claireResult.missing_items);
      if (bits.length) body += '<details style="margin-top:12px;"><summary style="cursor:pointer;font-weight:900;">CLAIRE Intake Notes</summary><div class="dd-support-list" style="margin-top:10px;">' + bits.join('') + '</div></details>';
    }

    return supportCard(
      'accepted-offer-source-documents',
      'Accepted Offer Source Documents',
      'Original PDFs and CLAIRE source documents preserved from intake.',
      body
    );
  }

  async function buildGeneratedDocumentsPanel(id) {
    var docs = [];

    try {
      var data = await fetchJson('./api/claire-dealview/generated-docs?deal_id=' + encodeURIComponent(id));
      docs = data.documents || [];
    } catch (err) {}

    var body = docs.length
      ? '<div class="dd-support-list">' + docs.map(function(d) {
          var meta = 'Status: ' + (d.email_status || 'created');
          if (d.email_to) meta += ' | Sent to: ' + d.email_to;
          if (d.email_subject) meta += ' | Subject: ' + d.email_subject;
          return supportItem(d.filename || 'Generated document', meta, d.url, 'View PDF');
        }).join('') + '</div>'
      : '<div class="dd-support-empty">No generated/sent documents yet. This section will show the printed Deal Sheet PDF after CLAIRE creates the deal and emails it.</div>';

    return supportCard(
      'generatedSentDocumentsPanel',
      'Generated / Sent Documents',
      'Documents Deal Desk creates from the accepted-offer file and sends automatically.',
      body
    );
  }

  function buildClaireIntakePanel(id) {
    var body = '<div class="dd-support-item">' +
      '<div class="dd-support-item-main">' +
        '<strong class="dd-support-item-title">CLAIRE Intake Read / Notes</strong>' +
        '<span class="dd-support-item-meta">Full CLAIRE document read, notes, flags, missing items, and conflicts preserved from intake.</span>' +
      '</div>' +
      '<a class="dd-support-action" href="./claire-intake-read.html?id=' + encodeURIComponent(id) + '">View Read</a>' +
    '</div>';

    return supportCard(
      'claire-intake-read-link-card',
      'CLAIRE Intake Read',
      'Full CLAIRE intake read and document notes for this accepted-offer file.',
      body
    );
  }

  function buildLenderPanel(record) {
    record = record || {};
    var deal = record.deal || record || {};
    var f = record.financials || {};
    var lender = findParty(record, 'lender');

    var lenderName = first(lender.display_name, lender.name, lender.full_name, lender.contact_name, lender.loan_officer_name, deal.lender_name, deal.loan_officer_name);
    var lenderCompany = first(lender.company_name, lender.broker_name, lender.lender_company, deal.lender_company, deal.lender, deal.financing_lender);
    var lenderEmail = first(lender.email, lender.email_address, lender.loan_officer_email, deal.lender_email, deal.loan_officer_email);
    var lenderPhone = first(lender.phone, lender.phone_number, lender.mobile, lender.loan_officer_phone, deal.lender_phone, deal.loan_officer_phone);
    var nmls = first(lender.nmls, lender.nmls_number, deal.nmls, deal.loan_officer_nmls);
    var mortgage = first(f.mortgage_amount, f.loan_amount, deal.mortgage_amount, deal.loan_amount);
    var preapprovalAmount = first(deal.preapproval_amount, deal.preapproval_offer_price, f.preapproval_amount);
    var financingStatus = first(deal.financing_status, deal.mortgage_status, deal.financing, f.financing_status);
    var contingency = first(deal.financing_contingency_length, deal.financing_contingency, f.financing_contingency_length);
    var expiration = first(deal.preapproval_expiration, f.preapproval_expiration);

    var fields =
      supportField('Lender / Company', lenderCompany) +
      supportField('Loan Officer / Contact', lenderName) +
      supportField('Email', lenderEmail) +
      supportField('Phone', lenderPhone) +
      supportField('NMLS', nmls) +
      supportField('Mortgage / Loan Amount', mortgage ? money(mortgage) : '') +
      supportField('Preapproval Amount', preapprovalAmount ? money(preapprovalAmount) : '') +
      supportField('Financing Status', financingStatus) +
      supportField('Financing Contingency', contingency) +
      supportField('Preapproval Expiration', expiration);

    return supportCard(
      'lenderFinancingPanel',
      'Lender / Financing',
      'Loan, lender, and financing information saved to this accepted-offer file.',
      '<div class="dd-support-fields">' + fields + '</div>'
    );
  }

  function removeOldPanels() {
    [
      'dealDocumentsPanel',
      'accepted-offer-source-documents',
      'generatedSentDocumentsPanel',
      'claire-intake-read-link-card',
      'lenderFinancingPanel',
      'dealdeskSupportPanelsStack'
    ].forEach(function(id) {
      var el = document.getElementById(id);
      if (el) el.remove();
    });

    Array.from(document.querySelectorAll('.claire-pdf-source-links-card,.claire-source-docs-card')).forEach(function(el) {
      el.remove();
    });
  }

  function findDangerZone() {
    return document.querySelector('.danger-zone') || Array.from(document.querySelectorAll('section,.card')).find(function(el) {
      return /remove accepted offer/i.test(el.textContent || '');
    });
  }

  async function renderSupportPanels() {
    var id = getDealId();
    if (!id) return;

    var danger = findDangerZone();
    if (!danger || !danger.parentNode) return;

    removeOldPanels();

    var record = await loadDealRecord(id);

    var stack = document.createElement('div');
    stack.id = 'dealdeskSupportPanelsStack';
    stack.className = 'dd-support-stack';

    var sourcePanel = await buildSourceDocumentsPanel(id);
    var generatedPanel = await buildGeneratedDocumentsPanel(id);
    var clairePanel = buildClaireIntakePanel(id);
    var lenderPanel = buildLenderPanel(record);

    stack.appendChild(sourcePanel);
    stack.appendChild(generatedPanel);
    stack.appendChild(clairePanel);
    stack.appendChild(lenderPanel);

    danger.parentNode.insertBefore(stack, danger);
  }

  function scheduleRender() {
    renderSupportPanels();
    var tries = 0;
    var timer = setInterval(function() {
      tries += 1;
      renderSupportPanels();
      if (tries >= 8) clearInterval(timer);
    }, 500);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', scheduleRender);
  } else {
    scheduleRender();
  }

  window.addEventListener('load', function() {
    setTimeout(scheduleRender, 800);
  });
})();
</script>
<!-- END_DEALDESK_SUPPORT_PANELS_CLEAN_V1 -->
'''

# Insert CSS just before closing head.
head_idx = html.lower().rfind("</head>")
if head_idx < 0:
    print("ERROR: Could not find </head> in detail.html")
    sys.exit(1)
html = html[:head_idx] + support_css + "\n" + html[head_idx:]

# Insert JS just before closing body.
body_idx = html.lower().rfind("</body>")
if body_idx < 0:
    print("ERROR: Could not find </body> in detail.html")
    sys.exit(1)
html = html[:body_idx] + support_js + "\n" + html[body_idx:]

DETAIL.write_text(html, encoding="utf-8")

print("Removed old scattered blocks:")
for key, value in removed.items():
    print(f" - {key}: {value}")
print("Installed one CSS block and one support-panels JS module.")
PY

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK CLEAN PATCH"
grep -n "dealdesk-support-panels-style\|DEALDESK_SUPPORT_PANELS_CLEAN_V1\|dd-support-card\|buildLenderPanel" "$DETAIL" || echo "NO CLEAN SUPPORT PANEL PATCH FOUND"

echo ""
echo "CHECK OLD SCATTERED BLOCKS REMOVED"
grep -n "DEALDESK_FORMAT_BOTTOM_BOXES_LIKE_GENERATED_V1\|DEALDESK_CLAIRE_PDF_SOURCE_LINKS_V1\|DEALDESK_CLAIRE_INTAKE_READ_LINK_V1\|DEALDESK_GENERATED_SENT_DOCUMENTS_PANEL_FINAL\|DEALDESK_MOVE_GENERATED_SENT_DOCS_AFTER_SOURCE_DOCS_V1\|DEALDESK_LENDER_FINANCING_PANEL_V1\|claire-deal-documents-panel-v1" "$DETAIL" || echo "Old scattered support-panel blocks removed."

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Done. Hard refresh the detail page."
echo "Expected order before Remove Accepted Offer:"
echo "1. Accepted Offer Source Documents"
echo "2. Generated / Sent Documents"
echo "3. CLAIRE Intake Read"
echo "4. Lender / Financing"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
