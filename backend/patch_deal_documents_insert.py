path = "/home/servicedepartmen/dealdesk-backend/server.js"
with open(path, "r") as f:
    src = f.read()

old = """      const docPublicId = crypto.randomUUID();
      await connection.query(
        `INSERT INTO dd_deal_documents
         (public_id, deal_id, inbound_email_id, intake_draft_id, original_filename, stored_filename, mime_type, file_path, document_type, source, uploaded_by)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          docPublicId,
          dealId,
          draft.inbound_email_id || null,
          draft.id || null,
          original,
          stored,
          cleanText(att.mime_type || '') || 'application/octet-stream',
          targetPath,
          claireInferDocumentType(original, att.mime_type),
          'Email Intake',
          cleanText(operator || 'CLAIRE')
        ]
      );"""

new = """      const docPublicId = crypto.randomUUID();
      await connection.query(
        `INSERT INTO dd_deal_documents
         (deal_id, document_type, document_title, file_path, document_status, created_by)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [
          dealId,
          claireInferDocumentType(original, att.mime_type),
          original,
          targetPath,
          'Created',
          cleanText(operator || 'CLAIRE')
        ]
      );"""

if old not in src:
    raise SystemExit("Old INSERT block not found verbatim, aborting.")

src = src.replace(old, new, 1)

with open(path, "w") as f:
    f.write(src)

print("Patched dd_deal_documents INSERT to match real schema.")
