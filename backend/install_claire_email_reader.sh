#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_reader_sidecar.js"
HTML="$APPDIR/claire-email-reader.html"
HTACCESS="$APPDIR/.htaccess"
STAMP="$(date +%Y%m%d-%H%M%S)"
PORT="${CLAIRE_READER_PORT:-3021}"
PM2_NAME="dealdesk-claire-reader"

mkdir -p "$BACKEND/backups" "$APPDIR/backups"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing CLAIRE Email Reader sidecar..."
echo "Backend: $BACKEND"
echo "Appdir:  $APPDIR"
echo "Port:    $PORT"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

if [ -f "$SIDE" ]; then cp -f "$SIDE" "$BACKEND/backups/claire_reader_sidecar.js.before-$STAMP.bak"; fi
if [ -f "$HTML" ]; then cp -f "$HTML" "$APPDIR/backups/claire-email-reader.html.before-$STAMP.bak"; fi
if [ -f "$HTACCESS" ]; then cp -f "$HTACCESS" "$APPDIR/backups/.htaccess.before-claire-reader-$STAMP.bak"; fi

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
const PORT = Number(process.env.CLAIRE_READER_PORT || 3021);
const MODEL = process.env.CLAIRE_MODEL || process.env.OPENAI_MODEL || "gpt-4.1";
const MAX_ATTACHMENT_BYTES = Number(process.env.CLAIRE_MAX_ATTACHMENT_BYTES || 25 * 1024 * 1024);

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization"
  });
  res.end(body);
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
    auth: {
      user: cfg.mailbox.user,
      pass: cfg.mailbox.pass
    },
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

async function listEmails({ limit = 20, from = "" }) {
  return withMailbox(async client => {
    const rows = [];
    for await (const msg of client.fetch("1:*", { uid: true, envelope: true, flags: true })) {
      const row = emailLine(msg);
      const haystack = `${row.from} ${row.subject}`.toLowerCase();
      if (from && !haystack.includes(from.toLowerCase())) continue;
      rows.push(row);
    }
    rows.sort((a, b) => Number(b.uid) - Number(a.uid));
    return rows.slice(0, Math.max(1, Math.min(Number(limit) || 20, 100)));
  });
}

async function latestUid(from) {
  const rows = await listEmails({ limit: 1, from });
  if (!rows.length) throw new Error("No matching email found.");
  return rows[0].uid;
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

    const parsed = await simpleParser(msg.source);
    return parsed;
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

function buildPrompt(parsed) {
  const from = parsed.from?.text || "";
  const to = parsed.to?.text || "";
  const subject = parsed.subject || "";
  const date = parsed.date ? new Date(parsed.date).toISOString() : "";
  const body = clean(parsed.text || "").slice(0, 30000);

  return `
You are CLAIRE, Deal Desk's real estate email reader.

Read the email and every attached document like a human transaction coordinator.

Rules:
- Do not use a fixed form template.
- Do not focus on one field.
- Do not silently force uncertain data.
- Do not treat a preapproval, proof of funds, memorandum, contract, inspection, title document, attorney email, or broker note as the same kind of document.
- Read all documents together and explain what each document contributes.
- If documents conflict, flag the conflict and explain which document appears to control which issue.
- If a value is uncertain, say uncertain.
- Give useful operational information, not raw OCR dumps.

Email:
From: ${from}
To: ${to}
Subject: ${subject}
Date: ${date}

Email body:
${body || "[No plain-text email body]"}

Attachments:
${attachmentListText(parsed)}

Return the answer exactly in this structure:

# CLAIRE Email Readout

## Email
- From:
- To:
- Subject:
- Date:
- What this email appears to be:

## Documents Read

For each document:

### Document [number]: [filename]
- Document type:
- What it is for:
- Key information:
- People / companies:
- Contact information:
- Dates / deadlines:
- Money / financing / terms:
- Conditions / contingencies:
- Review flags:
- Confidence:

## Combined Transaction Picture
- Property:
- Seller(s):
- Purchaser(s):
- Agents / brokers:
- Attorneys:
- Lender / loan officer:
- Important terms:
- Open questions / conflicts:
- Recommended next action:

## Deal Desk Intake Draft
Give the practical information an operator would review before deciding whether to set up an accepted-offer deal file.
`;
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

async function askModel(parsed) {
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

    content.push({
      type: "input_file",
      filename,
      file_data: dataUrl(att)
    });
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
      max_output_tokens: 8000
    })
  });

  const text = await response.text();
  let data;
  try {
    data = text ? JSON.parse(text) : {};
  } catch (err) {
    throw new Error("OpenAI returned non-JSON: " + text.slice(0, 600));
  }

  if (!response.ok) {
    throw new Error(data.error?.message || JSON.stringify(data, null, 2));
  }

  return extractOutputText(data);
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

  if (req.method === "GET" && url.pathname === "/api/claire-reader/health") {
    sendJson(res, 200, { ok: true, service: "dealdesk-claire-reader", model: MODEL });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/claire-reader/emails") {
    const from = url.searchParams.get("from") || "";
    const limit = url.searchParams.get("limit") || "20";
    const emails = await listEmails({ from, limit });
    sendJson(res, 200, { ok: true, emails });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/claire-reader/read") {
    let uid = url.searchParams.get("uid") || "";
    const from = url.searchParams.get("from") || "";
    const useLatest = url.searchParams.get("latest") === "1" || url.searchParams.get("latest") === "true";

    if (!uid && useLatest) uid = await latestUid(from);
    if (!uid) throw new Error("Missing uid or latest=1.");

    const parsed = await fetchParsedEmail(uid);
    const attachments = attachmentSummary(parsed);
    const readout = await askModel(parsed);

    sendJson(res, 200, {
      ok: true,
      uid,
      email: {
        from: parsed.from?.text || "",
        to: parsed.to?.text || "",
        subject: parsed.subject || "",
        date: parsed.date ? new Date(parsed.date).toISOString() : "",
        attachments
      },
      readout
    });
    return;
  }

  sendJson(res, 404, { ok: false, error: "Not found" });
}

