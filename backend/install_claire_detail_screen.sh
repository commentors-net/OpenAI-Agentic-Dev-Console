#!/usr/bin/env bash
set -euo pipefail

APPDIR="/home/servicedepartmen/public_html/dealdesk"
BACKEND="/home/servicedepartmen/dealdesk-backend"
HTML="$APPDIR/claire-detail-reader.html"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$APPDIR/backups" "$BACKEND/backups"

# Preserve the current working version.
if [ -f "$APPDIR/claire-email-reader.html" ]; then
  cp -f "$APPDIR/claire-email-reader.html" "$APPDIR/backups/claire-email-reader.html.working-before-detail-screen-$STAMP.bak"
fi

if [ -f "$BACKEND/claire_reader_sidecar.js" ]; then
  cp -f "$BACKEND/claire_reader_sidecar.js" "$BACKEND/backups/claire_reader_sidecar.js.working-before-detail-screen-$STAMP.bak"
fi

cat > "$HTML" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>CLAIRE Deal Detail Reader</title>
  <style>
    :root{
      --navy:#071b2c;--navy2:#0b263d;--teal:#14b8a6;--bg:#f4f7fb;--card:#fff;
      --text:#122033;--muted:#66758a;--border:#dbe5ef;--soft:#f8fbfe;
      --ok:#067647;--bad:#b42318;--warn:#b54708;--gold:#f79009;
    }
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font-family:Arial,Helvetica,sans-serif}
    header{background:linear-gradient(135deg,var(--navy),var(--navy2));color:#fff;padding:18px 20px;border-bottom:4px solid var(--teal)}
    header h1{margin:0;font-size:23px}
    header p{margin:6px 0 0;color:#c7d8e8}
    main{max-width:1280px;margin:18px auto 42px;padding:0 14px}
    .layout{display:grid;grid-template-columns:340px 1fr;gap:16px}
    @media(max-width:980px){.layout{grid-template-columns:1fr}}
    .card{background:var(--card);border:1px solid var(--border);border-radius:16px;box-shadow:0 10px 26px rgba(15,35,55,.06);overflow:hidden}
    .card h2{margin:0;padding:14px 16px;font-size:16px;background:var(--soft);border-bottom:1px solid var(--border)}
    .body{padding:16px}
    label{display:block;font-size:12px;font-weight:800;color:#344054;margin:12px 0 5px}
    input{width:100%;border:1px solid #cbd5e1;border-radius:10px;padding:11px 12px;font-size:14px}
    button{border:0;border-radius:10px;padding:11px 13px;font-weight:800;cursor:pointer;background:var(--navy);color:white}
    button.secondary{background:#e6eef7;color:#102a43}
    button.teal{background:var(--teal);color:#06251f}
    button:disabled{opacity:.55;cursor:not-allowed}
    .buttons{display:grid;gap:10px;margin-top:14px}
    .row{display:flex;gap:10px}.row>*{flex:1}
    .status{padding:12px 14px;border-radius:12px;margin-bottom:12px;border:1px solid var(--border);background:#f8fbfe;color:#344054;font-size:14px;white-space:pre-wrap}
    .status.ok{background:#ecfdf3;border-color:#abefc6;color:var(--ok)}
    .status.err{background:#fef3f2;border-color:#fecdca;color:var(--bad)}
    .status.warn{background:#fffaeb;border-color:#fedf89;color:var(--warn)}
    .email-list{display:grid;gap:10px;max-height:620px;overflow:auto}
    .email{border:1px solid var(--border);border-radius:12px;padding:12px;background:#fff;cursor:pointer}
    .email:hover{border-color:var(--teal);background:#f7fffd}
    .uid{font-size:12px;color:var(--teal);font-weight:900}.subj{font-weight:900;margin-top:5px}.meta{font-size:12px;color:var(--muted);margin-top:4px}
    .summary-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:16px}
    @media(max-width:980px){.summary-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}
    @media(max-width:560px){.summary-grid{grid-template-columns:1fr}}
    .metric{border:1px solid var(--border);background:#fff;border-radius:14px;padding:13px}
    .metric .label{font-size:11px;color:var(--muted);font-weight:900;text-transform:uppercase;letter-spacing:.04em}
    .metric .value{font-size:16px;font-weight:900;margin-top:6px;min-height:20px}
    .section{margin-bottom:16px}
    .section-title{display:flex;align-items:center;justify-content:space-between;gap:10px;margin:0 0 10px}
    .section-title h2{background:none;border:0;padding:0;margin:0;font-size:18px}
    .pill{display:inline-block;padding:4px 9px;border-radius:999px;background:#e6eef7;color:#24415c;font-size:12px;font-weight:900}
    .pill.teal{background:#d1faf3;color:#075e54}.pill.warn{background:#fff0cf;color:#8a4b00}
    .doc-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}
    @media(max-width:980px){.doc-grid{grid-template-columns:1fr}}
    .doc-card{border:1px solid var(--border);background:#fff;border-radius:16px;overflow:hidden}
    .doc-head{padding:13px 15px;background:#f8fbfe;border-bottom:1px solid var(--border)}
    .doc-head h3{margin:0;font-size:16px}
    .doc-body{padding:14px 15px}
    .kv{display:grid;grid-template-columns:210px 1fr;border-top:1px solid #edf2f7}
    .kv:first-child{border-top:0}
    .kv .k{font-weight:900;color:#344054;padding:9px 10px;background:#fbfdff}
    .kv .v{padding:9px 10px;white-space:pre-wrap}
    @media(max-width:700px){.kv{grid-template-columns:1fr}.kv .k{padding-bottom:2px}.kv .v{padding-top:2px}}
    .raw{white-space:pre-wrap;font-family:Arial,Helvetica,sans-serif;line-height:1.45;background:#fff;border:1px solid var(--border);border-radius:14px;padding:16px}
    .tabs{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 14px}
    .tab{background:#e6eef7;color:#102a43}.tab.active{background:var(--navy);color:white}
    .placeholder{color:var(--muted);padding:28px;text-align:center}
    .small{font-size:12px;color:var(--muted);margin-top:8px}
    .topbar{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:12px}
    .actions{display:flex;gap:8px;flex-wrap:wrap}
    .hidden{display:none}
  </style>
</head>
<body>
<header>
  <h1>CLAIRE Deal Detail Reader</h1>
  <p>Fast email/document readout — easy review before creating an Accepted Offer file.</p>
</header>

<main>
  <div class="layout">
    <aside class="card">
      <h2>Reader Controls</h2>
      <div class="body">
        <div id="status" class="status warn">Ready. List emails or read the latest matching email.</div>

        <label>API Base</label>
        <input id="apiBase" value="./api/claire-reader">

        <label>Sender / search filter</label>
        <input id="fromFilter" value="zach">

        <div class="row">
          <div>
            <label>Limit</label>
            <input id="limit" value="20">
          </div>
          <div>
            <label>UID</label>
            <input id="uid" placeholder="optional">
          </div>
        </div>

        <div class="buttons">
          <button id="listBtn">List Emails</button>
          <button id="latestBtn" class="teal">Read Latest Matching Email</button>
          <button id="uidBtn" class="secondary">Read UID</button>
        </div>

        <p class="small">This page uses the current working CLAIRE reader sidecar. It does not change the prompt, DB, or deal files.</p>
      </div>
    </aside>

    <section class="card">
      <h2>Email Inbox</h2>
      <div class="body">
        <div id="emails" class="email-list">
          <div class="placeholder">No emails loaded yet.</div>
        </div>
      </div>
    </section>
  </div>

  <section class="card" style="margin-top:16px">
    <h2>Deal-Style Readout</h2>
    <div class="body">
      <div class="topbar">
        <div class="tabs">
          <button class="tab active" data-view="detail">Detail View</button>
          <button class="tab" data-view="raw">Raw CLAIRE Readout</button>
        </div>
        <div class="actions">
          <button id="copyBtn" class="secondary">Copy</button>
          <button id="printBtn" class="secondary">Print</button>
        </div>
      </div>

      <div id="detailView">
        <div class="placeholder">Read an email to build the Deal Detail view.</div>
      </div>

      <div id="rawView" class="hidden">
        <div id="rawReadout" class="raw">No readout yet.</div>
      </div>
    </div>
  </section>
</main>

<script>
(function(){
  const $ = id => document.getElementById(id);
  let currentReadout = "";
  let currentData = null;

  function setStatus(msg, type){
    $("status").className = "status " + (type || "");
    $("status").textContent = msg;
  }

  function base(){
    return $("apiBase").value.replace(/\/+$/, "");
  }

  function esc(s){
    return String(s || "").replace(/[&<>"']/g, c => ({
      "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#039;"
    }[c]));
  }

  async function fetchJson(url){
    const res = await fetch(url, {headers:{Accept:"application/json"}, cache:"no-store"});
    const text = await res.text();
    let data;
    try { data = text ? JSON.parse(text) : {}; }
    catch(e){ throw new Error("Backend did not return JSON: " + text.slice(0, 300)); }
    if(!res.ok || data.ok === false) throw new Error(data.error || ("HTTP " + res.status));
    return data;
  }

  function renderEmails(list){
    if(!list || !list.length){
      $("emails").innerHTML = '<div class="placeholder">No matching emails.</div>';
      return;
    }

    $("emails").innerHTML = list.map(x => `
      <div class="email" data-uid="${esc(x.uid)}">
        <div class="uid">UID ${esc(x.uid)}</div>
        <div class="subj">${esc(x.subject || "(no subject)")}</div>
        <div class="meta">${esc(x.from)}</div>
        <div class="meta">${esc(x.date)} ${x.seen ? "seen" : "unread"}</div>
      </div>
    `).join("");

    document.querySelectorAll(".email").forEach(el => {
      el.onclick = () => {
        $("uid").value = el.dataset.uid || "";
        readUid();
      };
    });
  }

  function splitSections(text){
    const lines = String(text || "").split(/\r?\n/);
    const sections = [];
    let current = {title:"Overview", lines:[]};

    for(const line of lines){
      const clean = line.trim();
      if(/^#{1,3}\s+/.test(clean) || /^[A-Z][A-Z /-]{3,}$/.test(clean) || /^Document\s+\d+/i.test(clean)){
        if(current.lines.join("").trim() || current.title !== "Overview") sections.push(current);
        current = {title: clean.replace(/^#{1,3}\s+/, ""), lines:[]};
      } else {
        current.lines.push(line);
      }
    }
    if(current.lines.join("").trim() || current.title !== "Overview") sections.push(current);
    return sections;
  }

  function fieldPairs(lines){
    const pairs = [];
    for(let raw of lines){
      let line = raw.trim();
      if(!line) continue;
      line = line.replace(/^[-•]\s*/, "");
      let m = line.match(/^([^:\t]{2,80})\t(.+)$/);
      if(!m) m = line.match(/^([^:]{2,80}):\s*(.+)$/);
      if(m){
        pairs.push({k:m[1].trim(), v:m[2].trim()});
      }
    }
    return pairs;
  }

  function findValue(text, labels){
    const pairs = [];
    for(const s of splitSections(text)){
      pairs.push(...fieldPairs(s.lines));
    }
    for(const label of labels){
      const found = pairs.find(p => p.k.toLowerCase().includes(label.toLowerCase()));
      if(found && found.v && !/^\[?value\]?$/i.test(found.v)) return found.v;
    }
    return "";
  }

  function documentSections(text){
    const sections = splitSections(text);
    return sections.filter(s => /^Document\s+\d+/i.test(s.title) || /document\s+\d+/i.test(s.title));
  }

  function renderKv(pairs){
    if(!pairs.length) return '<div class="placeholder">No structured fields found in this section.</div>';
    return pairs.map(p => `
      <div class="kv">
        <div class="k">${esc(p.k)}</div>
        <div class="v">${esc(p.v)}</div>
      </div>
    `).join("");
  }

  function renderDetail(data){
    const text = data.readout || data.output || data.text || "";
    currentReadout = text;
    currentData = data;
    $("rawReadout").textContent = text || "No readout returned.";

    if(!text){
      $("detailView").innerHTML = '<div class="placeholder">No readout returned.</div>';
      return;
    }

    const email = data.email || {};
    const property = findValue(text, ["Property"]);
    const sellers = findValue(text, ["Seller"]);
    const purchasers = findValue(text, ["Purchaser", "Buyer"]);
    const next = findValue(text, ["Recommended next action", "Next action"]);

    const docs = documentSections(text);

    const docHtml = docs.length ? docs.map((s, i) => {
      const pairs = fieldPairs(s.lines);
      return `
        <article class="doc-card">
          <div class="doc-head">
            <h3>${esc(s.title || ("Document " + (i + 1)))}</h3>
          </div>
          <div class="doc-body">${renderKv(pairs)}</div>
        </article>
      `;
    }).join("") : `<div class="placeholder">CLAIRE returned text, but no document sections were detected. Use Raw CLAIRE Readout.</div>`;

    $("detailView").innerHTML = `
      <div class="summary-grid">
        <div class="metric"><div class="label">Subject</div><div class="value">${esc(email.subject || findValue(text, ["Subject"]) || "—")}</div></div>
        <div class="metric"><div class="label">Property</div><div class="value">${esc(property || "—")}</div></div>
        <div class="metric"><div class="label">Seller(s)</div><div class="value">${esc(sellers || "—")}</div></div>
        <div class="metric"><div class="label">Purchaser(s)</div><div class="value">${esc(purchasers || "—")}</div></div>
      </div>

      <div class="section">
        <div class="section-title">
          <h2>Documents</h2>
          <span class="pill teal">${docs.length || (email.attachments ? email.attachments.length : 0)} document(s)</span>
        </div>
        <div class="doc-grid">${docHtml}</div>
      </div>

      <div class="section">
        <div class="section-title">
          <h2>Recommended Next Action</h2>
          <span class="pill warn">Operator review</span>
        </div>
        <div class="doc-card"><div class="doc-body">
          <div class="kv"><div class="k">Next action</div><div class="v">${esc(next || "Review CLAIRE readout and confirm whether to create an Accepted Offer file.")}</div></div>
        </div></div>
      </div>
    `;
  }

  async function listEmails(){
    setStatus("Listing emails...", "");
    $("emails").innerHTML = '<div class="placeholder">Loading...</div>';
    try{
      const d = await fetchJson(`${base()}/emails?from=${encodeURIComponent($("fromFilter").value)}&limit=${encodeURIComponent($("limit").value || 20)}`);
      renderEmails(d.emails || []);
      setStatus("Emails loaded.", "ok");
    }catch(e){
      setStatus(e.message, "err");
      $("emails").innerHTML = '<div class="placeholder">Could not load emails.</div>';
    }
  }

  async function readLatest(){
    setStatus("CLAIRE is reading latest matching email...", "");
    $("detailView").innerHTML = '<div class="placeholder">Reading email and attachments...</div>';
    try{
      const d = await fetchJson(`${base()}/read?latest=1&from=${encodeURIComponent($("fromFilter").value)}`);
      renderDetail(d);
      setStatus("Readout complete.", "ok");
    }catch(e){
      setStatus(e.message, "err");
      $("detailView").innerHTML = '<div class="placeholder">Read failed.</div>';
    }
  }

  async function readUid(){
    const uid = $("uid").value.trim();
    if(!uid){ setStatus("Enter or click a UID.", "warn"); return; }
    setStatus("CLAIRE is reading UID " + uid + "...", "");
    $("detailView").innerHTML = '<div class="placeholder">Reading email and attachments...</div>';
    try{
      const d = await fetchJson(`${base()}/read?uid=${encodeURIComponent(uid)}`);
      renderDetail(d);
      setStatus("Readout complete.", "ok");
    }catch(e){
      setStatus(e.message, "err");
      $("detailView").innerHTML = '<div class="placeholder">Read failed.</div>';
    }
  }

  $("listBtn").onclick = listEmails;
  $("latestBtn").onclick = readLatest;
  $("uidBtn").onclick = readUid;
  $("copyBtn").onclick = async () => {
    await navigator.clipboard.writeText(currentReadout || "");
    setStatus("Readout copied.", "ok");
  };
  $("printBtn").onclick = () => window.print();

  document.querySelectorAll(".tab").forEach(btn => {
    btn.onclick = () => {
      document.querySelectorAll(".tab").forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      const view = btn.dataset.view;
      $("detailView").classList.toggle("hidden", view !== "detail");
      $("rawView").classList.toggle("hidden", view !== "raw");
    };
  });
})();
</script>
</body>
</html>
HTML

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "CLAIRE Deal Detail screen installed."
echo ""
echo "Preserved current working files as backups."
echo ""
echo "Open:"
echo "https://servicedepartment.ai/dealdesk/claire-detail-reader.html"
echo ""
echo "This did not modify the current CLAIRE reader sidecar or prompt."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
