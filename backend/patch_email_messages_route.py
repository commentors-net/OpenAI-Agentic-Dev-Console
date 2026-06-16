path = "/home/servicedepartmen/dealdesk-backend/server.js"
with open(path, "r") as f:
    src = f.read()

marker = "  if (req.method === 'POST' && (url.pathname === '/api/dealdesk/email-intake/import' || url.pathname === '/api/email-intake/import')) {"

if "/api/email-intake/messages" in src:
    print("Route already present, skipping.")
else:
    if marker not in src:
        raise SystemExit("Marker not found, aborting.")

    new_route = '''  if (req.method === 'GET' && (url.pathname === '/api/dealdesk/email-intake/messages' || url.pathname === '/api/email-intake/messages')) {
    const limit = Number(url.searchParams.get('limit') || 25);
    const result = await clairePickerListEmails(limit);
    sendJson(res, 200, { ok: true, ...result });
    return;
  }

'''
    src = src.replace(marker, new_route + marker, 1)
    with open(path, "w") as f:
        f.write(src)
    print("Inserted GET /api/email-intake/messages route.")
