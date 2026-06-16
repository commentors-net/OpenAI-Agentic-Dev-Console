#!/usr/bin/env node
const nodemailer = require("nodemailer");
const puppeteer = require("puppeteer");

const http = require("http");
const fs = require("fs");
const path = require("path");
const PDFDocument = require("pdfkit");
const crypto = require("crypto");
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

const CLAIRE_PDF_PUBLIC_ROOT = "/home/servicedepartmen/public_html/dealdesk";
const CLAIRE_PDF_SOURCE_ROOT = path.join(CLAIRE_PDF_PUBLIC_ROOT, "source-docs");
const CLAIRE_PDF_MANIFEST_ROOT = path.join(CLAIRE_PDF_SOURCE_ROOT, "manifests");
try { fs.mkdirSync(CLAIRE_PDF_SOURCE_ROOT, { recursive: true }); fs.mkdirSync(CLAIRE_PDF_MANIFEST_ROOT, { recursive: true }); } catch (err) {}


const CACHE_DIR = path.join(BACKEND, "cache", "claire-dealview");
const CACHE_TTL_MS = Number(process.env.CLAIRE_DEALVIEW_CACHE_TTL_MS || 24 * 60 * 60 * 1000);
try { fs.mkdirSync(CACHE_DIR, { recursive: true }); } catch (err) {}


const PUBLIC_DEALDESK_ROOT = "/home/servicedepartmen/public_html/dealdesk";
const SOURCE_DOC_ROOT = path.join(PUBLIC_DEALDESK_ROOT, "source-docs");
const SOURCE_DOC_MANIFEST_ROOT = path.join(SOURCE_DOC_ROOT, "manifests");
try { fs.mkdirSync(SOURCE_DOC_ROOT, { recursive: true }); fs.mkdirSync(SOURCE_DOC_MANIFEST_ROOT, { recursive: true }); } catch (err) {}


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


