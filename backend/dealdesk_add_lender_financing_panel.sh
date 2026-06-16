#!/usr/bin/env bash
set -euo pipefail

DETAIL="/home/servicedepartmen/public_html/dealdesk/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/home/servicedepartmen/dealdesk-backend/backups/add-lender-financing-panel-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Adding Lender / Financing panel to deal detail page..."
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

start = "<!-- DEALDESK_LENDER_FINANCING_PANEL_V1 -->"
end = "<!-- END_DEALDESK_LENDER_FINANCING_PANEL_V1 -->"

while True:
    s = html.find(start)
    e = html.find(end)
    if s >= 0 and e >= s:
        html = html[:s] + html[e + len(end):]
    else:
        break

script = r'''
<!-- DEALDESK_LENDER_FINANCING_PANEL_V1 -->
<script>
(function(){
  if (window.__dealdeskLenderFinancingPanelV1) return;
  window.__dealdeskLenderFinancingPanelV1 = true;

  function esc(v){
    return String(v == null ? '' : v).replace(/[&<>"']/g, function(c){
      return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c];
    });
  }

  function money(v){
    if (v === null || v === undefined || v === '') return '';
    var n = Number(String(v).replace(/[^0-9.-]/g,''));
    if (!Number.isFinite(n)) return String(v);
    return n.toLocaleString('en-US', { style:'currency', currency:'USD', maximumFractionDigits:0 });
  }

  function value(v){
    if (v === null || v === undefined) return '';
    return String(v).trim();
  }

  function first(){
    for (var i = 0; i < arguments.length; i++) {
      var v = value(arguments[i]);
      if (v) return v;
    }
    return '';
  }

  function getDealId(){
    var p = new URLSearchParams(location.search);
    return p.get('id') || p.get('deal_id') || p.get('public_id') || '';
  }

  function roleKey(p){
    return String((p && (p.role_key || p.role || p.roleKey || p.party_role)) || '').toLowerCase();
  }

  function findParty(record, role){
    var parties = record && (record.parties || record.deal_parties || record.contacts || []);
    if (!Array.isArray(parties)) return {};
    role = String(role || '').toLowerCase();

    for (var i = 0; i < parties.length; i++) {
      var p = parties[i] || {};
      var rk = roleKey(p);
      if (rk === role) return p;
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

  function row(label, val){
    val = value(val);
    return '<div style="display:grid;grid-template-columns:190px minmax(0,1fr);gap:8px;padding:7px 0;border-bottom:1px solid #eef2f7;">' +
      '<div style="font-size:12px;color:#64748b;font-weight:800;text-transform:uppercase;letter-spacing:.04em;">' + esc(label) + '</div>' +
      '<div style="font-weight:800;color:#0f172a;overflow-wrap:anywhere;">' + esc(val || '—') + '</div>' +
    '</div>';
  }

  function closestPanel(el){
    return el && (
      el.closest('section,.card,.panel,.deal-section,.detail-section,[class*="card"],[class*="panel"],[class*="section"]') ||
      el.parentElement
    );
  }

  function findPanelByText(needles){
    var nodes = Array.from(document.querySelectorAll('h1,h2,h3,h4,section,.card,.panel,div'));
    for (var i = 0; i < nodes.length; i++) {
      var txt = (nodes[i].textContent || '').replace(/\s+/g,' ').trim().toLowerCase();
      if (!txt) continue;
      for (var j = 0; j < needles.length; j++) {
        if (txt.indexOf(String(needles[j]).toLowerCase()) !== -1) return closestPanel(nodes[i]);
      }
    }
    return null;
  }

  function buildPanel(record){
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

    var hasAny = [
      lenderName, lenderCompany, lenderEmail, lenderPhone, nmls,
      mortgage, preapprovalAmount, financingStatus, contingency, expiration
    ].some(function(v){ return value(v); });

    var panel = document.createElement('section');
    panel.id = 'lenderFinancingPanel';
    panel.className = 'card full';
    panel.innerHTML =
      '<h2>Lender / Financing</h2>' +
      '<p class="note">Loan, lender, and financing information saved to this accepted-offer file.</p>' +
      (!hasAny ? '<div class="note" style="padding:12px;border:1px solid #e2e8f0;border-radius:12px;background:#f8fafc;">No lender / financing details are saved on this deal yet. If CLAIRE extracted lender information, the next fix is the Create Deal File mapping/backfill.</div>' : '') +
      '<div style="margin-top:10px;">' +
        row('Lender / Company', lenderCompany) +
        row('Loan Officer / Contact', lenderName) +
        row('Email', lenderEmail) +
        row('Phone', lenderPhone) +
        row('NMLS', nmls) +
        row('Mortgage / Loan Amount', mortgage ? money(mortgage) : '') +
        row('Preapproval Amount', preapprovalAmount ? money(preapprovalAmount) : '') +
        row('Financing Status', financingStatus) +
        row('Financing Contingency', contingency) +
        row('Preapproval Expiration', expiration) +
      '</div>';

    return panel;
  }

  async function loadAndInsert(){
    var id = getDealId();
    if (!id) return;

    var record = null;

    try {
      var res = await fetch('./api/deals/' + encodeURIComponent(id), {
        headers: { 'Accept': 'application/json' },
        cache: 'no-store'
      });
      var data = await res.json();
      record = data.record || data.deal || data;
    } catch (err) {
      record = null;
    }

    var old = document.getElementById('lenderFinancingPanel');
    if (old) old.remove();

    var panel = buildPanel(record || {});

    var financial = findPanelByText(['Financial Terms', 'Purchase Price', 'Mortgage Amount']);
    if (financial && financial.parentNode) {
      financial.parentNode.insertBefore(panel, financial.nextSibling);
      return;
    }

    var parties = findPanelByText(['Deal Parties', 'Seller Attorney', 'Purchaser Attorney']);
    if (parties && parties.parentNode) {
      parties.parentNode.insertBefore(panel, parties.nextSibling);
      return;
    }

    var sourceDocs = document.getElementById('accepted-offer-source-documents') || findPanelByText(['Accepted Offer Source Documents']);
    if (sourceDocs && sourceDocs.parentNode) {
      sourceDocs.parentNode.insertBefore(panel, sourceDocs);
      return;
    }

    (document.querySelector('#app') || document.querySelector('main') || document.body).appendChild(panel);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', loadAndInsert);
  } else {
    loadAndInsert();
  }

  setTimeout(loadAndInsert, 1500);
  setTimeout(loadAndInsert, 3500);
})();
</script>
<!-- END_DEALDESK_LENDER_FINANCING_PANEL_V1 -->
'''

idx = html.lower().rfind("</body>")
if idx >= 0:
    html = html[:idx] + script + "\n" + html[idx:]
else:
    html += "\n" + script

DETAIL.write_text(html, encoding="utf-8")
print("Patched detail.html with Lender / Financing panel.")
PY

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK PATCH"
grep -n "DEALDESK_LENDER_FINANCING_PANEL_V1\|lenderFinancingPanel\|Lender / Financing" "$DETAIL" || echo "NO LENDER PANEL PATCH FOUND"

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Done. Hard refresh the deal detail page."
echo "You should see a Lender / Financing section. If this deal has no saved lender data, it will say so clearly."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
