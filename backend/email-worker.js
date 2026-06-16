#!/usr/bin/env node
/*
Safe Deal Desk Email Worker for CLAIRE Intake Inbox.
Logs From / Subject / UID, avoids bad-email loops, and keeps PDF/DOCX/text extraction.
*/

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const http = require('http');

const CONFIG_PATH = path.join(__dirname, 'email-intake.config.json');

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) throw new Error('Missing config: ' + CONFIG_PATH);
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
}

function short(value, max = 220) {
  const v = String(value || '').replace(/\s+/g, ' ').trim();
  return v.length > max ? v.slice(0, max) + '...' : v;
}

function addressText(value) {
  if (!value) return '';
  if (typeof value === 'string') return value;
  if (value.text) return value.text;
  if (Array.isArray(value.value)) {
    return value.value.map(v => {
      if (v.name && v.address) return v.name + ' <' + v.address + '>';
      return v.name || v.address || '';
    }).filter(Boolean).join(', ');
  }
  return String(value);
}

function safeName(name) {
  return String(name || 'attachment').replace(/[^a-zA-Z0-9._-]+/g, '_').slice(0, 160);
}

function shouldSkipSubject(config, subject) {
  const rules = (config.processing && Array.isArray(config.processing.skip_subject_contains))
    ? config.processing.skip_subject_contains
    : [];
  const s = String(subject || '').toLowerCase();
  return rules.some(rule => rule && s.includes(String(rule).toLowerCase()));
}

async function markSeen(client, uid, reason) {
  try {
    await client.messageFlagsAdd(uid, ['\\Seen'], { uid: true });
    console.log('[CLAIRE] Marked email seen. UID:', uid, 'Reason:', reason || 'processed');
  } catch (err) {
    console.error('[CLAIRE] Could not mark email seen. UID:', uid, 'Error:', err.message);
  }
}

async function markFailedSeenIfConfigured(client, config, uid) {
  const shouldMark = !config.processing || config.processing.mark_failed_seen !== false;
  if (shouldMark) await markSeen(client, uid, 'failed/skipped to prevent loop');
}

async function extractAttachmentText(att) {
  const contentType = String(att.contentType || '').toLowerCase();
  const filename = String(att.filename || '').toLowerCase();

  try {
    if (contentType.startsWith('text/') || filename.endsWith('.txt') || filename.endsWith('.csv')) {
      return att.content.toString('utf8').slice(0, 500000);
    }

    if (contentType.includes('pdf') || filename.endsWith('.pdf')) {
      try {
        const pdfParse = require('pdf-parse');
        const result = await pdfParse(att.content);
        return String(result.text || '').slice(0, 750000);
      } catch (err) {
        return '[PDF text extraction failed: ' + err.message + ']';
      }
    }

    if (contentType.includes('wordprocessingml') || filename.endsWith('.docx')) {
      try {
        const mammoth = require('mammoth');
        const result = await mammoth.extractRawText({ buffer: att.content });
        return String(result.value || '').slice(0, 750000);
      } catch (err) {
        return '[DOCX text extraction failed: ' + err.message + ']';
      }
    }
  } catch (err) {
    return '[Attachment text extraction failed: ' + err.message + ']';
  }

  return '';
}

