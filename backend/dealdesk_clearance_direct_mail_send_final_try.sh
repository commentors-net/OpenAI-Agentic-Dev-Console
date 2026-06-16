#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
DETAIL="/home/servicedepartmen/public_html/dealdesk/detail.html"
SIDE="$BACKEND/claire_dealview_sidecar.js"
PM2_NAME="dealdesk-claire-dealview"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKEND/backups/clearance-direct-mail-send-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing direct clearance-email sender."
echo "Reason found: the draft button works, but the send route being called does not exist as a JSON route."
echo "Fix: send the displayed clearance draft through the CLAIRE sidecar itself and return JSON only."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

[ -f "$DETAIL" ] || { echo "Missing detail page: $DETAIL"; exit 1; }
[ -f "$SIDE" ] || { echo "Missing CLAIRE sidecar: $SIDE"; exit 1; }

cp -f "$DETAIL" "$BACKUP_DIR/detail.html.before-$STAMP.bak"
cp -f "$SIDE" "$BACKUP_DIR/claire_dealview_sidecar.js.before-$STAMP.bak"

python3 - <<'PY'
from pathlib import Path
import re
import sys

DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")
SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")

def find_function(src, name):
    starts = [src.find("function " + name), src.find("async function " + name)]
    starts = [s for s in starts if s >= 0]
    if not starts:
        raise RuntimeError("Could not find function " + name)
    start = min(starts)
    brace = src.find("{", start)
    if brace < 0:
        raise RuntimeError("Could not find opening brace for " + name)

    depth = 0
    i = brace
    in_str = None
    esc = False
    line_comment = False
    block_comment = False

    while i < len(src):
        ch = src[i]
        nxt = src[i + 1] if i + 1 < len(src) else ""

        if line_comment:
            if ch == "\n":
                line_comment = False
            i += 1
            continue

        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 2
                continue
            i += 1
            continue

        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == in_str:
                in_str = None
            i += 1
            continue

        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue

        if ch == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue

        if ch in ("'", '"', "`"):
            in_str = ch
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1

        i += 1

    raise RuntimeError("Could not find end of function " + name)

# Detail page: call ONLY the JSON sidecar route. No Apache fallback.
detail = DETAIL.read_text(encoding="utf-8", errors="replace")

new_send_fn = r'''async function sendClearanceDraftEmail(dealId, row, emailId, toEmail) {
    var subjectEl = row ? row.querySelector('.vc-draft-subject') : null;
    var bodyEl = row ? row.querySelector('.vc-draft-body') : null;

    var payload = {
      deal_id: dealId,
      email_id: emailId,
      to_email: toEmail || '',
      subject: subjectEl ? subjectEl.textContent : '',
      body: bodyEl ? bodyEl.textContent : '',
      sent_by: 'operator',
      from_email: 'teamscher@servicedepartment.ai',
      from_name: 'Team Scher'
    };

    var response = await fetch('./api/claire-dealview/send-clearance-email', {
      credentials: 'same-origin',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      },
      cache: 'no-store',
      body: JSON.stringify(payload)
    });

    var text = await response.text();
    var data = null;

    try {
      data = text ? JSON.parse(text) : {};
    } catch (jsonErr) {
      var clean = text.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
      throw new Error('Clearance send route returned non-JSON response. HTTP ' + response.status + '. ' + clean.slice(0, 220));
    }

    if (!response.ok || !data.ok) {
      throw new Error((data && data.error) || ('Send failed HTTP ' + response.status));
    }

    var proofNote = row.querySelector('.vc-sent-proof-note');
    if (proofNote && !String(proofNote.value || '').trim()) {
      proofNote.value = 'Sent from teamscher@servicedepartment.ai to ' + (toEmail || 'recipient') + ' through Deal Desk.';
    }

    var taskId = row.getAttribute('data-task');
    if (taskId) {
      try {
        await postClearanceProof(dealId, taskId, collectClearanceProofPayload(row, 'mark_sent'));
      } catch (proofErr) {
        showClearanceEmailStatus(row, 'Email sent, but sent-proof could not be recorded: ' + proofErr.message, 'warning');
        return data;
      }
    }

    showClearanceEmailStatus(row, 'Email sent from teamscher@servicedepartment.ai to ' + (toEmail || 'recipient') + '.', '');
    return data;
  }'''

