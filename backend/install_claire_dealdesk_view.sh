#!/usr/bin/env bash
set -euo pipefail

APPDIR="/home/servicedepartmen/public_html/dealdesk"
BACKEND="/home/servicedepartmen/dealdesk-backend"
SIDE="$BACKEND/claire_dealview_sidecar.js"
HTML="$APPDIR/claire-dealdesk-view.html"
HTACCESS="$APPDIR/.htaccess"
STAMP="$(date +%Y%m%d-%H%M%S)"
PORT="${CLAIRE_DEALVIEW_PORT:-3022}"
PM2_NAME="dealdesk-claire-dealview"

mkdir -p "$APPDIR/backups" "$BACKEND/backups"

if [ -f "$SIDE" ]; then cp -f "$SIDE" "$BACKEND/backups/claire_dealview_sidecar.js.before-$STAMP.bak"; fi
if [ -f "$HTML" ]; then cp -f "$HTML" "$APPDIR/backups/claire-dealdesk-view.html.before-$STAMP.bak"; fi
if [ -f "$HTACCESS" ]; then cp -f "$HTACCESS" "$APPDIR/backups/.htaccess.before-claire-dealview-$STAMP.bak"; fi

cat > "$SIDE" <<'NODE'
#!/usr/bin/env node

const http = require("http");
const fs = require("fs");
const path = require("path");
const { ImapFlow } = require("imapflow");
const { simpleParser } = require("mailparser");

try {
  require("dotenv").config({ path: "/home/servicedepartmen/dealdesk-backend/.env" });
} catch (err) {}

const BACKEND = "/home/servicedepartmen/dealdesk-backend";
const CONFIG_PATH = path.join(BACKEND, "email-intake.config.json");
const HOST = "127.0.0.1";
const PORT = Number(process.env.CLAIRE_DEALVIEW_PORT || 3022);
const MODEL = process.env.CLAIRE_DEALVIEW_MODEL || process.env.CLAIRE_MODEL || process.env.OPENAI_MODEL || "gpt-4.1";
const MAX_ATTACHMENT_BYTES = Number(process.env.CLAIRE_MAX_ATTACHMENT_BYTES || 25 * 1024 * 1024);

function sendJson(res, status, payload) {
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization"
  });
  res.end(JSON.stringify(payload, null, 2));
}

