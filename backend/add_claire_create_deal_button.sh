#!/usr/bin/env bash
set -euo pipefail

APPDIR="/home/servicedepartmen/public_html/dealdesk"
HTML="$APPDIR/claire-dealdesk-view.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$APPDIR/backups/claire-create-deal-$STAMP"

mkdir -p "$BACKUP_DIR"

if [ ! -f "$HTML" ]; then
  echo "ERROR: Missing $HTML"
  exit 1
fi

cp -f "$HTML" "$BACKUP_DIR/claire-dealdesk-view.html.before-create-deal.bak"

python3 - <<'PY'
from pathlib import Path
import sys

html = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")
text = html.read_text(encoding="utf-8", errors="replace")

if 'id="createDealBtn"' not in text:
    old = '<div class="actions"><button id="copyJson" class="secondary">Copy JSON</button><button id="copySummary" class="secondary">Copy Summary</button><button id="printBtn" class="secondary">Print</button></div>'
    new = '<div class="actions"><button id="createDealBtn" class="teal">Create Deal File</button><button id="copyJson" class="secondary">Copy JSON</button><button id="copySummary" class="secondary">Copy Summary</button><button id="printBtn" class="secondary">Print</button></div>'
    if old not in text:
        print("ERROR: Could not find actions toolbar to add Create Deal File button.")
        sys.exit(1)
    text = text.replace(old, new, 1)

