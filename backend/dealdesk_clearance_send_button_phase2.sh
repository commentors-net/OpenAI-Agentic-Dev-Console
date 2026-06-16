#!/usr/bin/env bash
set -euo pipefail

DETAIL="/home/servicedepartmen/public_html/dealdesk/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/home/servicedepartmen/dealdesk-backend/backups/clearance-send-button-delegation-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing Phase 2 send-button fix:"
echo "- dynamically generated Send Email button now works"
echo "- no backend/server.js change"
echo "- errors stay inside the same clearance box"
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
import sys

DETAIL = Path("/home/servicedepartmen/public_html/dealdesk/detail.html")
html = DETAIL.read_text(encoding="utf-8", errors="replace")

marker = "// DEALDESK_CLEARANCE_SEND_DELEGATION_V1"
delegated = r'''    // DEALDESK_CLEARANCE_SEND_DELEGATION_V1
    // Send buttons are created after the draft returns, so direct listeners miss them.
    // Use one delegated listener on the Clearance Path section.
    if (!section.dataset.vcSendDraftEmailDelegated) {
      section.dataset.vcSendDraftEmailDelegated = '1';

      section.addEventListener('click', async function(event) {
        var button = event.target && event.target.closest ? event.target.closest('.vc-send-draft-email') : null;
        if (!button || !section.contains(button)) return;

        event.preventDefault();
        event.stopPropagation();

        var row = button.closest('.visual-clearance-row');
        var emailId = button.getAttribute('data-email-id') || '';
        var toEmail = button.getAttribute('data-to-email') || '';

        if (!row || !emailId) {
          showClearanceEmailStatus(row, 'Could not identify the saved draft email to send.', 'error');
          return;
        }

        var ok = confirm('Send this email now?\n\nFrom: teamscher@servicedepartment.ai\nTo: ' + (toEmail || 'recipient') + '\n\nThis will record sent proof on this clearance item.');
        if (!ok) return;

        button.disabled = true;
        button.textContent = 'Sending';
        showClearanceEmailStatus(row, 'Sending email from teamscher@servicedepartment.ai...', '');

        try {
          await sendClearanceDraftEmail(dealId, row, emailId, toEmail);
          button.textContent = 'Sent';
        } catch (err) {
          showClearanceEmailStatus(row, 'Could not send email: ' + err.message, 'error');
          button.disabled = false;
          button.textContent = 'Send Email';
        }
      });
    }'''

if marker in html:
    print("Send delegation patch already installed.")
else:
    start_anchor = "    section.querySelectorAll('.vc-send-draft-email').forEach(function(button) {"
    start = html.find(start_anchor)

    if start >= 0:
        end_anchor = "\n\n  }\n\n\n  function collectClearanceProofPayload"
        end = html.find(end_anchor, start)
        if end < 0:
            print("ERROR: Found old send block start, but not the expected end anchor.")
            sys.exit(1)
        html = html[:start] + delegated + html[end:]
    else:
        end_anchor = "\n\n  }\n\n\n  function collectClearanceProofPayload"
        end = html.find(end_anchor)
        if end < 0:
            print("ERROR: Could not find renderVisualClearancePath end anchor.")
            sys.exit(1)
        html = html[:end] + "\n\n" + delegated + html[end:]

DETAIL.write_text(html, encoding="utf-8")
print("Patched dynamic Send Email button delegation.")
PY

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK PATCH"
grep -n "DEALDESK_CLEARANCE_SEND_DELEGATION_V1\|vcSendDraftEmailDelegated\|sendClearanceDraftEmail" "$DETAIL" | head -n 80 || echo "NO SEND DELEGATION PATCH FOUND"

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Done. Hard refresh the detail page."
echo "Test Phase 2:"
echo "1. open the same clearance item"
echo "2. generate the draft again if needed"
echo "3. click Send Email"
echo "4. the result or error should appear inside that clearance box"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