const server = http.createServer((req, res) => {
  handle(req, res).catch(err => {
    sendJson(res, err.statusCode || 500, {
      ok: false,
      error: err.message || String(err)
    });
  });
});

server.listen(PORT, HOST, () => {
  console.log(`dealdesk-claire-reader listening on http://${HOST}:${PORT}`);
});
NODE

chmod +x "$SIDE"

cat > "$HTML" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>CLAIRE Email Reader</title>
  <style>
    :root{--navy:#071b2c;--teal:#14b8a6;--bg:#f4f7fb;--card:#fff;--border:#dbe5ef;--text:#122033;--muted:#66758a;--bad:#b42318;--ok:#067647;--warn:#b54708}
    *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--text);font-family:Arial,Helvetica,sans-serif}
    header{background:linear-gradient(135deg,var(--navy),#0b263d);color:#fff;padding:18px 20px;border-bottom:4px solid var(--teal)}
    h1{margin:0;font-size:23px} header p{margin:6px 0 0;color:#c7d8e8}
    main{max-width:1180px;margin:18px auto 40px;padding:0 14px}.grid{display:grid;grid-template-columns:360px 1fr;gap:16px}
    @media(max-width:900px){.grid{grid-template-columns:1fr}}
    .card{background:var(--card);border:1px solid var(--border);border-radius:14px;box-shadow:0 10px 28px rgba(15,35,55,.06);overflow:hidden}
    .card h2{margin:0;padding:14px 16px;font-size:16px;background:#f8fbfe;border-bottom:1px solid var(--border)}.body{padding:16px}
    label{display:block;font-size:12px;font-weight:700;color:#344054;margin:12px 0 5px}
    input{width:100%;border:1px solid #cbd5e1;border-radius:10px;padding:11px 12px;font-size:14px}
    button{border:0;border-radius:10px;padding:11px 13px;font-weight:700;cursor:pointer;background:var(--navy);color:white}button.secondary{background:#e6eef7;color:#102a43}button.teal{background:var(--teal);color:#06251f}button:disabled{opacity:.55}
    .row{display:flex;gap:10px}.row>*{flex:1}.buttons{display:grid;gap:10px;margin-top:14px}
    .status{padding:12px 14px;border-radius:12px;margin-bottom:12px;border:1px solid var(--border);background:#f8fbfe;color:#344054;font-size:14px;white-space:pre-wrap}.status.ok{background:#ecfdf3;border-color:#abefc6;color:var(--ok)}.status.err{background:#fef3f2;border-color:#fecdca;color:var(--bad)}.status.warn{background:#fffaeb;border-color:#fedf89;color:var(--warn)}
    .email-list{display:grid;gap:10px;max-height:540px;overflow:auto}.email{border:1px solid var(--border);border-radius:12px;padding:12px;background:#fff;cursor:pointer}.email:hover{border-color:var(--teal);background:#f7fffd}.uid{font-size:12px;color:var(--teal);font-weight:800}.subj{font-weight:800;margin-top:5px}.meta{font-size:12px;color:var(--muted);margin-top:4px}
    .top-actions{display:flex;gap:10px;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid var(--border);background:#fff}.pill{display:inline-block;padding:4px 8px;border-radius:999px;background:#e6eef7;color:#24415c;font-size:12px;font-weight:700}
    .readout{padding:18px;line-height:1.45;white-space:pre-wrap;font-size:14px}.placeholder{color:var(--muted);padding:28px;text-align:center}.small{color:var(--muted);font-size:12px;margin-top:8px}.endpoint{font-family:Menlo,Consolas,monospace;font-size:12px;background:#f1f5f9;border:1px solid #dbe5ef;border-radius:8px;padding:8px;overflow:auto}
  </style>
</head>
<body>
<header><h1>CLAIRE Email Reader</h1><p>Reads an email and its attached documents. No deal creation. No database write. Review first.</p></header>
<main>
  <div class="grid">
    <section class="card"><h2>Email Controls</h2><div class="body">
      <div id="status" class="status warn">Ready. Click List Emails or Read Latest Matching Email.</div>
      <label>API Base</label><input id="apiBase" value="./api/claire-reader">
      <label>From / search filter</label><input id="fromFilter" value="zach">
      <div class="row"><div><label>Limit</label><input id="limit" value="20"></div><div><label>UID</label><input id="uid" placeholder="optional"></div></div>
      <div class="buttons"><button id="listBtn">List Emails</button><button id="latestBtn" class="teal">Read Latest Matching Email</button><button id="uidBtn" class="secondary">Read UID</button></div>
      <p class="small">Secrets stay server-side. This page calls the CLAIRE reader sidecar.</p>
      <label>Endpoints</label><div class="endpoint">GET ./api/claire-reader/emails?from=zach&limit=20
GET ./api/claire-reader/read?from=zach&latest=1
GET ./api/claire-reader/read?uid=123</div>
    </div></section>
    <section class="card"><div class="top-actions"><span class="pill">Email list</span><button id="clearBtn" class="secondary">Clear</button></div><div class="body"><div id="emails" class="email-list"><div class="placeholder">No emails loaded yet.</div></div></div></section>
  </div>
  <section class="card" style="margin-top:16px"><div class="top-actions"><span class="pill">CLAIRE Readout</span><button id="copyBtn" class="secondary">Copy Readout</button></div><div id="readout" class="readout"><div class="placeholder">Read an email to see the document-by-document digest here.</div></div></section>
</main>
<script>
(function(){
  const $=id=>document.getElementById(id), status=$("status"), emails=$("emails"), readout=$("readout");
  function setStatus(m,t){status.className="status "+(t||"");status.textContent=m}
  function base(){return $("apiBase").value.replace(/\/+$/,"")}
  function esc(s){return String(s||"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[c]))}
  async function json(url){const r=await fetch(url,{headers:{Accept:"application/json"},cache:"no-store"});const tx=await r.text();let d;try{d=tx?JSON.parse(tx):{}}catch(e){throw new Error("Backend did not return JSON: "+tx.slice(0,300))}if(!r.ok||d.ok===false)throw new Error(d.error||("HTTP "+r.status));return d}
  function renderEmails(list){if(!list||!list.length){emails.innerHTML='<div class="placeholder">No matching emails.</div>';return}emails.innerHTML=list.map(x=>`<div class="email" data-uid="${esc(x.uid)}"><div class="uid">UID ${esc(x.uid)}</div><div class="subj">${esc(x.subject||"(no subject)")}</div><div class="meta">${esc(x.from)}</div><div class="meta">${esc(x.date)} ${x.seen?"seen":"unread"}</div></div>`).join("");emails.querySelectorAll(".email").forEach(el=>el.onclick=()=>{$("uid").value=el.dataset.uid;readUid()})}
  function renderReadout(d){readout.textContent=d.readout||d.output||d.text||JSON.stringify(d,null,2)}
  async function listEmails(){setStatus("Listing emails...","");emails.innerHTML='<div class="placeholder">Loading...</div>';try{const d=await json(`${base()}/emails?from=${encodeURIComponent($("fromFilter").value)}&limit=${encodeURIComponent($("limit").value||20)}`);renderEmails(d.emails);setStatus("Emails loaded.","ok")}catch(e){setStatus(e.message,"err")}}
  async function readLatest(){setStatus("CLAIRE is reading latest matching email...","");readout.textContent="Reading email and attachments...";try{const d=await json(`${base()}/read?latest=1&from=${encodeURIComponent($("fromFilter").value)}`);renderReadout(d);setStatus("Readout complete.","ok")}catch(e){setStatus(e.message,"err");readout.textContent=""}}
  async function readUid(){const uid=$("uid").value.trim();if(!uid){setStatus("Enter or click a UID.","warn");return}setStatus("CLAIRE is reading UID "+uid+"...","");readout.textContent="Reading email and attachments...";try{const d=await json(`${base()}/read?uid=${encodeURIComponent(uid)}`);renderReadout(d);setStatus("Readout complete.","ok")}catch(e){setStatus(e.message,"err");readout.textContent=""}}
  $("listBtn").onclick=listEmails;$("latestBtn").onclick=readLatest;$("uidBtn").onclick=readUid;$("clearBtn").onclick=()=>{emails.innerHTML='<div class="placeholder">No emails loaded yet.</div>';readout.innerHTML='<div class="placeholder">Read an email to see the document-by-document digest here.</div>';setStatus("Cleared.","warn")};$("copyBtn").onclick=async()=>{await navigator.clipboard.writeText(readout.textContent||"");setStatus("Readout copied.","ok")}
})();
</script>
</body>
</html>
HTML

if [ -f "$HTACCESS" ]; then
  if ! grep -q "DEALDESK_CLAIRE_READER_PROXY_V1" "$HTACCESS"; then
    if ! grep -qi "^RewriteEngine[[:space:]]\+On" "$HTACCESS"; then
      printf "\nRewriteEngine On\n" >> "$HTACCESS"
    fi
    TMP="$(mktemp)"
    awk -v port="$PORT" '
      BEGIN{inserted=0}
      {
        print
        if (!inserted && tolower($0) ~ /^rewriteengine[[:space:]]+on/) {
          print "# DEALDESK_CLAIRE_READER_PROXY_V1"
          print "RewriteRule ^api/claire-reader/(.*)$ http://127.0.0.1:" port "/api/claire-reader/$1 [P,L,QSA]"
          print "RewriteRule ^api/dealdesk/claire-reader/(.*)$ http://127.0.0.1:" port "/api/claire-reader/$1 [P,L,QSA]"
          print "# END_DEALDESK_CLAIRE_READER_PROXY_V1"
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
# DEALDESK_CLAIRE_READER_PROXY_V1
RewriteRule ^api/claire-reader/(.*)$ http://127.0.0.1:$PORT/api/claire-reader/\$1 [P,L,QSA]
RewriteRule ^api/dealdesk/claire-reader/(.*)$ http://127.0.0.1:$PORT/api/claire-reader/\$1 [P,L,QSA]
# END_DEALDESK_CLAIRE_READER_PROXY_V1
EOF
fi

cd "$BACKEND"
npm install imapflow mailparser dotenv >/tmp/claire-reader-npm-$STAMP.log 2>&1 || {
  cat /tmp/claire-reader-npm-$STAMP.log
  exit 1
}

node --check "$SIDE"

if pm2 describe "$PM2_NAME" >/dev/null 2>&1; then
  pm2 restart "$PM2_NAME" --update-env
else
  CLAIRE_READER_PORT="$PORT" pm2 start "$SIDE" --name "$PM2_NAME" --update-env
fi

sleep 1

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "CLAIRE Email Reader installed."
echo ""
echo "Viewer:"
echo "https://servicedepartment.ai/dealdesk/claire-email-reader.html"
echo ""
echo "Local health:"
curl -sS "http://127.0.0.1:$PORT/api/claire-reader/health" || true
echo ""
echo ""
echo "PM2:"
pm2 status "$PM2_NAME" || true
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
