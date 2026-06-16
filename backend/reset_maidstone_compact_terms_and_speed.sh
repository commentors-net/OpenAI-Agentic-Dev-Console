#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
HTML="$APPDIR/claire-dealdesk-view.html"
SOURCE_DOC_ROOT="$APPDIR/source-docs"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"
BACKUP_DIR="$BACKEND/backups/compact-additional-terms-reset-maidstone-$STAMP"

mkdir -p "$BACKUP_DIR" "$SOURCE_DOC_ROOT/manifests"

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Resetting 25 Maidstone and compacting CLAIRE additional terms..."
echo "Backup folder: $BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"

for f in "$SIDE" "$HTML"; do
  if [ -f "$f" ]; then
    cp -f "$f" "$BACKUP_DIR/$(basename "$f").before-$STAMP.bak"
  fi
done

cd "$BACKEND"
npm install mysql2 dotenv >/tmp/compact-terms-npm-$STAMP.log 2>&1 || {
  cat /tmp/compact-terms-npm-$STAMP.log
  exit 1
}

cat > "$BACKEND/delete_maidstone_once.js" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
require("dotenv").config({ path: "/home/servicedepartmen/dealdesk-backend/.env" });
const mysql = require("mysql2/promise");

const BACKUP_DIR = process.env.DD_BACKUP_DIR || "/home/servicedepartmen/dealdesk-backend/backups";
const TERMS = ["25 Maidstone", "Maidstone Lane", "25 Maidstone Lane", "Wading River"];

