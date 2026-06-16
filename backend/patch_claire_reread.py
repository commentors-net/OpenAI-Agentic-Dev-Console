import re

path = "/home/servicedepartmen/dealdesk-backend/server.js"
with open(path, "r") as f:
    src = f.read()

# ---- 1. Insert claireRereadIntakeDraftDocuments before the closing marker ----
marker1 = "  // END_CLAIRE_INTAKE_ATTACHMENT_VIEW_ROUTES_V1"
if "async function claireRereadIntakeDraftDocuments" in src:
    print("Helper already present, skipping helper insert.")
else:
    helper = '''
// CLAIRE_REREAD_INTAKE_DOCUMENTS_V1
async function claireRereadIntakeDraftDocuments(publicId) {
  const fs = require('fs');
  const pdfParse = require('pdf-parse');

  const [[draft]] = await pool.query(
    `SELECT * FROM dd_intake_drafts WHERE public_id = ? LIMIT 1`,
    [publicId]
  );
  if (!draft) return null;

  const [attachments] = await pool.query(
    `SELECT * FROM dd_inbound_email_attachments WHERE email_id = ? ORDER BY id`,
    [draft.inbound_email_id]
  );

  async function ensureText(att) {
    if (att.text_extract && att.text_extract.trim()) return att.text_extract;
    if (!att.file_path || !fs.existsSync(att.file_path)) return '';
    try {
      const buf = fs.readFileSync(att.file_path);
      if ((att.mime_type || '').includes('pdf') || /\\.pdf$/i.test(att.filename || '')) {
        const result = await pdfParse(buf);
        const text = claireDocShort(result.text || '');
        await pool.query(
          `UPDATE dd_inbound_email_attachments SET text_extract = ? WHERE id = ?`,
          [text, att.id]
        );
        return text;
      }
      return '';
    } catch (err) {
      return '[PDF text extraction failed: ' + err.message + ']';
    }
  }

  let memoText = '';
  let preapprovalText = '';

  for (const att of attachments) {
    const text = await ensureText(att);
    const name = String(att.filename || '').toLowerCase();
    const isMemo = /memorandum|offer.*purchase|purchase.*sell/i.test(name) ||
      /MEMORANDUM OF OFFER TO PURCHASE/i.test(text);
    const isPreapproval = /preapproval|pre-approval|pre approved/i.test(name) ||
      /pre-approved|loan estimate|guaranteed rate|gr affinity/i.test(text);

    if (isMemo && !memoText) {
      memoText = text;
    } else if (isPreapproval && !preapprovalText) {
      preapprovalText = text;
    } else if (!memoText) {
      memoText = text;
    }
  }

  const primaryText = memoText || preapprovalText || '';
  const parsed = claireDocParseAcceptedOfferText(primaryText);
  const extracted = parsed.extracted || {};

  // Merge preapproval-only loan/financing info if not already present.
  if (preapprovalText) {
    const preParsed = claireDocParseAcceptedOfferText(preapprovalText);
    const preExtracted = preParsed.extracted || {};
    for (const key of ['preapproval_amount', 'preapproval_offer_price', 'loan_amount', 'lender_name', 'loan_officer_name', 'loan_officer_email', 'loan_officer_phone']) {
      if (!extracted[key] && preExtracted[key]) extracted[key] = preExtracted[key];
    }
  }

  const missing = parsed.missing_fields || [];
  const confidence = parsed.confidence_score || 0;

  await pool.query(
    `UPDATE dd_intake_drafts
     SET extracted_json = ?,
         property_address = ?,
         confidence_score = ?,
         missing_fields_json = ?,
         updated_at = NOW()
     WHERE public_id = ?`,
    [
      JSON.stringify(extracted),
      extracted.property_address || draft.property_address || null,
      confidence,
      JSON.stringify(missing),
      publicId
    ]
  );

  return {
    public_id: publicId,
    property_address: extracted.property_address || draft.property_address || null,
    confidence_score: confidence,
    extracted_json: extracted,
    missing_fields_json: missing
  };
}
// END_CLAIRE_REREAD_INTAKE_DOCUMENTS_V1

'''
    src = src.replace(marker1, helper + marker1, 1)
    print("Inserted claireRereadIntakeDraftDocuments helper.")

# ---- 2. Insert routes after the restored handleRequest wrapper ----
marker2 = "// END_DEALDESK_RESTORED_HANDLE_REQUEST_WRAPPER_V1"
if "CLAIRE_REREAD_AND_ATTACHMENT_VIEW_ROUTES_V1" in src:
    print("Routes already present, skipping route insert.")
else:
    routes = '''
// CLAIRE_REREAD_AND_ATTACHMENT_VIEW_ROUTES_V1
  const claireIntakeAttachmentViewMatch =
    url.pathname.match(/^\\/api\\/intake-attachments\\/([^/]+)\\/view$/) ||
    url.pathname.match(/^\\/api\\/dealdesk\\/intake-attachments\\/([^/]+)\\/view$/) ||
    url.pathname.match(/^\\/api\\/email-intake\\/attachments\\/([^/]+)\\/view$/) ||
    url.pathname.match(/^\\/api\\/dealdesk\\/email-intake\\/attachments\\/([^/]+)\\/view$/);

  if (req.method === 'GET' && claireIntakeAttachmentViewMatch) {
    const fsv = require('fs');
    const att = await claireGetInboundAttachmentForView(claireIntakeAttachmentViewMatch[1]);
    if (!att || !att.file_path || !fsv.existsSync(att.file_path)) {
      sendJson(res, 404, { ok: false, error: 'Attachment not found' });
      return;
    }
    const mime = att.mime_type || 'application/octet-stream';
    const name = att.filename || 'document';
    res.writeHead(200, {
      'Content-Type': mime,
      'Content-Disposition': 'inline; filename="' + String(name).replace(/"/g, '') + '"',
      'Cache-Control': 'private, max-age=60'
    });
    fsv.createReadStream(att.file_path).pipe(res);
    return;
  }

  const claireRereadDocsMatch =
    url.pathname.match(/^\\/api\\/intake-drafts\\/([^/]+)\\/reread-documents$/) ||
    url.pathname.match(/^\\/api\\/dealdesk\\/intake-drafts\\/([^/]+)\\/reread-documents$/);

  if (req.method === 'POST' && claireRereadDocsMatch) {
    const result = await claireRereadIntakeDraftDocuments(claireRereadDocsMatch[1]);
    if (!result) {
      sendJson(res, 404, { ok: false, error: 'Intake draft not found' });
      return;
    }
    sendJson(res, 200, { ok: true, draft: result });
    return;
  }
// END_CLAIRE_REREAD_AND_ATTACHMENT_VIEW_ROUTES_V1
'''
    src = src.replace(marker2, marker2 + routes, 1)
    print("Inserted reread/view routes.")

with open(path, "w") as f:
    f.write(src)

print("Patch applied.")