try:
    s, e = find_function(detail, "sendClearanceDraftEmail")
    detail = detail[:s] + new_send_fn + detail[e:]
except Exception as exc:
    print("ERROR patching detail sendClearanceDraftEmail:", exc)
    sys.exit(1)

DETAIL.write_text(detail, encoding="utf-8")
print("Patched detail.html to call only sidecar JSON send route.")

# Sidecar: replace old proxy route with direct mail sender.
side = SIDE.read_text(encoding="utf-8", errors="replace")

new_route = r'''
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

'''

# Remove old proxy route if present.
marker_old = "    // DEALDESK_CLEARANCE_EMAIL_SEND_PROXY_V1"
marker_new = "    // DEALDESK_CLEARANCE_EMAIL_DIRECT_SEND_V1"

if marker_new in side:
    print("Direct send route already installed.")
else:
    start = side.find(marker_old)
    if start >= 0:
        # Remove through the next known CLAIRE route.
        next_patterns = [
            "/api/claire-dealview/print-deal-sheet-send",
            "/api/claire-dealview/generated-docs"
        ]
        candidates = []
        for pat in next_patterns:
            idx = side.find(pat, start + len(marker_old))
            if idx >= 0:
                line_start = side.rfind("\n", 0, idx)
                candidates.append(line_start if line_start >= 0 else idx)
        if not candidates:
            print("ERROR: Found old send proxy marker but could not find next route boundary.")
            sys.exit(1)
        end = min(candidates)
        side = side[:start] + new_route + side[end:]
    else:
        # Insert before existing print route.
        match = re.search(r"^[ \t]*if\s*\([^\n]*?/api/claire-dealview/print-deal-sheet-send[^\n]*?\)\s*\{", side, re.M)
        if not match:
            match = re.search(r"^[ \t]*if\s*\([^\n]*?/api/claire-dealview/generated-docs[^\n]*?\)\s*\{", side, re.M)
        if not match:
            print("ERROR: Could not find sidecar route insertion point.")
            sys.exit(1)
        side = side[:match.start()] + new_route + side[match.start():]

# Keep shebang first if present.
lines = side.splitlines()
shebang = ""
out = []
for line in lines:
    if line.strip() == "#!/usr/bin/env node":
        shebang = "#!/usr/bin/env node"
    else:
        out.append(line)
side = (shebang + "\n" if shebang else "") + "\n".join(out) + "\n"

SIDE.write_text(side, encoding="utf-8")
print("Patched sidecar with direct clearance mail sender.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK DETAIL"
grep -n "send-clearance-email\|sendClearanceDraftEmail\|api/emails.*send" "$DETAIL" | head -n 80 || true

echo ""
echo "CHECK SIDECAR"
grep -n "DEALDESK_CLEARANCE_EMAIL_DIRECT_SEND_V1\|send-clearance-email\|createTransport\|sendMail" "$SIDE" | head -n 120 || true

echo ""
echo "LOCAL JSON ROUTE TEST"
curl -s -i -X POST "http://127.0.0.1:3022/api/claire-dealview/send-clearance-email" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  --data '{"deal_id":"TEST","email_id":"TEST","to_email":"teamscher@servicedepartment.ai","subject":"Deal Desk clearance test","body":"This is a Deal Desk clearance email route test.","from_email":"teamscher@servicedepartment.ai"}' \
  | head -n 60

echo ""
echo "PM2"
pm2 status "$PM2_NAME"

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Done. Hard refresh the detail page. Generate one draft and click Send Email once."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