function clean(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function loadMailboxConfig() {
  if (!fs.existsSync(CONFIG_PATH)) throw new Error("Missing mailbox config: " + CONFIG_PATH);
  const cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  if (!cfg.mailbox || !cfg.mailbox.host || !cfg.mailbox.user || !cfg.mailbox.pass) {
    throw new Error("email-intake.config.json is missing mailbox host/user/pass");
  }
  return cfg;
}

function openaiKey() {
  const key = process.env.OPENAI_API_KEY || process.env.CLAIRE_OPENAI_API_KEY || process.env.OPENAI_KEY;
  if (!key) throw new Error("OpenAI API key is not loaded from .env. Expected OPENAI_API_KEY.");
  return key;
}

function imapClient(cfg) {
  return new ImapFlow({
    host: cfg.mailbox.host,
    port: Number(cfg.mailbox.port || 993),
    secure: cfg.mailbox.secure !== false,
    auth: { user: cfg.mailbox.user, pass: cfg.mailbox.pass },
    logger: false
  });
}

function emailLine(msg) {
  const from = msg.envelope?.from?.map(x => `${x.name || ""} <${x.address || ""}>`).join(", ") || "";
  const subject = msg.envelope?.subject || "";
  const date = msg.envelope?.date ? new Date(msg.envelope.date).toISOString() : "";
  const seen = Array.from(msg.flags || []).includes("\\Seen");
  return { uid: msg.uid, seen, date, from, subject };
}

async function withMailbox(fn) {
  const cfg = loadMailboxConfig();
  const client = imapClient(cfg);
  await client.connect();
  const box = cfg.processing?.mailbox || "INBOX";
  const lock = await client.getMailboxLock(box);
  try {
    return await fn(client);
  } finally {
    lock.release();
    await client.logout().catch(() => {});
  }
}

async function listEmails({ limit = 30, search = "" }) {
  return withMailbox(async client => {
    const rows = [];
    for await (const msg of client.fetch("1:*", { uid: true, envelope: true, flags: true })) {
      const row = emailLine(msg);
      const haystack = `${row.from} ${row.subject}`.toLowerCase();
      if (search && !haystack.includes(search.toLowerCase())) continue;
      rows.push(row);
    }
    rows.sort((a, b) => Number(b.uid) - Number(a.uid));
    return rows.slice(0, Math.max(1, Math.min(Number(limit) || 30, 150)));
  });
}

async function fetchParsedEmail(uid) {
  return withMailbox(async client => {
    const msg = await client.fetchOne(String(uid), {
      uid: true,
      envelope: true,
      source: true,
      flags: true
    }, { uid: true });
    if (!msg || !msg.source) throw new Error("Email UID not found: " + uid);
    return simpleParser(msg.source);
  });
}

function attachmentSummary(parsed) {
  return (parsed.attachments || []).map((att, i) => ({
    number: i + 1,
    filename: att.filename || `attachment-${i + 1}`,
    mime_type: att.contentType || "",
    size_bytes: att.size || (att.content ? att.content.length : 0)
  }));
}

function attachmentListText(parsed) {
  const rows = attachmentSummary(parsed);
  if (!rows.length) return "[No attachments]";
  return rows.map(a => `- ${a.number}. ${a.filename} | ${a.mime_type} | ${a.size_bytes} bytes`).join("\n");
}

function dataUrl(att) {
  const mime = att.contentType || "application/octet-stream";
  const b64 = Buffer.from(att.content || Buffer.alloc(0)).toString("base64");
  return `data:${mime};base64,${b64}`;
}

function isSupportedAttachment(att) {
  const mime = String(att.contentType || "").toLowerCase();
  const filename = String(att.filename || "").toLowerCase();
  return (
    mime.includes("pdf") ||
    mime.startsWith("image/") ||
    mime.includes("text/") ||
    filename.endsWith(".pdf") ||
    filename.endsWith(".png") ||
    filename.endsWith(".jpg") ||
    filename.endsWith(".jpeg") ||
    filename.endsWith(".webp") ||
    filename.endsWith(".txt")
  );
}

function buildPrompt(parsed) {
  const from = parsed.from?.text || "";
  const to = parsed.to?.text || "";
  const subject = parsed.subject || "";
  const date = parsed.date ? new Date(parsed.date).toISOString() : "";
  const body = clean(parsed.text || "").slice(0, 30000);

  return `
You are CLAIRE, Deal Desk's real estate email/document reader.

Read the email body and all attachments like a human transaction coordinator.
Do not use fixed templates as the brain.
Do not focus on one field.
Do not silently force uncertain values.
Classify every document and extract all useful information for an Accepted Offer to Close workflow.
This is only review. Do not say a deal file was created.

Email:
From: ${from}
To: ${to}
Subject: ${subject}
Date: ${date}

Email body:
${body || "[No plain-text email body]"}

Attachments:
${attachmentListText(parsed)}

Return ONLY valid JSON. No markdown. No code fence.

JSON shape:
{
  "email": {
    "from": "",
    "to": "",
    "subject": "",
    "date": "",
    "purpose": ""
  },
  "documents": [
    {
      "number": 1,
      "filename": "",
      "document_type": "",
      "purpose": "",
      "key_fields": [
        {"field": "", "value": "", "source_note": ""}
      ],
      "people_companies": [
        {"role": "", "name": "", "email": "", "phone": "", "notes": ""}
      ],
      "dates_deadlines": [
        {"field": "", "value": "", "notes": ""}
      ],
      "money_terms": [
        {"field": "", "value": "", "notes": ""}
      ],
      "conditions_contingencies": [
        {"field": "", "value": "", "notes": ""}
      ],
      "review_flags": [],
      "confidence": "High"
    }
  ],
  "dealdesk_fields": {
    "file_status": "Accepted Offer / Intake Review",
    "next_action": "",
    "property": {
      "address": "",
      "mls_number": "",
      "property_type": ""
    },
    "seller": {
      "names": [],
      "address": "",
      "phone": "",
      "email": ""
    },
    "purchaser": {
      "names": [],
      "address": "",
      "phone": "",
      "email": ""
    },
    "listing_side": {
      "broker": "",
      "agent": "",
      "agent_license": "",
      "email": "",
      "phone": ""
    },
    "buyer_side": {
      "broker": "",
      "agent": "",
      "agent_license": "",
      "email": "",
      "phone": ""
    },
    "attorneys": {
      "seller_attorney": {"name": "", "email": "", "phone": ""},
      "purchaser_attorney": {"name": "", "email": "", "phone": ""}
    },
    "financial_terms": {
      "purchase_price": "",
      "seller_concession": "",
      "seller_payment_to_buyer_broker": "",
      "down_payment": "",
      "mortgage_amount": "",
      "balance_due_at_closing": "",
      "net_to_seller": ""
    },
    "financing": {
      "financing_type": "",
      "lender": "",
      "loan_officer": "",
      "loan_officer_email": "",
      "loan_officer_phone": "",
      "preapproval_amount": "",
      "loan_amount": "",
      "rate_apr": "",
      "loan_term": "",
      "preapproval_expiration": "",
      "financing_contingency_length": ""
    },
    "contingencies": {
      "financing": "",
      "inspection": "",
      "sale_of_other_property": "",
      "other": ""
    },
    "personal_property": {
      "included": "",
      "excluded": ""
    },
    "notes": [],
    "review_flags": [],
    "missing_items": [],
    "conflicts": []
  },
  "operator_summary": "",
  "recommended_next_action": ""
}

Rules for dealdesk_fields:
- Fill fields only when supported by the documents.
- Use "uncertain" for unclear values.
- Use arrays for names.
- Put conflicts in conflicts, not hidden in notes.
- If a document has financing info, put it in financing, not seller/purchaser terms unless it clearly belongs there.
- If an attorney appears but side is uncertain, use the most likely side and add a review flag.
`;
}

function extractOutputText(data) {
  if (data.output_text) return data.output_text;
  const parts = [];
  for (const item of data.output || []) {
    for (const c of item.content || []) {
      if (c.text) parts.push(c.text);
      if (c.type === "output_text" && c.text) parts.push(c.text);
    }
  }
  return parts.join("\n") || JSON.stringify(data, null, 2);
}

function parseJsonModelOutput(text) {
  const raw = String(text || "").trim();
  try { return JSON.parse(raw); } catch (err) {}
  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced) {
    try { return JSON.parse(fenced[1].trim()); } catch (err) {}
  }
  const first = raw.indexOf("{");
  const last = raw.lastIndexOf("}");
  if (first >= 0 && last > first) {
    try { return JSON.parse(raw.slice(first, last + 1)); } catch (err) {}
  }
  return { parse_error: true, raw_output: raw };
}

