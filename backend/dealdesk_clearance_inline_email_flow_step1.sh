#!/usr/bin/env bash
set -euo pipefail

DETAIL="/home/servicedepartmen/public_html/dealdesk/detail.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/home/servicedepartmen/dealdesk-backend/backups/clearance-inline-email-flow-$STAMP"

mkdir -p "$BACKUP_DIR"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Installing step 1 clearance-box email flow:"
echo "- draft displays inside the clearance item"
echo "- send button displays inside the same clearance item"
echo "- errors display inside the same clearance item"
echo "- send request passes from_email=teamscher@servicedepartment.ai"
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

css_marker = "/* DEALDESK_CLEARANCE_INLINE_EMAIL_FLOW_V1 */"
css_add = r'''
  /* DEALDESK_CLEARANCE_INLINE_EMAIL_FLOW_V1 */
  .vc-email-status {
    grid-column: 1 / -1;
    display: none;
    border: 1px solid #99f6e4;
    background: #f0fdfa;
    color: #115e59;
    border-radius: 12px;
    padding: 9px 10px;
    font-size: 12px;
    font-weight: 800;
    line-height: 1.35;
  }
  .vc-email-status.active {
    display: block;
  }
  .vc-email-status.error {
    display: block;
    border-color: #fecaca;
    background: #fef2f2;
    color: #991b1b;
  }
  .vc-email-status.warning {
    display: block;
    border-color: #fde68a;
    background: #fffbeb;
    color: #92400e;
  }
  .vc-send-draft-email {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: #111827;
    color: #ffffff;
    border: 0;
    border-radius: 10px;
    padding: 10px 13px;
    font-weight: 900;
    cursor: pointer;
    margin-top: 8px;
  }
  .vc-send-draft-email:disabled {
    opacity: .65;
    cursor: not-allowed;
  }
  .vc-draft-actions {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    margin-top: 8px;
  }
  .vc-draft-from {
    color: #0f766e;
    font-weight: 900;
  }
'''
if css_marker not in html:
    style_id = '<style id="visual-clearance-path-style">'
    style_start = html.find(style_id)
    if style_start < 0:
        print("ERROR: Could not find visual-clearance-path-style block.")
        sys.exit(1)
    style_end = html.find("</style>", style_start)
    if style_end < 0:
        print("ERROR: Could not find end of visual-clearance-path-style block.")
        sys.exit(1)
    html = html[:style_end] + css_add + "\n" + html[style_end:]

def find_function(src, name):
    for marker in (f"function {name}", f"async function {name}"):
        start = src.find(marker)
        if start >= 0:
            break
    else:
        raise RuntimeError(f"Could not find function {name}")

    brace = src.find("{", start)
    if brace < 0:
        raise RuntimeError(f"Could not find opening brace for {name}")

    depth = 0
    i = brace
    in_str = None
    esc = False
    in_line_comment = False
    in_block_comment = False

    while i < len(src):
        ch = src[i]
        nxt = src[i+1] if i + 1 < len(src) else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue

        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
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
            in_line_comment = True
            i += 2
            continue

        if ch == "/" and nxt == "*":
            in_block_comment = True
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

    raise RuntimeError(f"Could not find function end for {name}")

new_render_preview = r'''function renderClearanceDraftPreview(draft) {
    if (!draft) return '';

    var emailId = draft.public_id || draft.email_public_id || draft.email_id || draft.id || '';
    var toLine = [draft.to_name, draft.to_email].filter(Boolean).join(' <');
    if (draft.to_name && draft.to_email) toLine += '>';

    var fromLine = draft.from_email || 'teamscher@servicedepartment.ai';

    return [
      '<div class="vc-draft-card" data-draft-email-id="' + escapeHtml(emailId) + '">',
        '<div class="vc-draft-label">Draft Email Saved In This Clearance Item</div>',
        '<div class="vc-draft-subject">' + escapeHtml(draft.subject || 'Draft email') + '</div>',
        '<div class="vc-draft-meta">',
          'To: ' + escapeHtml(toLine || draft.to_email || ''),
          (draft.cc_email ? ' | CC: ' + escapeHtml(draft.cc_email) : ''),
          ' | <span class="vc-draft-from">From: ' + escapeHtml(fromLine) + '</span>',
        '</div>',
        '<div class="vc-draft-body">' + escapeHtml(draft.body || '') + '</div>',
        '<div class="vc-draft-actions">',
          emailId ? '<button type="button" class="vc-send-draft-email" data-email-id="' + escapeHtml(emailId) + '" data-to-email="' + escapeHtml(draft.to_email || '') + '">Send Email</button>' : '<div class="vc-email-status warning active">Draft displayed, but no saved email ID came back from the server. The draft can be reviewed, but Send cannot run until the draft route returns an email ID.</div>',
        '</div>',
      '</div>'
    ].join('');
  }'''

