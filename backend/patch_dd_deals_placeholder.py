path = "/home/servicedepartmen/dealdesk-backend/server.js"
with open(path, "r") as f:
    lines = f.readlines()

# Line 190 (1-indexed) -> index 189
target_idx = 189
line = lines[target_idx]

old = "       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,\n"
new = "       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,\n"

if line != old:
    raise SystemExit("Line 190 doesn't match expected content, aborting. Got: " + repr(line))

lines[target_idx] = new

with open(path, "w") as f:
    f.writelines(lines)

print("Patched line 190: added missing placeholder (17 -> 18).")