async function askModelStructured(parsed) {
  const content = [{ type: "input_text", text: buildPrompt(parsed) }];
  const skipped = [];

  for (const att of parsed.attachments || []) {
    const filename = att.filename || "attachment";
    const size = att.size || (att.content ? att.content.length : 0);
    if (!isSupportedAttachment(att)) {
      skipped.push(`${filename}: unsupported type ${att.contentType || ""}`);
      continue;
    }
    if (size > MAX_ATTACHMENT_BYTES) {
      skipped.push(`${filename}: skipped because ${size} bytes exceeds limit`);
      continue;
    }
    content.push({ type: "input_file", filename, file_data: dataUrl(att) });
  }

  if (skipped.length) {
    content[0].text += "\n\nAttachments not sent as files:\n" + skipped.map(s => "- " + s).join("\n");
  }

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${openaiKey()}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      model: MODEL,
      input: [{ role: "user", content }],
      max_output_tokens: 12000
    })
  });

  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; }
  catch (err) { throw new Error("OpenAI returned non-JSON: " + text.slice(0, 600)); }

  if (!response.ok) {
    throw new Error(data.error?.message || JSON.stringify(data, null, 2));
  }

  const outputText = extractOutputText(data);
  return { structured: parseJsonModelOutput(outputText), raw_output: outputText };
}

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization"
    });
    res.end();
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/claire-dealview/health") {
    sendJson(res, 200, { ok: true, service: "dealdesk-claire-dealview", model: MODEL });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/claire-dealview/emails") {
    const search = url.searchParams.get("search") || url.searchParams.get("from") || "";
    const limit = url.searchParams.get("limit") || "30";
    const emails = await listEmails({ search, limit });
    sendJson(res, 200, { ok: true, emails });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/claire-dealview/read") {
    const uid = url.searchParams.get("uid") || "";
    if (!uid) throw new Error("Missing uid.");
    const parsed = await fetchParsedEmail(uid);
    const modelResult = await askModelStructured(parsed);
    sendJson(res, 200, {
      ok: true,
      uid,
      source_email: {
        from: parsed.from?.text || "",
        to: parsed.to?.text || "",
        subject: parsed.subject || "",
        date: parsed.date ? new Date(parsed.date).toISOString() : "",
        attachments: attachmentSummary(parsed)
      },
      result: modelResult.structured,
      raw_output: modelResult.raw_output
    });
    return;
  }

  sendJson(res, 404, { ok: false, error: "Not found" });
}