try:
    s, e = find_function(html, "renderClearanceDraftPreview")
    html = html[:s] + new_render_preview + html[e:]
except Exception as exc:
    print("ERROR replacing renderClearanceDraftPreview:", exc)
    sys.exit(1)

old_dupe = '''            '<button type="button" class="vc-email">Generate Draft Email</button>',
            '<div class="visual-clearance-draft-preview">' + renderClearanceDraftPreview(item.draft_email) + '</div>',
            '<div class="visual-clearance-draft-preview">' + renderClearanceDraftPreview(item.draft_email) + '</div>','''
new_single = '''            '<button type="button" class="vc-email">Generate Draft Email</button>',
            '<div class="vc-email-status" aria-live="polite"></div>',
            '<div class="visual-clearance-draft-preview">' + renderClearanceDraftPreview(item.draft_email) + '</div>','''

if old_dupe in html:
    html = html.replace(old_dupe, new_single, 1)
else:
    old_single = '''            '<button type="button" class="vc-email">Generate Draft Email</button>',
            '<div class="visual-clearance-draft-preview">' + renderClearanceDraftPreview(item.draft_email) + '</div>','''
    if old_single in html:
        html = html.replace(old_single, new_single, 1)
    else:
        print("WARNING: Could not find exact draft-preview markup to dedupe/add status.")

helper_marker = "function showClearanceEmailStatus(row, message, kind)"
helper_code = r'''
  function showClearanceEmailStatus(row, message, kind) {
    if (!row) return;
    var box = row.querySelector('.vc-email-status');
    if (!box) return;
    box.className = 'vc-email-status active' + (kind ? ' ' + kind : '');
    box.textContent = message || '';
  }

  function clearClearanceEmailStatus(row) {
    if (!row) return;
    var box = row.querySelector('.vc-email-status');
    if (!box) return;
    box.className = 'vc-email-status';
    box.textContent = '';
  }

  async function sendClearanceDraftEmail(dealId, row, emailId, toEmail) {
    var urls = [
      './api/emails/' + encodeURIComponent(emailId) + '/send',
      './api/dealdesk/emails/' + encodeURIComponent(emailId) + '/send'
    ];

    var lastError = null;

    for (var i = 0; i < urls.length; i++) {
      try {
        var response = await fetch(urls[i], {
          credentials: 'same-origin',
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
          },
          cache: 'no-store',
          body: JSON.stringify({
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
  }

'''
if helper_marker not in html:
    anchor = "  function renderVisualClearancePath(section, dealId, items) {"
    idx = html.find(anchor)
    if idx < 0:
        print("ERROR: Could not find renderVisualClearancePath anchor for helper insertion.")
        sys.exit(1)
    html = html[:idx] + helper_code + "\n" + html[idx:]

start_anchor = "    section.querySelectorAll('.vc-email').forEach(function(button) {"
start = html.find(start_anchor)
if start < 0:
    print("ERROR: Could not find .vc-email handler start.")
    sys.exit(1)

next_anchor = "\n\n  }\n\n\n  function collectClearanceProofPayload"
end = html.find(next_anchor, start)
if end < 0:
    print("ERROR: Could not find .vc-email handler end.")
    sys.exit(1)