function extractFirstJsonObject(raw) {
  const s = String(raw || "").trim();
  const start = s.indexOf("{");
  if (start < 0) return "";

  let depth = 0;
  let inString = false;
  let escape = false;

  for (let i = start; i < s.length; i++) {
    const ch = s[i];

    if (inString) {
      if (escape) {
        escape = false;
      } else if (ch === "\\") {
        escape = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }

    if (ch === "{") depth++;
    if (ch === "}") {
      depth--;
      if (depth === 0) return s.slice(start, i + 1);
    }
  }

  return "";
}

function parseJsonModelOutput(text) {
  const raw = String(text || "").trim();

  function parseMaybe(value) {
    if (!value) return null;
    try { return JSON.parse(value); } catch (err) { return null; }
  }

  let parsed = parseMaybe(raw);
  if (parsed) return parsed;

  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced) {
    parsed = parseMaybe(fenced[1].trim());
    if (parsed) return parsed;

    const firstFenced = extractFirstJsonObject(fenced[1]);
    parsed = parseMaybe(firstFenced);
    if (parsed) return parsed;
  }

  const first = extractFirstJsonObject(raw);
  parsed = parseMaybe(first);
  if (parsed) return parsed;

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


function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk.toString("utf8");
      if (body.length > 2_000_000) {
        reject(new Error("Request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function safeSlug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "deal";
}

function safeFilename(value, fallback) {
  const base = String(value || fallback || "document.pdf")
    .replace(/[\/\\:*?"<>|]+/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 140);
  return base || fallback || "document.pdf";
}

function publicSourceDocUrl(relativePath) {
  return "./source-docs/" + relativePath.split(path.sep).map(encodeURIComponent).join("/");
}

function manifestFile(alias) {
  return path.join(SOURCE_DOC_MANIFEST_ROOT, safeSlug(alias) + ".json");
}

function readManifest(alias) {
  const file = manifestFile(alias);
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeManifestAliases(manifest, aliases) {
  const unique = Array.from(new Set((aliases || []).filter(Boolean).map(String)));
  for (const alias of unique) {
    fs.writeFileSync(manifestFile(alias), JSON.stringify(manifest, null, 2), "utf8");
  }
}

async function saveSourceDocsForDeal(uid, parsed, body) {
  const deal = body.deal || {};
  const dealId = String(body.deal_id || body.dealId || deal.id || deal.deal_id || "").trim();
  const publicId = String(body.deal_public_id || body.public_id || deal.public_id || "").trim();
  const property = String(body.property_address || deal.property_address || body.property || "").trim();
  const folderName = safeSlug(publicId || dealId || property || ("email-" + uid));
  const folder = path.join(SOURCE_DOC_ROOT, folderName);
  fs.mkdirSync(folder, { recursive: true });

  const docs = [];
  let index = 0;

  for (const att of parsed.attachments || []) {
    index++;
    const filename = safeFilename(att.filename, `source-document-${index}.pdf`);
    const outName = String(index).padStart(2, "0") + "-" + filename;
    const outPath = path.join(folder, outName);
    fs.writeFileSync(outPath, Buffer.from(att.content || Buffer.alloc(0)));

    const relative = path.join(folderName, outName);
    docs.push({
      number: index,
      filename,
      stored_filename: outName,
      url: publicSourceDocUrl(relative),
      mime_type: att.contentType || "",
      size_bytes: att.size || (att.content ? att.content.length : 0)
    });
  }

  const aliases = [dealId, publicId, property, folderName].filter(Boolean);
  const manifest = {
    ok: true,
    created_at: new Date().toISOString(),
    uid: String(uid || ""),
    deal_id: dealId,
    deal_public_id: publicId,
    property_address: property,
    folder: folderName,
    source_documents: docs,
    inspection_prefill: body.inspection_prefill || null,
    claire_result: body.claire_result || null,
    claire_backup_note: "Full CLAIRE intake read preserved here. Additional Terms stays short."
  };

  writeManifestAliases(manifest, aliases.length ? aliases : [folderName]);
  try { rebuildSourceDocumentsIndex(); } catch (err) {}
  return manifest;
}

function dbConfigForClaire() {
  return {
    host: process.env.DB_HOST || process.env.MYSQL_HOST || "localhost",
    user: process.env.DB_USER || process.env.MYSQL_USER || process.env.MYSQL_USERNAME || "servicedepartmen_dealdesk",
    password: process.env.DB_PASSWORD || process.env.MYSQL_PASSWORD || process.env.DB_PASS || "",
    database: process.env.DB_NAME || process.env.MYSQL_DATABASE || process.env.DATABASE_NAME || "servicedepartmen_dealdesk",
    multipleStatements: false
  };
}

function quoteSqlId(id) {
  return "`" + String(id).replace(/`/g, "``") + "`";
}




async function bestEffortClearInspectionForDeal(aliases, note) {
  let mysql;
  try { mysql = require("mysql2/promise"); } catch (err) { return { ok: false, skipped: true, reason: "mysql2 not available" }; }

  const cleanAliases = Array.from(new Set((aliases || []).filter(Boolean).map(String)));
  if (!cleanAliases.length) return { ok: false, skipped: true, reason: "no deal identifiers" };

  const conn = await mysql.createConnection(dbConfigForClaire());
  const changed = [];
  const inspected = [];
  const errors = [];

  try {
    const [cols] = await conn.query(`
      SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
      ORDER BY TABLE_NAME, ORDINAL_POSITION
    `);

    const byTable = new Map();
    for (const c of cols) {
      if (!byTable.has(c.TABLE_NAME)) byTable.set(c.TABLE_NAME, []);
      byTable.get(c.TABLE_NAME).push(c);
    }

    const expandedAliases = new Set(cleanAliases);

    // Expand from deal rows matching property/public id/id.
    for (const [table, tableCols] of byTable.entries()) {
      const names = tableCols.map(c => c.COLUMN_NAME);
      const textCols = tableCols
        .filter(c => /char|text|json|enum|set/i.test(String(c.DATA_TYPE || "")))
        .map(c => c.COLUMN_NAME);

      const wheres = [];
      const params = [];

      for (const col of ["id", "deal_id", "public_id", "deal_public_id", "file_id", "transaction_id"]) {
        if (names.includes(col)) {
          wheres.push(`${quoteSqlId(col)} IN (${cleanAliases.map(() => "?").join(",")})`);
          params.push(...cleanAliases);
        }
      }

      for (const col of textCols) {
        for (const a of cleanAliases) {
          if (!a || a.length < 3) continue;
          wheres.push(`${quoteSqlId(col)} LIKE ?`);
          params.push(`%${a}%`);
        }
      }

      if (!wheres.length) continue;

      try {
        const [rows] = await conn.query(`SELECT * FROM ${quoteSqlId(table)} WHERE ${wheres.join(" OR ")} LIMIT 150`, params);
        for (const row of rows) {
          for (const k of ["id","deal_id","public_id","deal_public_id","file_id","transaction_id","property_address"]) {
            if (row[k] !== undefined && row[k] !== null && String(row[k]).trim()) expandedAliases.add(String(row[k]));
          }
        }
      } catch (err) {}
    }

    const allAliases = Array.from(expandedAliases);

    const statusCols = ["status", "clearance_status", "item_status", "state", "task_status"];
    const doneCols = ["is_complete", "complete", "completed", "is_completed", "cleared", "is_cleared", "done", "is_done", "resolved", "is_resolved"];
    const timeCols = ["completed_at", "cleared_at", "resolved_at", "updated_at"];
    const proofCols = ["proof_note", "manager_proof_note", "evidence_note", "clearance_note", "completion_note", "response_summary", "note", "notes", "operator_note", "details", "manager_proof"];
    const relationCols = ["deal_id", "dealId", "deal_public_id", "public_id", "file_id", "transaction_id"];

    for (const [table, tableCols] of byTable.entries()) {
      const names = tableCols.map(c => c.COLUMN_NAME);
      const textCols = tableCols
        .filter(c => /char|text|json|enum|set/i.test(String(c.DATA_TYPE || "")))
        .map(c => c.COLUMN_NAME);

      if (!textCols.length) continue;

      const relationWheres = [];
      const relationParams = [];

      for (const col of relationCols) {
        if (names.includes(col)) {
          relationWheres.push(`${quoteSqlId(col)} IN (${allAliases.map(() => "?").join(",")})`);
          relationParams.push(...allAliases);
        }
      }

      for (const col of textCols) {
        for (const a of allAliases) {
          if (!a || a.length < 3) continue;
          relationWheres.push(`${quoteSqlId(col)} LIKE ?`);
          relationParams.push(`%${a}%`);
        }
      }

      if (!relationWheres.length) continue;

      const inspectionWheres = textCols.map(c => `${quoteSqlId(c)} LIKE ?`);
      const inspectionParams = textCols.map(() => "%inspection%");

      let rows = [];
      try {
        [rows] = await conn.query(
          `SELECT * FROM ${quoteSqlId(table)} WHERE (${relationWheres.join(" OR ")}) AND (${inspectionWheres.join(" OR ")}) LIMIT 150`,
          [...relationParams, ...inspectionParams]
        );
      } catch (err) {
        errors.push({ table, stage: "select", error: err.message });
        continue;
      }

      if (!rows.length) continue;
      inspected.push({ table, rows: rows.length });

      const sets = [];
      const values = [];

      for (const col of statusCols) {
        if (names.includes(col)) {
          sets.push(`${quoteSqlId(col)}=?`);
          values.push("Cleared");
        }
      }

      for (const col of doneCols) {
        if (names.includes(col)) {
          sets.push(`${quoteSqlId(col)}=?`);
          values.push(1);
        }
      }

      for (const col of timeCols) {
        if (names.includes(col)) sets.push(`${quoteSqlId(col)}=NOW()`);
      }

      for (const col of proofCols) {
        if (names.includes(col)) {
          sets.push(`${quoteSqlId(col)}=?`);
          values.push(note);
          break;
        }
      }

      if (!sets.length) continue;

      try {
        if (names.includes("id")) {
          const ids = rows.map(r => r.id).filter(v => v !== undefined && v !== null);
          if (!ids.length) continue;
          const [result] = await conn.query(
            `UPDATE ${quoteSqlId(table)} SET ${sets.join(", ")} WHERE ${quoteSqlId("id")} IN (${ids.map(() => "?").join(",")})`,
            [...values, ...ids]
          );
          if (result.affectedRows) changed.push({ table, rows: result.affectedRows, method: "id" });
        } else {
          const [result] = await conn.query(
            `UPDATE ${quoteSqlId(table)} SET ${sets.join(", ")} WHERE (${relationWheres.join(" OR ")}) AND (${inspectionWheres.join(" OR ")})`,
            [...values, ...relationParams, ...inspectionParams]
          );
          if (result.affectedRows) changed.push({ table, rows: result.affectedRows, method: "relation+inspection" });
        }
      } catch (err) {
        errors.push({ table, stage: "update", error: err.message });
      }
    }

    return { ok: true, aliases: allAliases, inspected, changed, errors };
  } catch (err) {
    return { ok: false, error: err.message, inspected, changed, errors };
  } finally {
    await conn.end().catch(() => {});
  }
}






function cacheKeyForParsedEmail(uid, parsed) {
  const attachments = (parsed.attachments || []).map(att => ({
    filename: att.filename || "",
    type: att.contentType || "",
    size: att.size || (att.content ? att.content.length : 0)
  }));
  const basis = JSON.stringify({
    uid: String(uid || ""),
    model: MODEL,
    subject: parsed.subject || "",
    date: parsed.date ? new Date(parsed.date).toISOString() : "",
    attachments
  });
  return crypto.createHash("sha256").update(basis).digest("hex");
}

function cachePathForKey(key) {
  return path.join(CACHE_DIR, key + ".json");
}

function readCachedResult(key) {
  const file = cachePathForKey(key);
  if (!fs.existsSync(file)) return null;
  const stat = fs.statSync(file);
  if (Date.now() - stat.mtimeMs > CACHE_TTL_MS) return null;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeCachedResult(key, payload) {
  const file = cachePathForKey(key);
  fs.writeFileSync(file, JSON.stringify(payload, null, 2), "utf8");
}


function readAllSourceDocManifests() {
  const out = [];
  try {
    if (!fs.existsSync(SOURCE_DOC_MANIFEST_ROOT)) return out;
    for (const name of fs.readdirSync(SOURCE_DOC_MANIFEST_ROOT)) {
      if (!name.toLowerCase().endsWith(".json")) continue;
      const file = path.join(SOURCE_DOC_MANIFEST_ROOT, name);
      try {
        const data = JSON.parse(fs.readFileSync(file, "utf8"));
        data._manifest_file = file;
        out.push(data);
      } catch (err) {}
    }
  } catch (err) {}
  return out;
}

function findSourceDocManifest(query) {
  const q = String(query || "").trim().toLowerCase();
  if (!q) return null;

  // First try exact alias manifest.
  try {
    const exact = readManifest(query);
    if (exact) return exact;
  } catch (err) {}

  const manifests = readAllSourceDocManifests();

  for (const m of manifests) {
    const fields = [
      m.deal_id,
      m.deal_public_id,
      m.public_id,
      m.property_address,
      m.folder,
      ...(m.source_documents || []).map(d => d.filename || "")
    ].filter(Boolean).map(v => String(v).toLowerCase());

    if (fields.some(v => v === q || v.includes(q) || q.includes(v))) return m;
  }

  const words = q.split(/[^a-z0-9]+/).filter(w => w.length >= 4);
  if (words.length) {
    let best = null;
    let bestScore = 0;
    for (const m of manifests) {
      const hay = JSON.stringify(m).toLowerCase();
      const score = words.reduce((n, w) => n + (hay.includes(w) ? 1 : 0), 0);
      if (score > bestScore) {
        best = m;
        bestScore = score;
      }
    }
    if (best && bestScore >= Math.min(2, words.length)) return best;
  }

  return null;
}


function rebuildSourceDocumentsIndex() {
  try {
    const root = SOURCE_DOC_ROOT;
    const outFile = path.join(root, "source-documents-index.json");
    const docs = [];

    function encRel(rel) {
      return "./source-docs/" + rel.split(path.sep).map(encodeURIComponent).join("/");
    }

    function walk(dir) {
      if (!fs.existsSync(dir)) return;
      for (const name of fs.readdirSync(dir)) {
        const full = path.join(dir, name);
        const rel = path.relative(root, full);
        if (!rel || rel === "source-documents-index.json") continue;
        if (rel.startsWith("manifests" + path.sep)) continue;
        const st = fs.statSync(full);
        if (st.isDirectory()) {
          walk(full);
        } else {
          const ext = path.extname(name).toLowerCase();
          if (![".pdf", ".png", ".jpg", ".jpeg", ".webp", ".txt", ".doc", ".docx"].includes(ext)) continue;
          docs.push({
            filename: name,
            folder: rel.split(path.sep)[0] || "",
            relative_path: rel,
            url: encRel(rel),
            size_bytes: st.size,
            modified_at: st.mtime.toISOString()
          });
        }
      }
    }

    fs.mkdirSync(root, { recursive: true });
    walk(root);
    docs.sort((a, b) => a.relative_path.localeCompare(b.relative_path));
    fs.writeFileSync(outFile, JSON.stringify({ ok: true, generated_at: new Date().toISOString(), source_documents: docs }, null, 2), "utf8");
    return docs;
  } catch (err) {
    return [];
  }
}


function clairePdfReadBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk.toString("utf8");
      if (body.length > 5_000_000) {
        reject(new Error("Request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function clairePdfSafeSlug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 90) || "deal";
}

function clairePdfSafeFile(value) {
  return String(value || "deal-sheet.pdf")
    .replace(/[\/\\:*?"<>|]+/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 140) || "deal-sheet.pdf";
}

function clairePdfPublicUrl(rel) {
  return "./source-docs/" + rel.split(path.sep).map(encodeURIComponent).join("/");
}

function clairePdfManifestPath(alias) {
  return path.join(CLAIRE_PDF_MANIFEST_ROOT, clairePdfSafeSlug(alias) + ".json");
}

function clairePdfReadJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (err) { return null; }
}

function clairePdfWriteJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
}

function clairePdfReadManifestByAlias(alias) {
  const direct = clairePdfManifestPath(alias);
  if (fs.existsSync(direct)) return clairePdfReadJson(direct);

  if (!fs.existsSync(CLAIRE_PDF_MANIFEST_ROOT)) return null;
  const q = String(alias || "").toLowerCase().trim();
  if (!q) return null;

  for (const name of fs.readdirSync(CLAIRE_PDF_MANIFEST_ROOT)) {
    if (!name.toLowerCase().endsWith(".json")) continue;
    const file = path.join(CLAIRE_PDF_MANIFEST_ROOT, name);
    const data = clairePdfReadJson(file);
    if (!data) continue;
    const hay = JSON.stringify({
      deal_id: data.deal_id,
      deal_public_id: data.deal_public_id,
      property_address: data.property_address,
      folder: data.folder,
      source_documents: data.source_documents
    }).toLowerCase();
    if (hay.includes(q) || q.includes(String(data.property_address || "").toLowerCase())) return data;
  }
  return null;
}

function clairePdfWriteManifestAliases(manifest, aliases) {
  const unique = Array.from(new Set((aliases || []).filter(Boolean).map(String)));
  if (!unique.length) unique.push(manifest.folder || manifest.property_address || "deal");
  for (const alias of unique) {
    clairePdfWriteJson(clairePdfManifestPath(alias), manifest);
  }
}

function clairePdfAddLine(doc, label, value) {
  if (value === undefined || value === null || String(value).trim() === "") return;
  doc.font("Helvetica-Bold").fontSize(9).text(label + ": ", { continued: true });
  doc.font("Helvetica").fontSize(9).text(String(value));
}

function clairePdfMoney(value) {
  return String(value || "").trim();
}

function clairePdfPartiesFromPayload(payload) {
  return [
    ["Seller", payload.seller_name],
    ["Purchaser", payload.purchaser_name],
    ["Seller Attorney", [payload.seller_attorney_name, payload.seller_attorney_email, payload.seller_attorney_phone].filter(Boolean).join(" | ")],
    ["Purchaser Attorney", [payload.purchaser_attorney_name, payload.purchaser_attorney_email, payload.purchaser_attorney_phone].filter(Boolean).join(" | ")],
    ["Listing Agent", [payload.seller_agent_name, payload.seller_agent_broker, payload.seller_agent_email, payload.seller_agent_phone].filter(Boolean).join(" | ")],
    ["Buyer Agent", [payload.purchaser_agent_name, payload.purchaser_agent_broker, payload.purchaser_agent_email, payload.purchaser_agent_phone].filter(Boolean).join(" | ")],
    ["Lender / Loan Officer", [payload.lender_company, payload.lender_name, payload.lender_email, payload.lender_phone].filter(Boolean).join(" | ")]
  ];
}

async function clairePdfGenerateDealSheet(filePath, body) {
  const payload = body.payload || {};
  const deal = body.deal || {};
  const claire = body.claire_result || {};
  const property = payload.property_address || deal.property_address || body.property_address || "Accepted Offer";

  await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: "LETTER", margin: 42, info: { Title: "Deal Sheet - " + property } });
    const stream = fs.createWriteStream(filePath);
    doc.pipe(stream);

    doc.font("Helvetica-Bold").fontSize(18).text("Deal Sheet", { align: "center" });
    doc.font("Helvetica").fontSize(10).text("Accepted Offer to Close", { align: "center" });
    doc.moveDown(1);

    doc.font("Helvetica-Bold").fontSize(13).text(property);
    doc.font("Helvetica").fontSize(9).fillColor("#555").text("Generated by CLAIRE Deal Desk intake on " + new Date().toLocaleString("en-US"));
    doc.fillColor("#000");
    doc.moveDown(0.8);

    doc.font("Helvetica-Bold").fontSize(11).text("Offer Review");
    doc.moveDown(0.25);
    clairePdfAddLine(doc, "MLS", payload.mls_number);
    clairePdfAddLine(doc, "Status", payload.transaction_status || deal.transaction_status || "Accepted Offer Intake Started");
    clairePdfAddLine(doc, "Purchase Price", clairePdfMoney(payload.purchase_price || payload.total_price));
    clairePdfAddLine(doc, "Seller Concession", payload.seller_concession);
    clairePdfAddLine(doc, "Deposit / Down Payment", payload.contract_deposit);
    clairePdfAddLine(doc, "Mortgage Amount", payload.mortgage_amount);
    clairePdfAddLine(doc, "Closing Date / Terms", payload.closing_date_text);
    doc.moveDown(0.8);

    doc.font("Helvetica-Bold").fontSize(11).text("Parties and Contacts");
    doc.moveDown(0.25);
    for (const [label, value] of clairePdfPartiesFromPayload(payload)) clairePdfAddLine(doc, label, value);
    doc.moveDown(0.8);

    doc.font("Helvetica-Bold").fontSize(11).text("CLAIRE Intake Note");
    doc.moveDown(0.25);
    const addTerms = payload.additional_terms || "";
    if (addTerms) doc.font("Helvetica").fontSize(9).text(addTerms, { width: 510 });
    else doc.font("Helvetica").fontSize(9).text("No short CLAIRE intake note supplied.");
    doc.moveDown(0.8);

    const f = claire.dealdesk_fields || {};
    const flags = []
      .concat(Array.isArray(f.review_flags) ? f.review_flags : [])
      .concat(Array.isArray(f.missing_items) ? f.missing_items : [])
      .slice(0, 10);

    doc.font("Helvetica-Bold").fontSize(11).text("Review Flags / Missing Items");
    doc.moveDown(0.25);
    if (flags.length) {
      for (const flag of flags) doc.font("Helvetica").fontSize(9).text("- " + flag, { width: 510 });
    } else {
      doc.font("Helvetica").fontSize(9).text("No major flags saved with intake.");
    }

    const docs = body.source_documents || [];
    doc.moveDown(0.8);
    doc.font("Helvetica-Bold").fontSize(11).text("Source Documents");
    doc.moveDown(0.25);
    if (docs.length) {
      for (const d of docs) doc.font("Helvetica").fontSize(9).text("- " + (d.filename || d.stored_filename || "Source document"));
    } else {
      doc.font("Helvetica").fontSize(9).text("Source documents are saved separately in the Deal Desk source-documents panel.");
    }

    doc.moveDown(1);
    doc.font("Helvetica-Oblique").fontSize(8).fillColor("#555")
      .text("Internal Deal Desk working document. Verify all terms against fully executed contract and attorney communications.", { align: "center" });

    doc.end();
    stream.on("finish", resolve);
    stream.on("error", reject);
  });
}

function clairePdfRebuildIndex() {
  const outFile = path.join(CLAIRE_PDF_SOURCE_ROOT, "source-documents-index.json");
  const docs = [];

  function encRel(rel) {
    return "./source-docs/" + rel.split(path.sep).map(encodeURIComponent).join("/");
  }

  function walk(dir) {
    if (!fs.existsSync(dir)) return;
    for (const name of fs.readdirSync(dir)) {
      const full = path.join(dir, name);
      const rel = path.relative(CLAIRE_PDF_SOURCE_ROOT, full);
      if (!rel || rel === "source-documents-index.json") continue;
      if (rel.startsWith("manifests" + path.sep)) continue;
      const st = fs.statSync(full);
      if (st.isDirectory()) walk(full);
      else {
        const ext = path.extname(name).toLowerCase();
        if (![".pdf", ".png", ".jpg", ".jpeg", ".webp", ".txt", ".doc", ".docx"].includes(ext)) continue;
        docs.push({
          filename: name,
          folder: rel.split(path.sep)[0] || "",
          relative_path: rel,
          url: encRel(rel),
          size_bytes: st.size,
          modified_at: st.mtime.toISOString()
        });
      }
    }
  }

  fs.mkdirSync(CLAIRE_PDF_SOURCE_ROOT, { recursive: true });
  walk(CLAIRE_PDF_SOURCE_ROOT);
  docs.sort((a, b) => a.relative_path.localeCompare(b.relative_path));
  clairePdfWriteJson(outFile, { ok: true, generated_at: new Date().toISOString(), source_documents: docs });
  return docs;
}

async function clairePdfSaveDealSheet(body) {
  const payload = body.payload || {};
  const deal = body.deal || {};
  const property = payload.property_address || deal.property_address || body.property_address || "accepted-offer";
  const dealId = String(body.deal_id || deal.id || deal.deal_id || "").trim();
  const publicId = String(body.deal_public_id || deal.public_id || "").trim();

  let existing = null;
  for (const alias of [publicId, dealId, property]) {
    if (!alias) continue;
    existing = clairePdfReadManifestByAlias(alias);
    if (existing) break;
  }

  const folder = (existing && existing.folder) || clairePdfSafeSlug(publicId || dealId || property);
  const folderPath = path.join(CLAIRE_PDF_SOURCE_ROOT, folder);
  fs.mkdirSync(folderPath, { recursive: true });

  const pdfFilename = "deal-sheet-" + clairePdfSafeSlug(property).slice(0, 70) + ".pdf";
  const stored = clairePdfSafeFile(pdfFilename);
  const outPath = path.join(folderPath, stored);

  await clairePdfGenerateDealSheet(outPath, body);

  const stat = fs.statSync(outPath);
  const rel = path.join(folder, stored);
  const pdfEntry = {
    number: 0,
    filename: stored,
    stored_filename: stored,
    url: clairePdfPublicUrl(rel),
    mime_type: "application/pdf",
    size_bytes: stat.size,
    category: "generated_deal_sheet",
    generated_at: new Date().toISOString()
  };

  const manifest = existing || {
    ok: true,
    created_at: new Date().toISOString(),
    deal_id: dealId,
    deal_public_id: publicId,
    property_address: property,
    folder,
    source_documents: []
  };

  manifest.ok = true;
  manifest.deal_id = manifest.deal_id || dealId;
  manifest.deal_public_id = manifest.deal_public_id || publicId;
  manifest.property_address = manifest.property_address || property;
  manifest.folder = manifest.folder || folder;
  manifest.updated_at = new Date().toISOString();
  manifest.deal_sheet_pdf = pdfEntry;
  manifest.claire_result = manifest.claire_result || body.claire_result || null;
  manifest.claire_raw_output = manifest.claire_raw_output || body.claire_raw_output || null;

  const docs = Array.isArray(manifest.source_documents) ? manifest.source_documents : [];
  const filtered = docs.filter(d => d.category !== "generated_deal_sheet" && d.stored_filename !== stored && d.filename !== stored);
  manifest.source_documents = [pdfEntry, ...filtered];

  clairePdfWriteManifestAliases(manifest, [dealId, publicId, property, folder]);
  clairePdfRebuildIndex();

  return { manifest, pdf: pdfEntry };
}


const DD_AUTO_DOC_ROOT = "/home/servicedepartmen/public_html/dealdesk/generated-docs";
const DD_AUTO_MANIFEST_ROOT = path.join(DD_AUTO_DOC_ROOT, "manifests");
try { fs.mkdirSync(DD_AUTO_DOC_ROOT, { recursive: true }); fs.mkdirSync(DD_AUTO_MANIFEST_ROOT, { recursive: true }); } catch (err) {}

function ddAutoReadBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk.toString("utf8");
      if (body.length > 5000000) {
        reject(new Error("Request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function ddAutoSlug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 90) || "deal";
}

function ddAutoPublicUrl(rel) {
  return "./generated-docs/" + rel.split(path.sep).map(encodeURIComponent).join("/");
}

function ddAutoManifestPath(alias) {
  return path.join(DD_AUTO_MANIFEST_ROOT, ddAutoSlug(alias) + ".json");
}

function ddAutoReadJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (err) { return null; }
}

function ddAutoWriteJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
}

function ddAutoFindManifest(aliases) {
  const clean = Array.from(new Set((aliases || [])
    .filter(Boolean)
    .map(v => String(v).trim())
    .filter(Boolean)));

  // Strict record binding:
  // Generated / Sent Documents must be found only by the exact deal record id
  // or an exact alias intentionally written for that same deal.
  // Do NOT scan all manifests by property text, because that cross-links
  // generated PDFs from older retry deals into newly-created deals.
  for (const alias of clean) {
    const direct = ddAutoManifestPath(alias);
    if (fs.existsSync(direct)) return ddAutoReadJson(direct);
  }

  return null;
}

function ddAutoWriteManifest(manifest, aliases) {
  const unique = Array.from(new Set((aliases || []).filter(Boolean).map(String)));
  if (!unique.length) unique.push(manifest.folder || manifest.property_address || "deal");
  for (const alias of unique) ddAutoWriteJson(ddAutoManifestPath(alias), manifest);
}

function ddAutoTransporter() {
  const host = process.env.DEALDESK_SMTP_HOST || process.env.SMTP_HOST || "";
  const user = process.env.DEALDESK_SMTP_USER || process.env.SMTP_USER || "";
  const pass = process.env.DEALDESK_SMTP_PASS || process.env.SMTP_PASS || "";
  const port = Number(process.env.DEALDESK_SMTP_PORT || process.env.SMTP_PORT || 587);
  const secure = String(process.env.DEALDESK_SMTP_SECURE || process.env.SMTP_SECURE || "").toLowerCase() === "true";

  if (host && user && pass) {
    return nodemailer.createTransport({ host, port, secure, auth: { user, pass } });
  }

  for (const p of [process.env.SENDMAIL_PATH, "/usr/sbin/sendmail", "/usr/lib/sendmail"].filter(Boolean)) {
    try {
      if (fs.existsSync(p)) {
        return nodemailer.createTransport({ sendmail: true, path: p, newline: "unix" });
      }
    } catch (err) {}
  }

  throw new Error("No email transport configured.");
}


async function ddAutoFetchRealDealRecord(dealPublicId) {
  const id = String(dealPublicId || "").trim();
  if (!id) return null;

  const port = Number(process.env.DEALDESK_PORT || 3017);
  const candidates = [
    "http://127.0.0.1:" + port + "/api/dealdesk/deals/" + encodeURIComponent(id),
    "http://127.0.0.1:" + port + "/api/deals/" + encodeURIComponent(id)
  ];

  let lastError = "";

  for (const url of candidates) {
    try {
      const response = await fetch(url, {
        headers: { "Accept": "application/json" }
      });

      const text = await response.text();
      let data = null;

      try {
        data = text ? JSON.parse(text) : {};
      } catch (err) {
        lastError = "Non-JSON from " + url + ": " + text.slice(0, 140);
        continue;
      }

      if (response.ok && data && data.ok && data.record && data.record.deal) {
        return data.record;
      }

      lastError = "Bad response from " + url + ": " + JSON.stringify(data).slice(0, 240);
    } catch (err) {
      lastError = String(err && err.message ? err.message : err);
    }
  }

  console.warn("Could not fetch real Deal Desk record for print PDF:", lastError);
  return null;
}

async function ddAutoRenderPrintPageToPdf(opts) {
  const dealPublicId = String(opts.deal_public_id || opts.deal_id || "").trim();
  const property = String(opts.property_address || "accepted-offer").trim();

  if (!dealPublicId) throw new Error("Missing deal public id for print.html.");

  const folder = ddAutoSlug(dealPublicId || property);
  const folderPath = path.join(DD_AUTO_DOC_ROOT, folder);
  fs.mkdirSync(folderPath, { recursive: true });

  const filename = "deal-sheet-" + ddAutoSlug(property).slice(0, 70) + ".pdf";
  const absolutePath = path.join(folderPath, filename);

  const printFilePath = "/home/servicedepartmen/public_html/dealdesk/print.html";
  if (!fs.existsSync(printFilePath)) {
    throw new Error("Local print.html was not found at " + printFilePath);
  }

  const printUrl = "file://" + printFilePath + "?id=" + encodeURIComponent(dealPublicId);

  const apiRecord = await ddAutoFetchRealDealRecord(dealPublicId);
  const deal = opts.deal || {};
  const payload = opts.payload || {};
  const sourceRecord = opts.record || {};

  // Use the exact full record returned by the main Deal Desk API whenever possible.
  // print.html expects record.deal, record.financials, and record.parties.
  const fallbackRecord = Object.assign({}, sourceRecord, {
    deal: Object.assign({}, sourceRecord.deal || {}, payload, deal, {
      id: deal.id || payload.id || dealPublicId,
      deal_id: deal.deal_id || payload.deal_id || dealPublicId,
      public_id: deal.public_id || payload.public_id || dealPublicId,
      property_address: property || deal.property_address || payload.property_address || ""
    }),
    financials: sourceRecord.financials || payload.financials || deal.financials || {},
    parties: sourceRecord.parties || payload.parties || deal.parties || []
  });

  const record = apiRecord || fallbackRecord;

  const browser = await puppeteer.launch({
    headless: true,
    args: [
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-dev-shm-usage",
      "--allow-file-access-from-files",
      "--disable-web-security"
    ]
  });

  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1100, height: 1400, deviceScaleFactor: 1 });

    await page.evaluateOnNewDocument((record, dealPublicId) => {
      window.__DEALDESK_PRINT_RECORD__ = record;
      window.__DEALDESK_PRINT_DEAL_ID__ = dealPublicId;
      try {
        localStorage.setItem("dealdesk_print_record_" + dealPublicId, JSON.stringify(record));
        sessionStorage.setItem("dealdesk_print_record_" + dealPublicId, JSON.stringify(record));
      } catch (err) {}
    }, record, dealPublicId);

    await page.goto(printUrl, { waitUntil: "networkidle0", timeout: 120000 });
    await page.emulateMediaType("print");

    await new Promise(resolve => setTimeout(resolve, 1500));

    const result = await page.evaluate(() => {
      const text = document.body ? document.body.innerText : "";
      const dealTitle = document.querySelector(".deal-title, h1") ? document.querySelector(".deal-title, h1").innerText : "";
      return {
        text,
        textLength: String(text || "").trim().length,
        dealTitle,
        hasMainSheet: !!document.querySelector("main.sheet, main.page"),
        hasProperty: /Property Address/i.test(text || "")
      };
    });

    if (/Could not load printable deal sheet|Could not load accepted offer file|Missing accepted offer file ID|unauthorized|login|invalid auth/i.test(result.text || "")) {
      throw new Error("Local print.html loaded, but it did not use the injected real Deal Desk API record.");
    }

    if (!result.hasMainSheet || !result.hasProperty || result.textLength < 250) {
      throw new Error("Local print.html rendered too little real deal content. Render check: " + JSON.stringify({
        textLength: result.textLength,
        dealTitle: result.dealTitle,
        hasMainSheet: result.hasMainSheet,
        hasProperty: result.hasProperty,
        usedApiRecord: !!apiRecord
      }));
    }

    await page.pdf({
      path: absolutePath,
      format: "Letter",
      printBackground: true,
      margin: { top: "0.25in", bottom: "0.25in", left: "0.25in", right: "0.25in" }
    });
  } finally {
    await browser.close();
  }

  const stat = fs.statSync(absolutePath);
  const rel = path.join(folder, filename);

  return {
    filename,
    stored_filename: filename,
    relative_path: rel,
    url: ddAutoPublicUrl(rel),
    absolute_path: absolutePath,
    mime_type: "application/pdf",
    size_bytes: stat.size,
    category: "generated_print_deal_sheet",
    print_url: printUrl,
    render_mode: "local_print_html_with_real_dealdesk_api_record",
    generated_at: new Date().toISOString()
  };
}

async function ddAutoSendDealSheetEmail(opts) {
  const transporter = ddAutoTransporter();
  const to = process.env.DEALSHEETS_TO || "dealsheets@servicedepartment.ai";
  const from = process.env.DEALSHEETS_FROM || "Deal Desk <dealsheets@servicedepartment.ai>";
  const subject = String(opts.property_address || "Deal Sheet").trim() || "Deal Sheet";

  const info = await transporter.sendMail({
    from,
    to,
    subject,
    text: [
      "Deal Sheet PDF generated by Deal Desk.",
      "",
      "Property: " + subject,
      "Generated: " + new Date().toLocaleString("en-US")
    ].join("\n"),
    attachments: [
      {
        filename: opts.pdf.filename,
        path: opts.pdf.absolute_path,
        contentType: "application/pdf"
      }
    ]
  });

  return {
    to,
    from,
    subject,
    message_id: info.messageId || "",
    response: info.response || "",
    sent_at: new Date().toISOString()
  };
}

async function ddAutoPrintSaveSend(body) {
  const deal = body.deal || {};
  const payload = body.payload || {};

  const property = body.property_address || payload.property_address || deal.property_address || "Accepted Offer";
  const dealPublicId = String(body.deal_public_id || deal.public_id || deal.id || deal.deal_id || "").trim();
  const dealId = String(body.deal_id || deal.id || deal.deal_id || "").trim();

  const pdf = await ddAutoRenderPrintPageToPdf({
    deal_public_id: dealPublicId,
    deal_id: dealId,
    property_address: property,
    deal,
    payload,
    record: Object.assign({}, payload, deal, {
      id: deal.id || payload.id || dealPublicId,
      deal_id: deal.deal_id || payload.deal_id || dealId || dealPublicId,
      public_id: deal.public_id || payload.public_id || dealPublicId,
      property_address: property
    })
  });

  const email = await ddAutoSendDealSheetEmail({
    property_address: property,
    pdf
  });

  const safePdf = Object.assign({}, pdf, { absolute_path: undefined });

  const manifest = ddAutoFindManifest([dealPublicId, dealId]) || {
    ok: true,
    created_at: new Date().toISOString(),
    deal_id: dealId,
    deal_public_id: dealPublicId,
    property_address: property,
    folder: ddAutoSlug(dealPublicId || dealId || property),
    documents: []
  };

  manifest.ok = true;
  manifest.updated_at = new Date().toISOString();
  manifest.deal_id = manifest.deal_id || dealId;
  manifest.deal_public_id = manifest.deal_public_id || dealPublicId;
  manifest.property_address = manifest.property_address || property;
  manifest.last_email = email;

  const docs = Array.isArray(manifest.documents) ? manifest.documents : [];
  const pdfFolder = String(pdf.relative_path || "").split(path.sep)[0] || "";
  const currentGeneratedPdf = Object.assign({}, safePdf, {
      email_status: "sent",
      email_sent_at: email.sent_at,
      email_to: email.to,
      email_subject: email.subject
    });

  // Strict record binding:
  // Keep non-generated docs, but never carry generated Deal Sheet PDFs
  // from a different deal folder into this record's manifest.
  const cleanedExistingDocs = docs.filter(d => {
    const rel = String((d && d.relative_path) || "");
    const fn = String((d && d.filename) || "");
    const cat = String((d && d.category) || "");
    const isPdf = rel.toLowerCase().endsWith(".pdf") || fn.toLowerCase().endsWith(".pdf");
    const isGeneratedDealSheet = cat === "generated_print_deal_sheet" || rel.toLowerCase().includes("deal-sheet") || fn.toLowerCase().includes("deal-sheet");
    if (!(isPdf && isGeneratedDealSheet)) return true;
    if (!pdfFolder) return false;
    return rel.startsWith(pdfFolder + path.sep) && rel !== pdf.relative_path;
  });

  manifest.documents = [
    currentGeneratedPdf,
    ...cleanedExistingDocs
  ];

  ddAutoWriteManifest(manifest, [dealPublicId, dealId, manifest.folder]);

  return { pdf: safePdf, email, manifest };
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
    const force = url.searchParams.get("force") === "1" || url.searchParams.get("refresh") === "1";
    const parsed = await fetchParsedEmail(uid);
    const key = cacheKeyForParsedEmail(uid, parsed);

    if (!force) {
      const cached = readCachedResult(key);
      if (cached) {
        cached.cached = true;
        cached.cache_key = key;
        sendJson(res, 200, cached);
        return;
      }
    }

    const modelResult = await askModelStructured(parsed);
    const payload = {
      ok: true,
      uid,
      cached: false,
      cache_key: key,
      source_email: {
        from: parsed.from?.text || "",
        to: parsed.to?.text || "",
        subject: parsed.subject || "",
        date: parsed.date ? new Date(parsed.date).toISOString() : "",
        attachments: attachmentSummary(parsed)
      },
      result: modelResult.structured,
      raw_output: modelResult.raw_output
    };

    writeCachedResult(key, payload);
    sendJson(res, 200, payload);
    return;
  }


  if (req.method === "GET" && url.pathname === "/api/claire-dealview/source-docs") {
    const alias =
      url.searchParams.get("deal_id") ||
      url.searchParams.get("deal_public_id") ||
      url.searchParams.get("public_id") ||
      url.searchParams.get("property") ||
      url.searchParams.get("q") ||
      "";

    const manifest = findSourceDocManifest(alias);

    sendJson(res, 200, manifest || {
      ok: true,
      source_documents: [],
      lookup: { alias, found: false },
      message: "No CLAIRE source-document manifest found for this deal identifier."
    });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/claire-dealview/save-source-docs") {
    const uid = url.searchParams.get("uid") || "";
    if (!uid) throw new Error("Missing uid.");
    const rawBody = await readBody(req);
    let body = {};
    try { body = rawBody ? JSON.parse(rawBody) : {}; } catch (err) { body = {}; }

    const parsed = await fetchParsedEmail(uid);
    const manifest = await saveSourceDocsForDeal(uid, parsed, body);

    const aliases = [
      manifest.deal_id,
      manifest.deal_public_id,
      manifest.property_address,
      manifest.folder
    ].filter(Boolean);

    const inspection_clear_report = { ok: true, skipped: true, reason: "Offer memo identifies inspection contingency only; not auto-cleared." };

sendJson(res, 200, { ok: true, manifest, inspection_clear_report });
    return;
  }



  if (req.method === "POST" && url.pathname === "/api/claire-dealview/clear-inspection") {
    sendJson(res, 200, {
      ok: true,
      skipped: true,
      reason: "Offer memo identifies home inspection as a contingency only. Inspection is not auto-cleared without completion, waiver, or resolution proof."
    });
    return;
  }


  if (req.method === "POST" && url.pathname === "/api/claire-dealview/generate-deal-sheet-pdf") {
    const raw = await clairePdfReadBody(req);
    let body = {};
    try { body = raw ? JSON.parse(raw) : {}; } catch (err) { throw new Error("Bad JSON body."); }

    const result = await clairePdfSaveDealSheet(body);
    sendJson(res, 200, { ok: true, pdf: result.pdf, manifest: result.manifest });
    return;
  }



    // DEALDESK_CLEARANCE_EMAIL_DIRECT_SEND_V1
    {
      const ddSendPathname = (() => {
        try { return new URL(req.url, 'http://127.0.0.1').pathname; }
        catch (err) { return ''; }
      })();

      if (req.method === 'POST' && ddSendPathname === '/api/claire-dealview/send-clearance-email') {
        const ddJson = (status, obj) => {
          res.writeHead(status, {
            'Content-Type': 'application/json; charset=utf-8',
            'Cache-Control': 'no-store',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, Authorization, Accept'
          });
          res.end(JSON.stringify(obj || {}, null, 2));
        };

        try {
          const chunks = [];
          for await (const chunk of req) chunks.push(chunk);
          const rawBody = Buffer.concat(chunks).toString('utf8');
          const body = rawBody ? JSON.parse(rawBody) : {};

          const toEmail = String(body.to_email || '').trim();
          const subject = String(body.subject || '').trim();
          const messageBody = String(body.body || '').trim();
          const fromEmail = 'teamscher@servicedepartment.ai';
          const fromName = 'Team Scher';

          if (!toEmail) return ddJson(400, { ok: false, error: 'Missing recipient email.' });
          if (!subject) return ddJson(400, { ok: false, error: 'Missing email subject.' });
          if (!messageBody) return ddJson(400, { ok: false, error: 'Missing email body.' });

          let nodemailer = null;
          try {
            nodemailer = require('nodemailer');
          } catch (err) {
            return ddJson(500, { ok: false, error: 'nodemailer is not available in the CLAIRE sidecar environment.' });
          }

          const pick = (...names) => {
            for (const name of names) {
              if (process.env[name]) return process.env[name];
            }
            return '';
          };

          const smtpHost = pick('DEALDESK_SMTP_HOST', 'SMTP_HOST', 'EMAIL_HOST', 'MAIL_HOST');
          const smtpPortRaw = pick('DEALDESK_SMTP_PORT', 'SMTP_PORT', 'EMAIL_PORT', 'MAIL_PORT');
          const smtpUser = pick('DEALDESK_SMTP_USER', 'SMTP_USER', 'EMAIL_USER', 'MAIL_USER');
          const smtpPass = pick('DEALDESK_SMTP_PASS', 'SMTP_PASS', 'EMAIL_PASS', 'MAIL_PASS');

          let transporter = null;
          let transportMode = '';

          if (smtpHost && smtpUser && smtpPass) {
            const smtpPort = Number(smtpPortRaw || 587);
            transporter = nodemailer.createTransport({
              host: smtpHost,
              port: smtpPort,
              secure: smtpPort === 465,
              auth: { user: smtpUser, pass: smtpPass }
            });
            transportMode = 'smtp';
          } else {
            transporter = nodemailer.createTransport({
              sendmail: true,
              newline: 'unix',
              path: '/usr/sbin/sendmail'
            });
            transportMode = 'sendmail';
          }

          const info = await transporter.sendMail({
            from: `${fromName} <${fromEmail}>`,
            to: toEmail,
            subject,
            text: messageBody,
            replyTo: fromEmail,
            headers: {
              'X-DealDesk-Clearance-Email': 'true',
              'X-DealDesk-Deal-Id': String(body.deal_id || ''),
              'X-DealDesk-Draft-Email-Id': String(body.email_id || '')
            }
          });

          return ddJson(200, {
            ok: true,
            sent: true,
            from_email: fromEmail,
            to_email: toEmail,
            subject,
            transport_mode: transportMode,
            message_id: info && info.messageId ? info.messageId : '',
            response: info && info.response ? info.response : ''
          });
        } catch (err) {
          return ddJson(500, { ok: false, error: err && err.message ? err.message : String(err) });
        }
      }
    }


  if (req.method === "POST" && url.pathname === "/api/claire-dealview/print-deal-sheet-send") {
    const raw = await ddAutoReadBody(req);
    let body = {};
    try { body = raw ? JSON.parse(raw) : {}; } catch (err) { throw new Error("Bad JSON body."); }

    const result = await ddAutoPrintSaveSend(body);
    sendJson(res, 200, { ok: true, pdf: result.pdf, email: result.email, manifest: result.manifest });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/claire-dealview/generated-docs") {
    const alias = url.searchParams.get("deal_id") || url.searchParams.get("deal_public_id") || url.searchParams.get("public_id") || url.searchParams.get("property") || url.searchParams.get("q") || "";
    const manifest = ddAutoFindManifest([alias]);
    sendJson(res, 200, manifest || { ok: true, documents: [], lookup: { alias, found: false } });
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