const server = http.createServer((req, res) => {
  handle(req, res).catch(err => {
    sendJson(res, err.statusCode || 500, { ok: false, error: err.message || String(err) });
  });
});

server.listen(PORT, HOST, () => {
  console.log(`dealdesk-claire-dealview listening on http://${HOST}:${PORT}`);
});
NODE

chmod +x "$SIDE"

cat > "$HTML" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>CLAIRE Deal Desk View</title>
  <style>
    :root{--navy:#071b2c;--navy2:#0b263d;--teal:#14b8a6;--bg:#f4f7fb;--card:#fff;--text:#122033;--muted:#66758a;--border:#dbe5ef;--soft:#f8fbfe;--ok:#067647;--bad:#b42318;--warn:#b54708}
    *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--text);font-family:Arial,Helvetica,sans-serif}
    header{background:linear-gradient(135deg,var(--navy),var(--navy2));color:#fff;padding:18px 20px;border-bottom:4px solid var(--teal)}
    header h1{margin:0;font-size:23px} header p{margin:6px 0 0;color:#c7d8e8}
    main{max-width:1320px;margin:18px auto 42px;padding:0 14px}.layout{display:grid;grid-template-columns:380px 1fr;gap:16px}@media(max-width:980px){.layout{grid-template-columns:1fr}}
    .card{background:var(--card);border:1px solid var(--border);border-radius:16px;box-shadow:0 10px 26px rgba(15,35,55,.06);overflow:hidden}.card h2{margin:0;padding:14px 16px;font-size:16px;background:var(--soft);border-bottom:1px solid var(--border)}.body{padding:16px}
    label{display:block;font-size:12px;font-weight:800;color:#344054;margin:12px 0 5px}input{width:100%;border:1px solid #cbd5e1;border-radius:10px;padding:11px 12px;font-size:14px}
    button{border:0;border-radius:10px;padding:11px 13px;font-weight:800;cursor:pointer;background:var(--navy);color:white}button.secondary{background:#e6eef7;color:#102a43}button.teal{background:var(--teal);color:#06251f}button:disabled{opacity:.55;cursor:not-allowed}
    .buttons{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:14px}.status{padding:12px 14px;border-radius:12px;margin-bottom:12px;border:1px solid var(--border);background:#f8fbfe;color:#344054;font-size:14px;white-space:pre-wrap}.status.ok{background:#ecfdf3;border-color:#abefc6;color:var(--ok)}.status.err{background:#fef3f2;border-color:#fecdca;color:var(--bad)}.status.warn{background:#fffaeb;border-color:#fedf89;color:var(--warn)}
    .email-list{display:grid;gap:10px;max-height:660px;overflow:auto}.email{border:1px solid var(--border);border-radius:12px;padding:12px;background:#fff;cursor:pointer}.email:hover{border-color:var(--teal);background:#f7fffd}.email.selected{border-color:var(--teal);box-shadow:0 0 0 3px rgba(20,184,166,.12)}.uid{font-size:12px;color:var(--teal);font-weight:900}.subj{font-weight:900;margin-top:5px}.meta{font-size:12px;color:var(--muted);margin-top:4px}
    .summary{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:16px}@media(max-width:1050px){.summary{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:560px){.summary{grid-template-columns:1fr}}
    .metric{border:1px solid var(--border);background:#fff;border-radius:14px;padding:13px}.metric .label{font-size:11px;color:var(--muted);font-weight:900;text-transform:uppercase;letter-spacing:.04em}.metric .value{font-size:16px;font-weight:900;margin-top:6px;min-height:20px}
    .section{margin-bottom:16px}.section-title{display:flex;align-items:center;justify-content:space-between;margin:0 0 10px}.section-title h2{background:none;border:0;padding:0;margin:0;font-size:18px}.pill{display:inline-block;padding:4px 9px;border-radius:999px;background:#e6eef7;color:#24415c;font-size:12px;font-weight:900}.pill.teal{background:#d1faf3;color:#075e54}.pill.warn{background:#fff0cf;color:#8a4b00}
    .field-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}@media(max-width:800px){.field-grid{grid-template-columns:1fr}}
    .panel{border:1px solid var(--border);background:#fff;border-radius:16px;overflow:hidden}.panel h3{margin:0;padding:12px 14px;background:#f8fbfe;border-bottom:1px solid var(--border);font-size:15px}.panel-body{padding:12px 14px}
    .kv{display:grid;grid-template-columns:210px 1fr;border-top:1px solid #edf2f7}.kv:first-child{border-top:0}.kv .k{font-weight:900;color:#344054;padding:9px 10px;background:#fbfdff}.kv .v{padding:9px 10px;white-space:pre-wrap}@media(max-width:700px){.kv{grid-template-columns:1fr}.kv .k{padding-bottom:2px}.kv .v{padding-top:2px}}
    .docs{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}@media(max-width:900px){.docs{grid-template-columns:1fr}}
    .listline{padding:7px 0;border-top:1px solid #edf2f7}.listline:first-child{border-top:0}.raw{white-space:pre-wrap;border:1px solid var(--border);background:#fff;border-radius:14px;padding:14px;overflow:auto}.hidden{display:none}.placeholder{color:var(--muted);padding:28px;text-align:center}
    .tabs{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px}.tab{background:#e6eef7;color:#102a43}.tab.active{background:var(--navy);color:white}.actions{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;margin-bottom:12px}
  </style>
</head>
<body>
<header><h1>CLAIRE Deal Desk View</h1><p>Select an email, read it, and view the extracted information in Deal Desk fields.</p></header>
<main>
  <div class="layout">
    <aside class="card">
      <h2>Email Selection</h2>
      <div class="body">
        <div id="status" class="status warn">Ready. List emails, select one, then read selected email.</div>
        <label>Search sender / subject</label><input id="search" value="zach">
        <label>Limit</label><input id="limit" value="30">
        <div class="buttons"><button id="listBtn">List Emails</button><button id="readBtn" class="teal">Read Selected Email</button></div>
      </div>
    </aside>
    <section class="card"><h2>Emails</h2><div class="body"><div id="emails" class="email-list"><div class="placeholder">No emails loaded.</div></div></div></section>
  </div>

  <section class="card" style="margin-top:16px">
    <h2>Deal Desk View</h2>
    <div class="body">
      <div class="actions"><button id="copyJson" class="secondary">Copy JSON</button><button id="copySummary" class="secondary">Copy Summary</button><button id="printBtn" class="secondary">Print</button></div>
      <div class="tabs"><button class="tab active" data-tab="deal">Deal Fields</button><button class="tab" data-tab="docs">Documents</button><button class="tab" data-tab="raw">Raw JSON</button></div>
      <div id="dealTab"><div class="placeholder">Read an email to populate Deal Desk fields.</div></div>
      <div id="docsTab" class="hidden"></div>
      <div id="rawTab" class="hidden"><div id="rawJson" class="raw">No JSON yet.</div></div>
    </div>
  </section>
</main>

<script>
(function(){
  const $=id=>document.getElementById(id);
  let selectedUid="", lastResult=null;

  function esc(s){return String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[c]))}
  function setStatus(m,t){$("status").className="status "+(t||"");$("status").textContent=m}
  function api(path){return "./api/claire-dealview"+path}
  async function getJson(url){const r=await fetch(url,{headers:{Accept:"application/json"},cache:"no-store"});const tx=await r.text();let d;try{d=tx?JSON.parse(tx):{}}catch(e){throw new Error("Backend returned non-JSON: "+tx.slice(0,300))}if(!r.ok||d.ok===false)throw new Error(d.error||("HTTP "+r.status));return d}
  function val(v){if(Array.isArray(v))return v.filter(Boolean).join(", "); if(v&&typeof v==="object")return Object.entries(v).filter(([k,x])=>x&&String(x).trim()).map(([k,x])=>`${k}: ${Array.isArray(x)?x.join(", "):x}`).join("\\n"); return v||""}
  function kv(label,value){return `<div class="kv"><div class="k">${esc(label)}</div><div class="v">${esc(val(value)||"—")}</div></div>`}
  function panel(title, rows){return `<div class="panel"><h3>${esc(title)}</h3><div class="panel-body">${rows.join("")}</div></div>`}

  async function listEmails(){
    setStatus("Listing emails...","");
    $("emails").innerHTML='<div class="placeholder">Loading...</div>';
    try{
      const search=encodeURIComponent($("search").value||"");
      const limit=encodeURIComponent($("limit").value||"30");
      const d=await getJson(api(`/emails?search=${search}&limit=${limit}`));
      renderEmails(d.emails||[]);
      setStatus("Emails loaded. Select one email.","ok");
    }catch(e){setStatus(e.message,"err");$("emails").innerHTML='<div class="placeholder">Could not load emails.</div>'}
  }

  function renderEmails(rows){
    if(!rows.length){$("emails").innerHTML='<div class="placeholder">No matching emails.</div>';return}
    $("emails").innerHTML=rows.map(x=>`<div class="email" data-uid="${esc(x.uid)}"><div class="uid">UID ${esc(x.uid)}</div><div class="subj">${esc(x.subject||"(no subject)")}</div><div class="meta">${esc(x.from)}</div><div class="meta">${esc(x.date)} ${x.seen?"seen":"unread"}</div></div>`).join("");
    document.querySelectorAll(".email").forEach(el=>{el.onclick=()=>{document.querySelectorAll(".email").forEach(e=>e.classList.remove("selected"));el.classList.add("selected");selectedUid=el.dataset.uid;setStatus("Selected UID "+selectedUid+". Click Read Selected Email.","ok")}});
  }

  async function readSelected(){
    if(!selectedUid){setStatus("Select an email first.","warn");return}
    setStatus("CLAIRE is reading selected email and documents...","");
    $("dealTab").innerHTML='<div class="placeholder">Reading email and attachments...</div>';
    try{
      const d=await getJson(api(`/read?uid=${encodeURIComponent(selectedUid)}`));
      lastResult=d;
      renderAll(d);
      setStatus("Deal Desk view complete.","ok");
    }catch(e){setStatus(e.message,"err");$("dealTab").innerHTML='<div class="placeholder">Read failed.</div>'}
  }

  function renderAll(d){
    const r=d.result||{};
    const f=r.dealdesk_fields||{};
    const p=f.property||{}, seller=f.seller||{}, buyer=f.purchaser||{}, ls=f.listing_side||{}, bs=f.buyer_side||{}, at=f.attorneys||{}, fin=f.financial_terms||{}, loan=f.financing||{}, cont=f.contingencies||{};
    $("rawJson").textContent=JSON.stringify(r,null,2);

    $("dealTab").innerHTML=`
      <div class="summary">
        <div class="metric"><div class="label">File Status</div><div class="value">${esc(f.file_status||"Intake Review")}</div></div>
        <div class="metric"><div class="label">Property</div><div class="value">${esc(p.address||"—")}</div></div>
        <div class="metric"><div class="label">Seller(s)</div><div class="value">${esc(val(seller.names)||"—")}</div></div>
        <div class="metric"><div class="label">Purchaser(s)</div><div class="value">${esc(val(buyer.names)||"—")}</div></div>
      </div>
      <div class="section"><div class="section-title"><h2>Deal Fields</h2><span class="pill teal">Reviewable draft</span></div>
        <div class="field-grid">
          ${panel("Property", [kv("Address",p.address),kv("MLS #",p.mls_number),kv("Property type",p.property_type)])}
          ${panel("Seller", [kv("Name(s)",seller.names),kv("Address",seller.address),kv("Email",seller.email),kv("Phone",seller.phone)])}
          ${panel("Purchaser", [kv("Name(s)",buyer.names),kv("Address",buyer.address),kv("Email",buyer.email),kv("Phone",buyer.phone)])}
          ${panel("Listing Side", [kv("Broker",ls.broker),kv("Agent",ls.agent),kv("Agent license",ls.agent_license),kv("Email",ls.email),kv("Phone",ls.phone)])}
          ${panel("Buyer Side", [kv("Broker",bs.broker),kv("Agent",bs.agent),kv("Agent license",bs.agent_license),kv("Email",bs.email),kv("Phone",bs.phone)])}
          ${panel("Attorneys", [kv("Seller attorney",at.seller_attorney),kv("Purchaser attorney",at.purchaser_attorney)])}
          ${panel("Financial Terms", [kv("Purchase price",fin.purchase_price),kv("Seller concession",fin.seller_concession),kv("Seller payment to buyer broker",fin.seller_payment_to_buyer_broker),kv("Down payment",fin.down_payment),kv("Mortgage amount",fin.mortgage_amount),kv("Balance due at closing",fin.balance_due_at_closing),kv("Net to seller",fin.net_to_seller)])}
          ${panel("Financing", [kv("Type",loan.financing_type),kv("Lender",loan.lender),kv("Loan officer",loan.loan_officer),kv("Loan officer email",loan.loan_officer_email),kv("Loan officer phone",loan.loan_officer_phone),kv("Preapproval amount",loan.preapproval_amount),kv("Loan amount",loan.loan_amount),kv("Rate / APR",loan.rate_apr),kv("Loan term",loan.loan_term),kv("Preapproval expiration",loan.preapproval_expiration),kv("Financing contingency length",loan.financing_contingency_length)])}
          ${panel("Contingencies", [kv("Financing",cont.financing),kv("Inspection",cont.inspection),kv("Sale of other property",cont.sale_of_other_property),kv("Other",cont.other)])}
          ${panel("Operator Review", [kv("Next action",f.next_action||r.recommended_next_action),kv("Notes",f.notes),kv("Missing items",f.missing_items),kv("Conflicts",f.conflicts),kv("Review flags",f.review_flags)])}
        </div>
      </div>`;

    renderDocs(r.documents||[]);
  }

  function renderDocs(docs){
    if(!docs.length){$("docsTab").innerHTML='<div class="placeholder">No documents returned.</div>';return}
    $("docsTab").innerHTML=`<div class="docs">${docs.map(doc=>{
      const rows=[kv("Document type",doc.document_type),kv("Purpose",doc.purpose),kv("Confidence",doc.confidence),kv("Review flags",doc.review_flags)];
      for(const item of doc.key_fields||[]) rows.push(kv(item.field,item.value));
      for(const item of doc.people_companies||[]) rows.push(kv(item.role || "Person / company", item.name || item.email || item.phone ? `${item.name||""}${item.email?"\\n"+item.email:""}${item.phone?"\\n"+item.phone:""}${item.notes?"\\n"+item.notes:""}` : ""));
      for(const item of doc.dates_deadlines||[]) rows.push(kv(item.field,item.value));
      for(const item of doc.money_terms||[]) rows.push(kv(item.field,item.value));
      for(const item of doc.conditions_contingencies||[]) rows.push(kv(item.field,item.value));
      return `<div class="panel"><h3>Document ${esc(doc.number||"")} — ${esc(doc.filename||"")}</h3><div class="panel-body">${rows.join("")}</div></div>`;
    }).join("")}</div>`;
  }

  $("listBtn").onclick=listEmails;
  $("readBtn").onclick=readSelected;
  $("copyJson").onclick=async()=>{await navigator.clipboard.writeText(JSON.stringify(lastResult?.result||{},null,2));setStatus("JSON copied.","ok")};
  $("copySummary").onclick=async()=>{await navigator.clipboard.writeText(lastResult?.result?.operator_summary||lastResult?.result?.recommended_next_action||"");setStatus("Summary copied.","ok")};
  $("printBtn").onclick=()=>window.print();
  document.querySelectorAll(".tab").forEach(btn=>btn.onclick=()=>{document.querySelectorAll(".tab").forEach(b=>b.classList.remove("active"));btn.classList.add("active");["deal","docs","raw"].forEach(t=>$(t+"Tab").classList.toggle("hidden",btn.dataset.tab!==t))});
})();
</script>
</body>
</html>
HTML

if [ -f "$HTACCESS" ]; then
  if ! grep -q "DEALDESK_CLAIRE_DEALVIEW_PROXY_V1" "$HTACCESS"; then
    if ! grep -qi "^RewriteEngine[[:space:]]\+On" "$HTACCESS"; then
      printf "\nRewriteEngine On\n" >> "$HTACCESS"
    fi
    TMP="$(mktemp)"
    awk -v port="$PORT" '
      BEGIN{inserted=0}
      {
        print
        if (!inserted && tolower($0) ~ /^rewriteengine[[:space:]]+on/) {
          print "# DEALDESK_CLAIRE_DEALVIEW_PROXY_V1"
          print "RewriteRule ^api/claire-dealview/(.*)$ http://127.0.0.1:" port "/api/claire-dealview/$1 [P,L,QSA]"
          print "RewriteRule ^api/dealdesk/claire-dealview/(.*)$ http://127.0.0.1:" port "/api/claire-dealview/$1 [P,L,QSA]"
          print "# END_DEALDESK_CLAIRE_DEALVIEW_PROXY_V1"
          inserted=1
        }
      }
    ' "$HTACCESS" > "$TMP"
    cat "$TMP" > "$HTACCESS"
    rm -f "$TMP"
  fi
else
  cat > "$HTACCESS" <<EOF
RewriteEngine On
# DEALDESK_CLAIRE_DEALVIEW_PROXY_V1
RewriteRule ^api/claire-dealview/(.*)$ http://127.0.0.1:$PORT/api/claire-dealview/\$1 [P,L,QSA]
RewriteRule ^api/dealdesk/claire-dealview/(.*)$ http://127.0.0.1:$PORT/api/claire-dealview/\$1 [P,L,QSA]
# END_DEALDESK_CLAIRE_DEALVIEW_PROXY_V1
EOF
fi

cd "$BACKEND"
npm install imapflow mailparser dotenv >/tmp/claire-dealview-npm-$STAMP.log 2>&1 || {
  cat /tmp/claire-dealview-npm-$STAMP.log
  exit 1
}

node --check "$SIDE"

if pm2 describe "$PM2_NAME" >/dev/null 2>&1; then
  pm2 restart "$PM2_NAME" --update-env
else
  CLAIRE_DEALVIEW_PORT="$PORT" pm2 start "$SIDE" --name "$PM2_NAME" --update-env
fi

sleep 1

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "CLAIRE Deal Desk View installed."
echo ""
echo "Open:"
echo "https://servicedepartment.ai/dealdesk/claire-dealdesk-view.html"
echo ""
echo "Local health:"
curl -sS "http://127.0.0.1:$PORT/api/claire-dealview/health" || true
echo ""
echo ""
echo "PM2:"
pm2 status "$PM2_NAME" || true
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
