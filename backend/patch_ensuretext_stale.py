path = "/home/servicedepartmen/dealdesk-backend/server.js"
with open(path, "r") as f:
    src = f.read()

old = """    if (att.text_extract && att.text_extract.trim()) return att.text_extract;"""

new = """    if (att.text_extract && att.text_extract.trim() && !/^\\[PDF text extraction failed/.test(att.text_extract.trim())) return att.text_extract;"""

if old not in src:
    raise SystemExit("Block not found, aborting.")

src = src.replace(old, new, 1)

with open(path, "w") as f:
    f.write(src)

print("Patched ensureText to ignore stale failed-extraction markers.")
