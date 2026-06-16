#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const ROOT = "/home/servicedepartmen/public_html/dealdesk/source-docs";
const OUT = path.join(ROOT, "source-documents-index.json");

function encPath(rel) {
  return "./source-docs/" + rel.split(path.sep).map(encodeURIComponent).join("/");
}

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const rel = path.relative(ROOT, full);
    if (!rel || rel === "source-documents-index.json") continue;
    if (rel.startsWith("manifests" + path.sep)) continue;
    const st = fs.statSync(full);
    if (st.isDirectory()) walk(full, out);
    else {
      const ext = path.extname(name).toLowerCase();
      if (![".pdf", ".png", ".jpg", ".jpeg", ".webp", ".txt", ".doc", ".docx"].includes(ext)) continue;
      out.push({
        filename: name,
        folder: rel.split(path.sep)[0] || "",
        relative_path: rel,
        url: encPath(rel),
        size_bytes: st.size,
        modified_at: st.mtime.toISOString()
      });
    }
  }
  return out;
}

fs.mkdirSync(ROOT, { recursive: true });
const source_documents = walk(ROOT).sort((a,b) => a.relative_path.localeCompare(b.relative_path));
fs.writeFileSync(OUT, JSON.stringify({
  ok: true,
  generated_at: new Date().toISOString(),
  source_documents
}, null, 2));
console.log(JSON.stringify({ ok: true, count: source_documents.length, index: OUT }, null, 2));
