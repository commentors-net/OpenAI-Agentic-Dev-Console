#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
DETAIL="/home/servicedepartmen/public_html/dealdesk/detail.html"
SIDE="$BACKEND/claire_dealview_sidecar.js"
PM2_NAME="dealdesk-claire-dealview"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKEND/backups/clearance-send-proxy-phase3-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing Phase 3 clearance email send proxy"
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
import re, sys

DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")
SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")

def find_function(src, name):
    starts = [src.find("function " + name), src.find("async function " + name)]
    starts = [s for s in starts if s >= 0]
    if not starts:
        raise RuntimeError("Could not find function " + name)
    start = min(starts)
    brace = src.find("{", start)
    depth = 0
    i = brace
    in_str = None
    esc = False
    line = False
    block = False
    while i < len(src):
        ch = src[i]
        nxt = src[i+1] if i+1 < len(src) else ""
        if line:
            if ch == "\n": line = False
            i += 1
            continue
        if block:
            if ch == "*" and nxt == "/":
                block = False
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if esc: esc = False
            elif ch == "\\": esc = True
            elif ch == in_str: in_str = None
            i += 1
            continue
        if ch == "/" and nxt == "/":
            line = True; i += 2; continue
        if ch == "/" and nxt == "*":
            block = True; i += 2; continue
        if ch in ("'", '"', "`"):
            in_str = ch; i += 1; continue
        if ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1
        i += 1
    raise RuntimeError("Could not find end of function " + name)

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
      from_name: 'Team Scher',
      requested_from_email: 'teamscher@servicedepartment.ai'
    };

    var urls = [
      './api/claire-dealview/send-clearance-email',
      './api/emails/' + encodeURIComponent(emailId) + '/send',
      './api/dealdesk/emails/' + encodeURIComponent(emailId) + '/send'
    ];

    var lastError = null;

    for (var i = 0; i < urls.length; i++) {
      try {
        var isSidecar = urls[i].indexOf('/send-clearance-email') !== -1;
        var response = await fetch(urls[i], {
          credentials: 'same-origin',
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
          },
          cache: 'no-store',
          body: JSON.stringify(isSidecar ? payload : {
            sent_by: 'operator',
            from_email: 'teamscher@servicedepartment.ai',
            from_name: 'Team Scher',
            requested_from_email: 'teamscher@servicedepartment.ai'
          })
        });

        var text = await response.text();
        var data = null;
        try {
          data = text ? JSON.parse(text) : {};
        } catch (jsonErr) {
          var clean = text.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
          throw new Error('Send route returned HTML instead of JSON. HTTP ' + response.status + '. ' + clean.slice(0, 180));
        }

        if (response.status === 404) {
          lastError = new Error((data && data.error) || 'Send route not found.');
          continue;
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
      } catch (err) {
        lastError = err;
      }
    }

    throw lastError || new Error('Could not send email.');
  }'''

try:
    s, e = find_function(detail, "sendClearanceDraftEmail")
    detail = detail[:s] + new_send_fn + detail[e:]
except Exception as exc:
    print("ERROR patching detail sendClearanceDraftEmail:", exc)
    sys.exit(1)

DETAIL.write_text(detail, encoding="utf-8")
print("Patched detail.html sendClearanceDraftEmail.")

side = SIDE.read_text(encoding="utf-8", errors="replace")
route_marker = "DEALDESK_CLEARANCE_EMAIL_SEND_PROXY_V1"
route_block = r'''
    // DEALDESK_CLEARANCE_EMAIL_SEND_PROXY_V1
    if (req.method === 'POST' && pathname === '/api/claire-dealview/send-clearance-email') {
      const ddClearanceEmailJson = (status, obj) => {
        res.writeHead(status, {
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': 'no-store'
        });
        res.end(JSON.stringify(obj || {}));
      };

      try {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const rawBody = Buffer.concat(chunks).toString('utf8');
        const body = rawBody ? JSON.parse(rawBody) : {};

        const emailId = String(body.email_id || body.email_public_id || body.public_id || '').trim();
        if (!emailId) {
          return ddClearanceEmailJson(400, { ok: false, error: 'Missing saved draft email id.' });
        }

        const backendPort = String(process.env.DEALDESK_PORT || '3017');
        const upstreamUrls = [
          `http://127.0.0.1:${backendPort}/api/emails/${encodeURIComponent(emailId)}/send`,
          `http://127.0.0.1:${backendPort}/api/dealdesk/emails/${encodeURIComponent(emailId)}/send`
        ];

        let lastStatus = 404;
        let lastData = { ok: false, error: 'Main backend send route not found.' };

        for (const upstreamUrl of upstreamUrls) {
          const upstream = await fetch(upstreamUrl, {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json'
            },
            body: JSON.stringify({
              sent_by: body.sent_by || 'operator',
              from_email: body.from_email || 'teamscher@servicedepartment.ai',
              from_name: body.from_name || 'Team Scher',
              requested_from_email: body.requested_from_email || body.from_email || 'teamscher@servicedepartment.ai'
            })
          });

          const text = await upstream.text();
          let data = null;
          try {
            data = text ? JSON.parse(text) : {};
          } catch (err) {
            data = {
              ok: false,
              error: 'Local backend send route returned non-JSON response. HTTP ' + upstream.status + '. ' + text.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 220)
            };
          }

          lastStatus = upstream.status;
          lastData = data;

          if (upstream.status !== 404) {
            return ddClearanceEmailJson(upstream.status, data);
          }
        }

        return ddClearanceEmailJson(lastStatus, lastData);
      } catch (err) {
        return ddClearanceEmailJson(500, { ok: false, error: err && err.message ? err.message : String(err) });
      }
    }

'''

if route_marker not in side:
    match = re.search(r"^[ \t]*if\s*\([^\n]*?/api/claire-dealview/print-deal-sheet-send[^\n]*?\)\s*\{", side, re.M)
    if not match:
        match = re.search(r"^[ \t]*if\s*\([^\n]*?/api/claire-dealview/generated-docs[^\n]*?\)\s*\{", side, re.M)
    if not match:
        print("ERROR: Could not find CLAIRE sidecar route insertion point.")
        sys.exit(1)
    side = side[:match.start()] + route_block + side[match.start():]
else:
    print("Sidecar send proxy route already installed.")

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
print("Patched CLAIRE sidecar with send-clearance-email proxy route.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK DETAIL PATCH"
grep -n "send-clearance-email\|sendClearanceDraftEmail\|teamscher@servicedepartment.ai" "$DETAIL" | head -n 80 || echo "NO DETAIL SEND PATCH FOUND"

echo ""
echo "CHECK SIDECAR PATCH"
grep -n "DEALDESK_CLEARANCE_EMAIL_SEND_PROXY_V1\|send-clearance-email\|api/emails.*send" "$SIDE" | head -n 80 || echo "NO SIDECAR SEND PATCH FOUND"

echo ""
echo "PM2"
pm2 status "$PM2_NAME"

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Done. Hard refresh the detail page."
echo "Test Send Email again from the same clearance box."
echo "If it still errors, paste the exact in-box error."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
