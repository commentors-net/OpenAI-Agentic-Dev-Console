#!/usr/bin/env node
/**
 * Deal Desk CLAIRE - Email Document Reader (no DB, no storage)
 *
 * Purpose:
 * - Read one email from the intake mailbox.
 * - Send the email body + attachments to the real AI model.
 * - Print a document-by-document digest in plain English/Markdown.
 *
 * It does NOT:
 * - write to MySQL
 * - create a deal
 * - assume a document template
 * - rely on regex extraction as the brain
 *
 * Install dependencies once:
 *   cd /home/servicedepartmen/dealdesk-backend
 *   npm install openai imapflow mailparser
 *
 * Required:
 *   export OPENAI_API_KEY="sk-..."
 *
 * Examples:
 *   node claire_email_reader.js --list 20
 *   node claire_email_reader.js --uid 123
 *   node claire_email_reader.js --latest
 *   node claire_email_reader.js --from zach --latest
 */

const fs = require("fs");
const { ImapFlow } = require("imapflow");
const { simpleParser } = require("mailparser");
const OpenAI = require("openai");

const CONFIG_PATH = "/home/servicedepartmen/dealdesk-backend/email-intake.config.json";

function arg(name, fallback = "") {
  const i = process.argv.indexOf("--" + name);
  if (i >= 0 && process.argv[i + 1]) return process.argv[i + 1];
  return fallback;
}

function flag(name) {
  return process.argv.includes("--" + name);
}

function die(msg) {
  console.error("ERROR:", msg);
  process.exit(1);
}

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) die("Missing mailbox config: " + CONFIG_PATH);
  const cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  if (!cfg.mailbox) die("Config missing mailbox section.");
  for (const k of ["host", "user", "pass"]) {
    if (!cfg.mailbox[k]) die("Config missing mailbox." + k);
  }
  return cfg;
}

function mailboxClient(cfg) {
  return new ImapFlow({
    host: cfg.mailbox.host,
    port: cfg.mailbox.port || 993,
    secure: cfg.mailbox.secure !== false,
    auth: {
      user: cfg.mailbox.user,
      pass: cfg.mailbox.pass
    },
    logger: false
  });
}

function clean(s) {
  return String(s || "").replace(/\s+/g, " ").trim();
}

function headerLine(msg) {
  const from = msg.envelope?.from?.map(x => `${x.name || ""} <${x.address || ""}>`).join(", ") || "";
  const subject = msg.envelope?.subject || "";
  const date = msg.envelope?.date ? new Date(msg.envelope.date).toISOString() : "";
  const seen = Array.from(msg.flags || []).includes("\\Seen") ? "seen" : "unread";
  return `UID ${msg.uid} | ${seen} | ${date} | ${from} | ${subject}`;
}

async function withMailbox(fn) {
  const cfg = loadConfig();
  const client = mailboxClient(cfg);
  await client.connect();
  const mailboxName = cfg.processing?.mailbox || "INBOX";
  const lock = await client.getMailboxLock(mailboxName);
  try {
    return await fn(client, cfg, mailboxName);
  } finally {
    lock.release();
    await client.logout().catch(() => {});
  }
}

async function listMessages(limit, fromFilter) {
  return withMailbox(async (client) => {
    const rows = [];
    for await (const msg of client.fetch("1:*", { uid: true, envelope: true, flags: true })) {
      const line = headerLine(msg);
      if (fromFilter && !line.toLowerCase().includes(fromFilter.toLowerCase())) continue;
      rows.push(msg);
    }

    rows.sort((a, b) => Number(b.uid) - Number(a.uid));

    console.log("****************************");
    console.log("EMAILS");
    console.log("****************************");
    for (const msg of rows.slice(0, limit)) {
      console.log(headerLine(msg));
    }
    console.log("****************************");
  });
}

async function findLatestUid(fromFilter) {
  return withMailbox(async (client) => {
    const rows = [];
    for await (const msg of client.fetch("1:*", { uid: true, envelope: true, flags: true })) {
      const line = headerLine(msg);
      if (fromFilter && !line.toLowerCase().includes(fromFilter.toLowerCase())) continue;
      rows.push(msg);
    }
    rows.sort((a, b) => Number(b.uid) - Number(a.uid));
    if (!rows.length) die("No matching emails found.");
    return rows[0].uid;
  });
}

async function fetchParsedEmail(uid) {
  return withMailbox(async (client) => {
    const msg = await client.fetchOne(String(uid), {
      uid: true,
      envelope: true,
      source: true,
      flags: true
    }, { uid: true });

    if (!msg || !msg.source) die("Email UID not found: " + uid);

    const parsed = await simpleParser(msg.source);
    return { msg, parsed };
  });
}

function dataUrlForAttachment(att) {
  const mime = att.contentType || "application/octet-stream";
  const b64 = Buffer.from(att.content || Buffer.alloc(0)).toString("base64");
  return `data:${mime};base64,${b64}`;
}