function postJson(url, payload, secret) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const body = JSON.stringify(payload);

    const req = http.request({
      hostname: u.hostname,
      port: u.port || 80,
      path: u.pathname + u.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Content-Length': Buffer.byteLength(body),
        'X-DealDesk-Intake-Secret': secret || ''
      }
    }, res => {
      let chunks = '';
      res.setEncoding('utf8');
      res.on('data', d => chunks += d);
      res.on('end', () => {
        let data = {};
        try {
          data = chunks ? JSON.parse(chunks) : {};
        } catch (err) {
          return reject(new Error('Import API returned non-JSON HTTP ' + res.statusCode + ': ' + chunks.replace(/<[^>]*>/g, ' ').slice(0, 220)));
        }

        if (res.statusCode < 200 || res.statusCode >= 300 || data.ok === false) {
          return reject(new Error(data.error || ('Import API failed HTTP ' + res.statusCode)));
        }

        resolve(data);
      });
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

async function runOnce() {
  const config = loadConfig();

  if (!config.enabled) {
    console.log('Email intake worker is installed but disabled. Set enabled=true in email-intake.config.json.');
    return;
  }

  let ImapFlow, simpleParser;
  try {
    ImapFlow = require('imapflow').ImapFlow;
    simpleParser = require('mailparser').simpleParser;
  } catch (err) {
    console.error('Missing dependencies. Run: npm install imapflow mailparser');
    throw err;
  }

  const storageRoot = config.storage_root || path.join(__dirname, 'storage', 'inbound-email');
  const attachmentRoot = path.join(storageRoot, 'attachments');
  fs.mkdirSync(attachmentRoot, { recursive: true });

  const mailboxName = (config.processing && config.processing.mailbox) || 'INBOX';
  const maxMessages = (config.processing && config.processing.max_messages_per_run) || 10;

  const client = new ImapFlow({
    host: config.mailbox.host,
    port: config.mailbox.port || 993,
    secure: config.mailbox.secure !== false,
    auth: {
      user: config.mailbox.user,
      pass: config.mailbox.pass
    }
  });

  console.log('[CLAIRE] Connecting to mailbox');
  console.log('  Host:', config.mailbox.host);
  console.log('  User:', config.mailbox.user);
  console.log('  Mailbox:', mailboxName);

  await client.connect();
  const lock = await client.getMailboxLock(mailboxName);

  let processed = 0;

  try {
    for await (const msg of client.fetch({ seen: false }, { uid: true, envelope: true, source: true })) {
      if (processed >= maxMessages) break;

      let parsed = null;
      let fromText = '';
      let subjectText = '';
      let messageIdText = String(msg.uid || '');

      try {
        parsed = await simpleParser(msg.source);

        fromText = addressText(parsed.from);
        subjectText = parsed.subject || '';
        messageIdText = parsed.messageId || String(msg.uid);

        console.log('[CLAIRE] Processing email');
        console.log('  UID:', msg.uid);
        console.log('  From:', short(fromText));
        console.log('  Subject:', short(subjectText));
        console.log('  Message-ID:', short(messageIdText));
        console.log('  Attachments:', (parsed.attachments || []).length);

        if (shouldSkipSubject(config, subjectText)) {
          console.log('[CLAIRE] Skipped by subject rule.');
          await markFailedSeenIfConfigured(client, config, msg.uid);
          processed++;
          continue;
        }

        const attachmentPayloads = [];

        for (const att of parsed.attachments || []) {
          const folder = path.join(attachmentRoot, new Date().toISOString().slice(0, 10));
          fs.mkdirSync(folder, { recursive: true });

          const filename = safeName(att.filename || ('attachment-' + crypto.randomUUID()));
          const outPath = path.join(folder, crypto.randomUUID() + '-' + filename);
          fs.writeFileSync(outPath, att.content);

          let textExtract = '';
          try {
            textExtract = await extractAttachmentText(att);
          } catch (err) {
            textExtract = '[Attachment text extraction failed: ' + err.message + ']';
            console.error('[CLAIRE] Attachment extraction failed');
            console.error('  UID:', msg.uid);
            console.error('  From:', short(fromText));
            console.error('  Subject:', short(subjectText));
            console.error('  Attachment:', att.filename || filename);
            console.error('  Error:', err.message);
          }

          attachmentPayloads.push({
            filename: att.filename || filename,
            mime_type: att.contentType || '',
            file_path: outPath,
            text_extract: textExtract
          });
        }

        const payload = {
          message_id: parsed.messageId || String(msg.uid),
          from_email: parsed.from && parsed.from.text || '',
          from_name: parsed.from && parsed.from.value && parsed.from.value[0] && parsed.from.value[0].name || '',
          to_email: parsed.to && parsed.to.text || '',
          subject: parsed.subject || '',
          received_at: parsed.date ? parsed.date.toISOString() : new Date().toISOString(),
          body_text: parsed.text || '',
          body_html: parsed.html || '',
          attachments: attachmentPayloads
        };

        const importUrl = String(config.api_base_url || 'http://127.0.0.1:3000').replace(/\/$/, '') + '/api/dealdesk/email-intake/import';
        const result = await postJson(importUrl, payload, config.api_secret);

        console.log('[CLAIRE] Imported email as intake draft:', result.draft && result.draft.public_id);
        console.log('  From:', short(fromText));
        console.log('  Subject:', short(subjectText));

        if (!config.processing || config.processing.mark_seen !== false) {
          await markSeen(client, msg.uid, 'imported');
        }

        processed++;
      } catch (err) {
        console.error('[CLAIRE BAD EMAIL]');
        console.error('  UID:', msg && msg.uid);
        console.error('  From:', short(fromText));
        console.error('  Subject:', short(subjectText));
        console.error('  Message-ID:', short(messageIdText));
        console.error('  Error:', err && err.stack || err.message || err);

        await markFailedSeenIfConfigured(client, config, msg.uid);
        processed++;
        continue;
      }
    }

    console.log('[CLAIRE] Email intake worker run complete. Processed:', processed);
  } finally {
    lock.release();
    await client.logout();
  }
}

if (require.main === module) {
  runOnce().catch(err => {
    console.error(err);
    process.exit(1);
  });
}