create_js = r'''
  function firstNonEmpty(){
    for(let i=0;i<arguments.length;i++){
      const v=arguments[i];
      if(Array.isArray(v) && v.length)return v.filter(Boolean).join(", ");
      if(v!==undefined && v!==null && String(v).trim()!=="")return String(v).trim();
    }
    return "";
  }

  function dateToInput(value){
    const s=String(value||"").trim();
    if(!s)return "";
    let m=s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
    if(m)return `${m[3]}-${String(m[1]).padStart(2,"0")}-${String(m[2]).padStart(2,"0")}`;
    m=s.match(/^(\d{4})-(\d{2})-(\d{2})/);
    if(m)return `${m[1]}-${m[2]}-${m[3]}`;
    return "";
  }

  function findInDocs(r, label){
    label=String(label||"").toLowerCase();
    const docs=(r.documents||[]);
    const buckets=["key_fields","dates_deadlines","money_terms","conditions_contingencies"];
    for(const doc of docs){
      for(const bucket of buckets){
        for(const item of (doc[bucket]||[])){
          const f=String(item.field||"").toLowerCase();
          if(f.includes(label)){
            return item.value || "";
          }
        }
      }
    }
    return "";
  }

  function makeAdditionalTerms(r,f){
    const lines=[];
    if(r.operator_summary)lines.push("CLAIRE Operator Summary:\n"+r.operator_summary);
    if(r.recommended_next_action)lines.push("Recommended Next Action:\n"+r.recommended_next_action);
    if(f.notes && f.notes.length)lines.push("Notes:\n- "+f.notes.join("\n- "));
    if(f.review_flags && f.review_flags.length)lines.push("Review Flags:\n- "+f.review_flags.join("\n- "));
    if(f.missing_items && f.missing_items.length)lines.push("Missing Items:\n- "+f.missing_items.join("\n- "));
    if(f.conflicts && f.conflicts.length)lines.push("Conflicts:\n- "+f.conflicts.join("\n- "));
    if(lastResult && lastResult.uid)lines.push("CLAIRE Source Email UID: "+lastResult.uid);
    return lines.join("\n\n");
  }

  function buildDealPayloadFromClaire(){
    const r=normalizeClaireResult((lastResult&&lastResult.result)||{});
    const f=r.dealdesk_fields||{};
    const p=f.property||{};
    const seller=f.seller||{};
    const buyer=f.purchaser||{};
    const ls=f.listing_side||{};
    const bs=f.buyer_side||{};
    const at=f.attorneys||{};
    const sa=at.seller_attorney||{};
    const pa=at.purchaser_attorney||{};
    const fin=f.financial_terms||{};
    const loan=f.financing||{};
    const sellerNames=Array.isArray(seller.names)?seller.names.join(", "):(seller.names||"");
    const buyerNames=Array.isArray(buyer.names)?buyer.names.join(", "):(buyer.names||"");
    const proposedClosing=findInDocs(r,"proposed closing date");
    const purchaserSigDate=findInDocs(r,"purchaser signature date");

    return {
      accepted_offer_date: "",
      mls_number: p.mls_number || "",
      transaction_status: "Accepted Offer Intake Started",
      property_address: p.address || "",

      purchase_price: fin.purchase_price || "",
      seller_concession: fin.seller_concession || "",
      contract_deposit: fin.down_payment || "",
      mortgage_amount: firstNonEmpty(fin.mortgage_amount, loan.loan_amount),
      cash_at_closing: fin.balance_due_at_closing || "",
      total_price: fin.purchase_price || "",
      contract_date_text: "",
      closing_date_text: proposedClosing || "",
      commission_paid_by_seller: fin.seller_payment_to_buyer_broker ? ("Seller payment to buyer broker: " + fin.seller_payment_to_buyer_broker) : "",
      commission_paid_by_purchaser: "",

      seller_name: sellerNames,
      purchaser_name: buyerNames,
      seller_legal_address: seller.address || "",
      purchaser_legal_address: buyer.address || "",

      seller_attorney_name: sa.name || "",
      seller_attorney_address: sa.address || "",
      seller_attorney_phone: sa.phone || "",
      seller_attorney_email: sa.email || "",

      purchaser_attorney_name: pa.name || "",
      purchaser_attorney_address: pa.address || "",
      purchaser_attorney_phone: pa.phone || "",
      purchaser_attorney_email: pa.email || "",

      seller_agent_name: ls.agent || "",
      seller_agent_license: ls.agent_license || "",
      seller_agent_broker: ls.broker || "",
      seller_agent_phone: ls.phone || "",
      seller_agent_email: ls.email || "",

      purchaser_agent_name: bs.agent || "",
      purchaser_agent_license: bs.agent_license || "",
      purchaser_agent_broker: bs.broker || "",
      purchaser_agent_phone: bs.phone || "",
      purchaser_agent_email: bs.email || "",

      lender_name: loan.loan_officer || "",
      lender_company: loan.lender || "",
      lender_phone: loan.loan_officer_phone || "",
      lender_email: loan.loan_officer_email || "",
      lender_address: "",

      property_condition_statement_status: "Unknown",
      next_action: f.next_action || r.recommended_next_action || "",
      additional_terms: makeAdditionalTerms(r,f),

      seller_acknowledgment_name: sellerNames,
      seller_acknowledgment_date: "",
      purchaser_acknowledgment_name: buyerNames,
      purchaser_acknowledgment_date: dateToInput(purchaserSigDate),

      source_label: "CLAIRE email intake reader",
      created_by: "claire"
    };
  }

  async function createDealFile(){
    if(!lastResult || !lastResult.result){
      setStatus("Read an email first, then create the deal file.","warn");
      return;
    }

    const payload=buildDealPayloadFromClaire();
    if(!payload.property_address){
      setStatus("Cannot create deal file because property address is missing.","err");
      return;
    }

    const btn=$("createDealBtn");
    btn.disabled=true;
    const oldText=btn.textContent;
    btn.textContent="Creating Deal File...";
    setStatus("Creating accepted-offer deal file...","");

    try{
      const response=await fetch("./api/deals",{
        method:"POST",
        headers:{"Content-Type":"application/json","Accept":"application/json"},
        cache:"no-store",
        body:JSON.stringify(payload)
      });

      const data=await response.json();
      if(!response.ok || !data.ok){
        throw new Error(data.error || "Create deal failed");
      }

      const deal=data.deal||{};
      const publicId=deal.public_id || deal.id || deal.deal_id || "";
      const detailUrl=publicId ? "./detail.html?id="+encodeURIComponent(publicId) : "./dashboard.html";
      const banner=`<div class="status ok"><strong>Deal file created.</strong><br>${esc(deal.property_address||payload.property_address)}<br>Status: ${esc(deal.transaction_status||payload.transaction_status)}<br><br><a href="${detailUrl}">Open Deal File</a> &nbsp; | &nbsp; <a href="./dashboard.html">Command Center</a></div>`;

      $("dealTab").insertAdjacentHTML("afterbegin",banner);
      setStatus("Deal file created. Open it from the link at the top of Deal Fields.","ok");
    }catch(e){
      setStatus("Could not create deal file: "+e.message,"err");
    }finally{
      btn.disabled=false;
      btn.textContent=oldText;
    }
  }

'''

if "function buildDealPayloadFromClaire()" not in text:
    marker = '  $("listBtn").onclick=listEmails;'
    if marker not in text:
        print("ERROR: Could not find JS event binding marker.")
        sys.exit(1)
    text = text.replace(marker, create_js + "\n" + marker, 1)

if '$("createDealBtn").onclick=createDealFile;' not in text:
    marker = '$("listBtn").onclick=listEmails;'
    if marker not in text:
        print("ERROR: Could not find listBtn binding.")
        sys.exit(1)
    text = text.replace(marker, '$("createDealBtn").onclick=createDealFile;\n  ' + marker, 1)

html.write_text(text, encoding="utf-8")
print("Create Deal File button added.")
PY

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Create Deal File button installed."
echo ""
echo "Open:"
echo "https://servicedepartment.ai/dealdesk/claire-dealdesk-view.html"
echo ""
echo "Use:"
echo "1. List Emails"
echo "2. Select email"
echo "3. Read Selected Email"
echo "4. Review Deal Fields"
echo "5. Click Create Deal File"
echo ""
echo "Backup:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