new_email_handler = r'''    section.querySelectorAll('.vc-email').forEach(function(button) {
      button.addEventListener('click', async function() {
        var row = button.closest('.visual-clearance-row');
        var taskId = row ? row.getAttribute('data-task') : '';

        if (!taskId) {
          showClearanceEmailStatus(row, 'Could not identify this clearance item.', 'error');
          return;
        }

        clearClearanceEmailStatus(row);

        var nameInput = row.querySelector('.vc-contact-name');
        var emailInput = row.querySelector('.vc-contact-email');
        var phoneInput = row.querySelector('.vc-contact-phone');

        var name = nameInput ? String(nameInput.value || '').trim() : '';
        var email = emailInput ? String(emailInput.value || '').trim() : '';
        var phone = phoneInput ? String(phoneInput.value || '').trim() : '';

        if (!email) {
          showClearanceEmailStatus(row, 'Enter the recipient email in this clearance box, then click Generate Draft Email again.', 'error');
          if (emailInput) emailInput.focus();
          return;
        }

        button.disabled = true;
        button.textContent = 'Generating';
        showClearanceEmailStatus(row, 'Generating draft inside this clearance item...', '');

        try {
          await fetch('./api/deals/' + encodeURIComponent(dealId) + '/clearance-controls/' + encodeURIComponent(taskId), {
            credentials: 'same-origin',
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json'
            },
            cache: 'no-store',
            body: JSON.stringify({
              control_state: row.querySelector('.vc-state') ? row.querySelector('.vc-state').value : 'open',
              clearance_source: row.querySelector('.vc-source') ? row.querySelector('.vc-source').value : 'operator_entered',
              clearance_evidence: row.querySelector('.vc-note') ? row.querySelector('.vc-note').value : '',
              office_contact_name: name,
              office_contact_email: email,
              office_contact_phone: phone,
              waiting_on_name: name,
              updated_by: 'operator'
            })
          });

          var draftUrls = [
            './api/deals/' + encodeURIComponent(dealId) + '/clearance-draft-email',
            './api/dealdesk/deals/' + encodeURIComponent(dealId) + '/clearance-draft-email',
            './api/deals/' + encodeURIComponent(dealId) + '/clearance-controls/' + encodeURIComponent(taskId) + '/draft-email',
            './api/dealdesk/deals/' + encodeURIComponent(dealId) + '/clearance-controls/' + encodeURIComponent(taskId) + '/draft-email'
          ];

          var response = null;
          var rawText = '';

          for (var draftUrlIndex = 0; draftUrlIndex < draftUrls.length; draftUrlIndex++) {
            response = await fetch(draftUrls[draftUrlIndex], {
              credentials: 'same-origin',
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json'
              },
              cache: 'no-store',
              body: JSON.stringify({
                task_public_id: taskId,
                to_email: email,
                to_name: name,
                office_contact_phone: phone,
                from_email: 'teamscher@servicedepartment.ai',
                from_name: 'Team Scher',
                created_by: 'operator'
              })
            });

            rawText = await response.text();
            if (response.status !== 404) {
              break;
            }
          }

          var data = null;
          try {
            data = rawText ? JSON.parse(rawText) : {};
          } catch (jsonError) {
            var cleanText = rawText.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
            throw new Error('Draft Email returned HTML instead of JSON. HTTP ' + (response ? response.status : '') + '. ' + cleanText.slice(0, 180));
          }

          if (!response.ok || !data.ok) {
            throw new Error((data && data.error) || 'Could not create draft email.');
          }

          var draft = data.draft || data.email || data.email_message || data.message || null;
          if (draft && !draft.from_email) draft.from_email = 'teamscher@servicedepartment.ai';

          var preview = row.querySelector('.visual-clearance-draft-preview');
          if (preview) {
            preview.innerHTML = renderClearanceDraftPreview(draft);
          }

          showClearanceEmailStatus(row, 'Draft generated. Review it inside this clearance item, then click Send Email.', '');

          button.disabled = false;
          button.textContent = 'Generate Draft Email';
        } catch (err) {
          showClearanceEmailStatus(row, 'Could not create draft email: ' + err.message, 'error');
          button.disabled = false;
          button.textContent = 'Generate Draft Email';
        }
      });
    });

    section.querySelectorAll('.vc-send-draft-email').forEach(function(button) {
      button.addEventListener('click', async function() {
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
    });
'''

html = html[:start] + new_email_handler + html[end:]

DETAIL.write_text(html, encoding="utf-8")
print("Patched clearance inline email flow.")
PY

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"

echo "CHECK PATCH"
grep -n "DEALDESK_CLEARANCE_INLINE_EMAIL_FLOW_V1\|showClearanceEmailStatus\|sendClearanceDraftEmail\|vc-send-draft-email\|teamscher@servicedepartment.ai" "$DETAIL" | head -n 120 || echo "NO INLINE EMAIL PATCH FOUND"

echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"

echo ""
echo "Done. Hard refresh the detail page."
echo "Test one clearance item only:"
echo "1. open Clearance Path"
echo "2. enter recipient email teamscher@servicedepartment.ai"
echo "3. click Generate Draft Email"
echo "4. review draft inside that clearance item"
echo "5. click Send Email if it looks right"
echo "6. any error should show inside that same clearance item"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
