path = "/home/servicedepartmen/dealdesk-backend/server.js"
with open(path, "r") as f:
    src = f.read()

changes = 0

# 1. Fix claireListDealDocuments
old1 = """  const [rows] = await pool.query(
    `SELECT
       public_id,
       original_filename,
       stored_filename,
       mime_type,
       document_type,
       source,
       created_at
     FROM dd_deal_documents
     WHERE deal_id = ?
     ORDER BY created_at DESC, id DESC`,
    [deal.id]
  );"""

new1 = """  const [rows] = await pool.query(
    `SELECT
       id,
       document_type,
       document_title,
       file_path,
       document_status,
       created_by,
       created_at
     FROM dd_deal_documents
     WHERE deal_id = ?
     ORDER BY created_at DESC, id DESC`,
    [deal.id]
  );"""

if old1 in src:
    src = src.replace(old1, new1, 1)
    changes += 1
    print("Fixed claireListDealDocuments SELECT.")
else:
    print("MISS: claireListDealDocuments SELECT not found.")

# 2. Fix claireGetDocumentForView
old2 = """async function claireGetDocumentForView(publicId) {
  const [[row]] = await pool.query(
    `SELECT *
     FROM dd_deal_documents
     WHERE public_id = ?
     LIMIT 1`,
    [publicId]
  );
  return row || null;
}"""

new2 = """async function claireGetDocumentForView(docId) {
  const [[row]] = await pool.query(
    `SELECT *
     FROM dd_deal_documents
     WHERE id = ?
     LIMIT 1`,
    [docId]
  );
  return row || null;
}"""

if old2 in src:
    src = src.replace(old2, new2, 1)
    changes += 1
    print("Fixed claireGetDocumentForView.")
else:
    print("MISS: claireGetDocumentForView not found.")

# 3. Fix createdDocuments.push to use real LAST_INSERT_ID
old3 = """      createdDocuments.push({
        public_id: docPublicId,
        original_filename: original,
        mime_type: cleanText(att.mime_type || ''),
        document_type: claireInferDocumentType(original, att.mime_type)
      });"""

new3 = """      const [docInsertResult] = await connection.query(`SELECT LAST_INSERT_ID() AS id`);
      const docId = docInsertResult[0] && docInsertResult[0].id;

      createdDocuments.push({
        id: docId,
        original_filename: original,
        mime_type: cleanText(att.mime_type || ''),
        document_type: claireInferDocumentType(original, att.mime_type)
      });"""

if old3 in src:
    src = src.replace(old3, new3, 1)
    changes += 1
    print("Fixed createdDocuments.push block.")
else:
    print("MISS: createdDocuments.push block not found.")

# 4. Fix claireDocumentViewMatch route (mime/name resolution)
old4 = """    const mime = doc.mime_type || 'application/octet-stream';
    const name = doc.original_filename || doc.stored_filename || 'document';"""

new4 = """    const mime = 'application/pdf';
    const name = doc.document_title || 'document';"""

if old4 in src:
    src = src.replace(old4, new4, 1)
    changes += 1
    print("Fixed claireDocumentViewMatch route.")
else:
    print("MISS: claireDocumentViewMatch route block not found (may already be fine or differently worded).")

with open(path, "w") as f:
    f.write(src)

print(f"Total changes applied: {changes}")