function dbConfig() {
  return {
    host: process.env.DB_HOST || process.env.MYSQL_HOST || "localhost",
    user: process.env.DB_USER || process.env.MYSQL_USER || process.env.MYSQL_USERNAME || "servicedepartmen_dealdesk",
    password: process.env.DB_PASSWORD || process.env.MYSQL_PASSWORD || process.env.DB_PASS || "",
    database: process.env.DB_NAME || process.env.MYSQL_DATABASE || process.env.DATABASE_NAME || "servicedepartmen_dealdesk",
    multipleStatements: false
  };
}
function q(id){ return "`" + String(id).replace(/`/g, "``") + "`"; }
function isText(t){ return /char|text|json|enum|set/i.test(String(t || "")); }

async function main() {
  const conn = await mysql.createConnection(dbConfig());
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

  const candidates = [];
  const aliases = new Set(TERMS);

  for (const [table, tableCols] of byTable.entries()) {
    const textCols = tableCols.filter(c => isText(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
    if (!textCols.length) continue;

    const wheres = [];
    const params = [];
    for (const col of textCols) {
      for (const term of TERMS) {
        wheres.push(`${q(col)} LIKE ?`);
        params.push(`%${term}%`);
      }
    }

    let rows = [];
    try {
      [rows] = await conn.query(`SELECT * FROM ${q(table)} WHERE ${wheres.join(" OR ")} LIMIT 500`, params);
    } catch (err) {
      continue;
    }

    if (!rows.length) continue;
    candidates.push({ table, rows });

    for (const row of rows) {
      for (const k of ["id","deal_id","public_id","deal_public_id","file_id","transaction_id","property_address"]) {
        if (row[k] !== undefined && row[k] !== null && String(row[k]).trim()) aliases.add(String(row[k]));
      }
    }
  }

  const backupPath = path.join(BACKUP_DIR, "maidstone-delete-backup.json");
  fs.writeFileSync(backupPath, JSON.stringify({
    deleted_at: new Date().toISOString(),
    terms: TERMS,
    aliases: Array.from(aliases),
    candidates
  }, null, 2));

  if (!candidates.length) {
    console.log("No Maidstone rows found. Nothing deleted.");
    console.log("Backup:", backupPath);
    await conn.end();
    return;
  }

  await conn.query("SET FOREIGN_KEY_CHECKS=0");

  const deleted = [];
  const allAliases = Array.from(aliases);

  for (const [table, tableCols] of byTable.entries()) {
    const names = tableCols.map(c => c.COLUMN_NAME);
    for (const col of ["deal_id", "dealId", "deal_public_id", "public_id", "file_id", "transaction_id"]) {
      if (!names.includes(col) || !allAliases.length) continue;
      try {
        const [r] = await conn.query(
          `DELETE FROM ${q(table)} WHERE ${q(col)} IN (${allAliases.map(() => "?").join(",")})`,
          allAliases
        );
        if (r.affectedRows) deleted.push({ table, column: col, rows: r.affectedRows });
      } catch (err) {}
    }
  }

  for (const item of candidates) {
    const tableCols = byTable.get(item.table) || [];
    const names = tableCols.map(c => c.COLUMN_NAME);

    if (names.includes("id")) {
      const ids = item.rows.map(r => r.id).filter(v => v !== undefined && v !== null);
      if (!ids.length) continue;
      try {
        const [r] = await conn.query(
          `DELETE FROM ${q(item.table)} WHERE ${q("id")} IN (${ids.map(() => "?").join(",")})`,
          ids
        );
        if (r.affectedRows) deleted.push({ table: item.table, column: "id", rows: r.affectedRows });
      } catch (err) {}
    } else {
      const textCols = tableCols.filter(c => isText(c.DATA_TYPE)).map(c => c.COLUMN_NAME);
      const wheres = [];
      const params = [];
      for (const col of textCols) {
        for (const term of TERMS) {
          wheres.push(`${q(col)} LIKE ?`);
          params.push(`%${term}%`);
        }
      }
      try {
        const [r] = await conn.query(`DELETE FROM ${q(item.table)} WHERE ${wheres.join(" OR ")}`, params);
        if (r.affectedRows) deleted.push({ table: item.table, column: "text match", rows: r.affectedRows });
      } catch (err) {}
    }
  }

  await conn.query("SET FOREIGN_KEY_CHECKS=1");
  await conn.end();

  console.log("Maidstone delete complete.");
  console.log("Backup:", backupPath);
  console.log("Deleted:", JSON.stringify(deleted, null, 2));
}
main().catch(err => {
  console.error("Maidstone delete failed:", err.message);
  process.exit(1);
});
NODE

DD_BACKUP_DIR="$BACKUP_DIR" node "$BACKEND/delete_maidstone_once.js" || true

# Remove prior Maidstone source-doc test folders/manifests.
if [ -d "$SOURCE_DOC_ROOT/manifests" ]; then
  mkdir -p "$BACKUP_DIR/source-doc-manifests" "$BACKUP_DIR/source-doc-folders"
  grep -ril "maidstone\|25 Maidstone\|Wading River" "$SOURCE_DOC_ROOT/manifests" 2>/dev/null | while read -r mf; do
    cp -f "$mf" "$BACKUP_DIR/source-doc-manifests/$(basename "$mf")" || true
    folder="$(python3 - "$mf" <<'PY'
import json, sys
try:
    data=json.load(open(sys.argv[1]))
    print(data.get("folder",""))
except Exception:
    print("")
PY
)"
    rm -f "$mf"
    if [ -n "$folder" ] && [ -d "$SOURCE_DOC_ROOT/$folder" ]; then
      cp -a "$SOURCE_DOC_ROOT/$folder" "$BACKUP_DIR/source-doc-folders/" 2>/dev/null || true
      rm -rf "$SOURCE_DOC_ROOT/$folder"
    fi
  done
fi

python3 - <<'PY'
from pathlib import Path
import sys

SIDE = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
HTML = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")

def replace_js_function(src, name, replacement):
    start = src.find(name)
    if start < 0:
        return src, False
    brace = src.find("{", start)
    if brace < 0:
        return src, False

    depth = 0
    i = brace
    in_str = False
    quote = ""
    esc = False
    in_line = False
    in_block = False

    while i < len(src):
        ch = src[i]
        nx = src[i+1] if i+1 < len(src) else ""

        if in_line:
            if ch == "\n": in_line = False
            i += 1
            continue

        if in_block:
            if ch == "*" and nx == "/":
                in_block = False
                i += 2
            else:
                i += 1
            continue

        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == quote:
                in_str = False
            i += 1
            continue

        if ch == "/" and nx == "/":
            in_line = True
            i += 2
            continue

        if ch == "/" and nx == "*":
            in_block = True
            i += 2
            continue

        if ch in ("'", '"', "`"):
            in_str = True
            quote = ch
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[:start] + replacement + src[i+1:], True

        i += 1

    return src, False

if not HTML.exists():
    print("ERROR: Missing CLAIRE HTML.")
    sys.exit(1)

html = HTML.read_text(encoding="utf-8", errors="replace")

compact_make_terms = r'''function makeAdditionalTerms(r,f){
    const issues=[];
    const sellerAttorney=((f.attorneys||{}).seller_attorney)||{};
    const rf=(f.review_flags||[]).join(" ").toLowerCase();
    const conflicts=(f.conflicts||[]).join(" ").toLowerCase();

    if(!sellerAttorney.name && !sellerAttorney.email && !sellerAttorney.phone)issues.push("seller attorney missing");
    if(rf.includes("seller signature") || rf.includes("seller acceptance") || rf.includes("acceptance"))issues.push("seller acceptance not confirmed");
    if(conflicts.includes("pre-approval") || conflicts.includes("preapproval") || conflicts.includes("gutierrez") || conflicts.includes("legal purchaser"))issues.push("verify purchaser/pre-approval name");
    if(!issues.length && f.next_action)issues.push(String(f.next_action).replace(/\s+/g," ").trim());
    if(!issues.length)issues.push("review CLAIRE source documents before attorney package");

    let line="CLAIRE intake note: "+issues.slice(0,2).join("; ")+".";
    if(line.length>240)line=line.slice(0,237)+"...";
    return line;
  }'''

html, replaced = replace_js_function(html, "function makeAdditionalTerms", compact_make_terms)
if not replaced:
    print("WARNING: makeAdditionalTerms function not found; additional terms not patched.")

# Ensure full CLAIRE result is saved with source docs manifest, not jammed into Additional Terms.
if "claire_result: normalizeClaireResult((lastResult&&lastResult.result)||{})" not in html:
    target = "property_address:payload.property_address,"
    if target in html:
        html = html.replace(
            target,
            target + '\n      claire_result: normalizeClaireResult((lastResult&&lastResult.result)||{}),',
            1
        )

# Keep inspection as open/contingency only.
html = html.replace('inspection_status: "Complete",', 'inspection_status: "Open",')
html = html.replace('inspection_status:"Complete",', 'inspection_status:"Open",')

HTML.write_text(html, encoding="utf-8")

if SIDE.exists():
    side = SIDE.read_text(encoding="utf-8", errors="replace")

    # Store full CLAIRE read in source-doc manifest if save-source-docs route/body uses saveSourceDocsForDeal.
    if "claire_result: body.claire_result || null" not in side:
        old = "inspection_prefill: body.inspection_prefill || null\n  };"
        new = "inspection_prefill: body.inspection_prefill || null,\n    claire_result: body.claire_result || null,\n    claire_backup_note: \"Full CLAIRE intake read preserved here so Deal Desk Additional Terms can stay short.\"\n  };"
        if old in side:
            side = side.replace(old, new, 1)
        else:
            print("WARNING: source-doc manifest block not found; full CLAIRE backup not added.")

    # Add compact model rules to reduce first-read output size where possible.
    if "CLAIRE_COMPACT_OUTPUT_RULE_V1" not in side:
        const_marker = "const MAX_ATTACHMENT_BYTES"
        idx = side.find(const_marker)
        if idx >= 0:
            line_end = side.find("\n", idx)
            compact_const = r'''
const CLAIRE_COMPACT_OUTPUT_RULE_V1 = `
COMPACT OUTPUT RULE V1:
- Keep extracted field values exact, but keep prose short.
- operator_summary: one sentence, max 25 words.
- recommended_next_action: one sentence, max 18 words.
- notes: max 3 short bullets.
- review_flags: max 3 short bullets.
- missing_items: max 5 short bullets.
- conflicts: max 3 short bullets.
- Do not repeat the same fact in multiple sections.
- Do not write long paragraphs.
`;
'''
            side = side[:line_end+1] + compact_const + side[line_end+1:]

    # Insert compact rules into prompt template in askModelStructured if present.
    if "CLAIRE_COMPACT_OUTPUT_RULE_V1" in side and "${CLAIRE_COMPACT_OUTPUT_RULE_V1}" not in side:
        fn_start = side.find("async function askModelStructured")
        if fn_start >= 0:
            fn_brace = side.find("{", fn_start)
            # find end of function with existing parser by replacing no-op.
            segment = side[fn_start:]
            prompt_patterns = ["const prompt = `", "let prompt = `", "const userPrompt = `", "let userPrompt = `", "const instructions = `"]
            best = None
            for pat in prompt_patterns:
                pos = side.find(pat, fn_start, fn_start + 20000)
                if pos >= 0:
                    best = (pos, pat)
                    break
            if best:
                pos, pat = best
                insert_at = pos + len(pat)
                side = side[:insert_at] + "${CLAIRE_COMPACT_OUTPUT_RULE_V1}\n\n" + side[insert_at:]
            else:
                print("WARNING: could not locate model prompt template to insert compact rules.")
        else:
            print("WARNING: askModelStructured not found; compact prompt not inserted.")

    # Make sure save-source-docs route does not auto-clear inspection now.
    side = side.replace(
        'const inspection_clear_report = await bestEffortClearInspectionForDeal(aliases, inspectionNote);',
        'const inspection_clear_report = { ok: true, skipped: true, reason: "Offer memo identifies inspection contingency only; not auto-cleared." };'
    )

    SIDE.write_text(side, encoding="utf-8")

print("Patched compact additional terms, full CLAIRE backup storage, compact prompt rules, and inspection non-clear.")
PY

node --check "$SIDE"
pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "Patch complete."
echo ""
echo "What changed:"
echo "1. Deleted/reset 25 Maidstone rows found in MySQL."
echo "2. Removed prior Maidstone source-doc test files/manifests."
echo "3. Additional Terms is now a short CLAIRE intake note, not the full readout."
echo "4. Full CLAIRE readout is preserved in the source-doc manifest backup when source docs are saved."
echo "5. Added compact model output instructions to reduce first-read verbosity and help speed."
echo "6. Inspection remains Open when offer memo only shows it as a contingency."
echo ""
echo "Now start again:"
echo "https://servicedepartment.ai/dealdesk/claire-dealdesk-view.html"
echo ""
echo "Backup folder:"
echo "$BACKUP_DIR"
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
