#!/usr/bin/env bash
set -euo pipefail

BACKEND="/home/servicedepartmen/dealdesk-backend"
APPDIR="/home/servicedepartmen/public_html/dealdesk"
SIDE="$BACKEND/claire_dealview_sidecar.js"
HTML="$APPDIR/claire-dealdesk-view.html"
STAMP="$(date +%Y%m%d-%H%M%S)"
PM2_NAME="dealdesk-claire-dealview"

mkdir -p "$BACKEND/backups" "$APPDIR/backups"

if [ ! -f "$SIDE" ]; then
  echo "ERROR: Missing $SIDE"
  exit 1
fi

if [ ! -f "$HTML" ]; then
  echo "ERROR: Missing $HTML"
  exit 1
fi

cp -f "$SIDE" "$BACKEND/backups/claire_dealview_sidecar.js.before-json-unwrap-$STAMP.bak"
cp -f "$HTML" "$APPDIR/backups/claire-dealdesk-view.html.before-json-unwrap-$STAMP.bak"

python3 - <<'PY'
from pathlib import Path
import sys

side = Path("/home/servicedepartmen/dealdesk-backend/claire_dealview_sidecar.js")
text = side.read_text(encoding="utf-8", errors="replace")

def replace_function(src, name, new_func):
    start = src.find("function " + name + "(")
    if start < 0:
        print("ERROR: Could not find function", name)
        sys.exit(1)

    brace = src.find("{", start)
    depth = 0
    i = brace
    in_single = in_double = in_template = False
    in_line_comment = in_block_comment = False
    escape = False

    while i < len(src):
        ch = src[i]
        nxt = src[i+1] if i+1 < len(src) else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue

        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 2
            else:
                i += 1
            continue

        if in_single or in_double or in_template:
            if escape:
                escape = False
                i += 1
                continue
            if ch == "\\":
                escape = True
                i += 1
                continue
            if in_single and ch == "'":
                in_single = False
            elif in_double and ch == '"':
                in_double = False
            elif in_template and ch == "`":
                in_template = False
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
        if ch == "'":
            in_single = True
            i += 1
            continue
        if ch == '"':
            in_double = True
            i += 1
            continue
        if ch == "`":
            in_template = True
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                return src[:start] + new_func + src[end:]

        i += 1

    print("ERROR: Could not find end of function", name)
    sys.exit(1)

helper = r'''
function extractFirstJsonObject(raw) {
  const s = String(raw || "").trim();
  const start = s.indexOf("{");
  if (start < 0) return "";

  let depth = 0;
  let inString = false;
  let escape = false;

  for (let i = start; i < s.length; i++) {
    const ch = s[i];

    if (inString) {
      if (escape) {
        escape = false;
      } else if (ch === "\\") {
        escape = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }

    if (ch === "{") depth++;
    if (ch === "}") {
      depth--;
      if (depth === 0) return s.slice(start, i + 1);
    }
  }

  return "";
}

'''

if "function extractFirstJsonObject(raw)" not in text:
    idx = text.find("function parseJsonModelOutput")
    if idx < 0:
        print("ERROR: Could not find parseJsonModelOutput insertion point")
        sys.exit(1)
    text = text[:idx] + helper + text[idx:]

new_parse = r'''function parseJsonModelOutput(text) {
  const raw = String(text || "").trim();

  function parseMaybe(value) {
    if (!value) return null;
    try { return JSON.parse(value); } catch (err) { return null; }
  }

  let parsed = parseMaybe(raw);
  if (parsed) return parsed;

  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced) {
    parsed = parseMaybe(fenced[1].trim());
    if (parsed) return parsed;

    const firstFenced = extractFirstJsonObject(fenced[1]);
    parsed = parseMaybe(firstFenced);
    if (parsed) return parsed;
  }

  const first = extractFirstJsonObject(raw);
  parsed = parseMaybe(first);
  if (parsed) return parsed;

  return { parse_error: true, raw_output: raw };
}'''

text = replace_function(text, "parseJsonModelOutput", new_parse)
side.write_text(text, encoding="utf-8")

html = Path("/home/servicedepartmen/public_html/dealdesk/claire-dealdesk-view.html")
h = html.read_text(encoding="utf-8", errors="replace")

if "function extractFirstJsonObjectFromText" not in h:
    marker = "  function renderAll(d){"
    if marker not in h:
        print("ERROR: Could not find renderAll marker in HTML")
        sys.exit(1)

    helper_js = r'''
  function extractFirstJsonObjectFromText(raw){
    const s=String(raw||"").trim();
    const start=s.indexOf("{");
    if(start<0)return "";
    let depth=0,inString=false,escape=false;
    for(let i=start;i<s.length;i++){
      const ch=s[i];
      if(inString){
        if(escape){escape=false}
        else if(ch==="\\"){escape=true}
        else if(ch==='"'){inString=false}
        continue;
      }
      if(ch==='"'){inString=true;continue}
      if(ch==="{")depth++;
      if(ch==="}"){
        depth--;
        if(depth===0)return s.slice(start,i+1);
      }
    }
    return "";
  }

  function normalizeClaireResult(r){
    if(!r)return {};
    if(r.parse_error && r.raw_output){
      const first=extractFirstJsonObjectFromText(r.raw_output);
      try{return JSON.parse(first)}catch(e){}
    }
    if(r.raw_output && typeof r.raw_output==="string" && !r.dealdesk_fields){
      const first=extractFirstJsonObjectFromText(r.raw_output);
      try{return JSON.parse(first)}catch(e){}
    }
    return r;
  }

'''
    h = h.replace(marker, helper_js + marker, 1)

h = h.replace("    const r=d.result||{};", "    const r=normalizeClaireResult(d.result||{});")

html.write_text(h, encoding="utf-8")
print("Patched sidecar JSON parser and HTML result normalizer.")
PY

node --check "$SIDE"

pm2 restart "$PM2_NAME" --update-env

echo "****************************"
echo "COPY FROM HERE"
echo "****************************"
echo "CLAIRE Deal Desk View JSON unwrap fixed."
echo ""
echo "What happened:"
echo "- The model returned full JSON, but wrapped it as parse_error/raw_output."
echo "- It also appears to have duplicated the JSON object in raw_output."
echo "- The screen had data, but was looking in the wrong layer."
echo ""
echo "Now refresh:"
echo "https://servicedepartment.ai/dealdesk/claire-dealdesk-view.html"
echo ""
echo "Select the same email and click Read Selected Email again."
echo "****************************"
echo "STOP COPY HERE"
echo "****************************"