function attachmentSummary(att, i) {
  return {
    number: i + 1,
    filename: att.filename || `attachment-${i + 1}`,
    mime_type: att.contentType || "",
    size_bytes: att.size || (att.content ? att.content.length : 0)
  };
}

function buildPrompt({ parsed }) {
  const from = parsed.from?.text || "";
  const to = parsed.to?.text || "";
  const subject = parsed.subject || "";
  const date = parsed.date ? new Date(parsed.date).toISOString() : "";
  const bodyText = clean(parsed.text || "").slice(0, 30000);
  const attachments = parsed.attachments || [];

  return `
You are CLAIRE, Deal Desk's real estate email document reader.

Task:
Read the email body and every attached document like a human transaction coordinator.
Do not use a fixed template.
Do not focus on only one field.
Classify each document and extract the useful transaction information.
If documents conflict, say so.
If a value is uncertain, say uncertain.
If a document is financing support, attorney contact, offer memo, proof of funds, inspection, title, contract, or anything else, identify its role.
Do not silently choose bad data.

Email:
From: ${from}
To: ${to}
Subject: ${subject}
Date: ${date}

Email body:
${bodyText || "[No plain-text email body found]"}

Attachments:
${attachments.map(attachmentSummary).map(a => `- ${a.number}. ${a.filename} | ${a.mime_type} | ${a.size_bytes} bytes`).join("\n")}

Return the answer in this exact structure:

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
- People/companies:
- Contact information:
- Dates/deadlines:
- Money/financing/terms:
- Conditions/contingencies:
- Review flags:
- Confidence:

## Combined Transaction Picture
- Property:
- Seller(s):
- Purchaser(s):
- Agents/brokers:
- Attorneys:
- Lender/loan officer:
- Important terms:
- Open questions / conflicts:
- Recommended next action:

## Deal Desk Intake Draft
Provide a practical draft of the information a Deal Desk operator would need to review before creating an accepted-offer file.
`;
}

async function askModelToReadEmail({ parsed, msg }) {
  if (!process.env.OPENAI_API_KEY) {
    die("OPENAI_API_KEY is not set. Export it first, then rerun.");
  }

  const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  const attachments = parsed.attachments || [];

  const content = [
    {
      type: "input_text",
      text: buildPrompt({ parsed, msg })
    }
  ];

  for (const att of attachments) {
    const mime = att.contentType || "";
    const filename = att.filename || "attachment";
    const lower = filename.toLowerCase();
    const allowed = (
      mime.includes("pdf") ||
      mime.startsWith("image/") ||
      mime.includes("word") ||
      lower.endsWith(".pdf") ||
      lower.endsWith(".png") ||
      lower.endsWith(".jpg") ||
      lower.endsWith(".jpeg") ||
      lower.endsWith(".webp") ||
      lower.endsWith(".docx")
    );

    if (!allowed) continue;

    content.push({
      type: "input_file",
      filename,
      file_data: dataUrlForAttachment(att)
    });
  }

  const model = process.env.CLAIRE_MODEL || process.env.OPENAI_MODEL || "gpt-5.5";

  const response = await openai.responses.create({
    model,
    input: [
      {
        role: "user",
        content
      }
    ]
  });

  return response.output_text || JSON.stringify(response, null, 2);
}

async function main() {
  const fromFilter = arg("from", "");
  if (flag("list")) {
    const limit = Number(arg("list", "20")) || 20;
    await listMessages(limit, fromFilter);
    return;
  }

  let uid = arg("uid", "");
  if (!uid && flag("latest")) {
    uid = await findLatestUid(fromFilter);
  }

  if (!uid) {
    console.log("Usage:");
    console.log("  node claire_email_reader.js --list 20");
    console.log("  node claire_email_reader.js --uid 123");
    console.log("  node claire_email_reader.js --latest");
    console.log("  node claire_email_reader.js --from zach --latest");
    process.exit(1);
  }

  const { msg, parsed } = await fetchParsedEmail(uid);

  console.log("****************************");
  console.log("CLAIRE READING EMAIL UID", uid);
  console.log("****************************");
  console.log("From:", parsed.from?.text || "");
  console.log("Subject:", parsed.subject || "");
  console.log("Attachments:", (parsed.attachments || []).length);
  for (const [i, att] of (parsed.attachments || []).entries()) {
    console.log(`- ${i + 1}. ${att.filename || "attachment"} | ${att.contentType || ""} | ${att.size || att.content?.length || 0} bytes`);
  }
  console.log("****************************");

  const readout = await askModelToReadEmail({ parsed, msg });

  console.log("");
  console.log(readout);
  console.log("");
  console.log("****************************");
  console.log("END CLAIRE READOUT");
  console.log("****************************");
}

main().catch(err => {
  console.error("ERROR:", err && err.stack ? err.stack : err.message || err);
  process.exit(1);
});
