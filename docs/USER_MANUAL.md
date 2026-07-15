# Deal Desk: User & Developer Manual

This document explains the difference between the **Standard Deal Desk Frontend** and the **Dev Agent Console**, including how to use them with examples.

---

## 1. Standard Deal Desk Frontend
**Purpose:** The primary interface for real estate operators, managers, and admins to manage deals from "Accepted Offer" to "Closing."

*   **URL:** `http://localhost:3017/index.html` (Local) or `https://yourdomain.com/index.html` (Server)
*   **Target User:** Business Operators, Managers.
*   **Capabilities:** Data entry, viewing deal status, uploading documents, managing contacts, and tracking clearance tasks.

### Use Case Example:
**Scenario:** A new offer has been accepted for "123 Main St."
1.  **Action:** Open the Dashboard.
2.  **Step:** Click "Add New Deal" or process the intake from the "Inbox."
3.  **Operation:** Fill in the buyer/seller names and attorney details.
4.  **Verification:** The system generates a "Transaction Tracker" (Clearance List) automatically.

---

## 2. Dev Agent Console (The "Bridge")
**Purpose:** A secure, AI-powered developer assistant interface for technical interrogation, debugging, editing files, and running whitelisted shell commands.

*   **URL:** `http://localhost:3017/dev-console.html`
*   **Target User:** Developers, System Admins, Tech Leads.
*   **Capabilities:** Code inspection, database queries, log grepping, deal snapshots, creating/modifying code files, and executing whitelisted shell commands (`git status/diff`, `npm test/build`, etc.) under strict sandboxing.

### 2.1 Interactive Developer Approvals & Live Logs (V3 Human-in-the-Loop)
To ensure system safety, the Dev Agent cannot write files, delete paths, or execute commands autonomously. When the agent attempts these actions, a **Pending Approval** modal appears on the console UI. 

* **Live Activity Audit Logs:** The console UI is structured as a split-screen dashboard. The right-hand panel renders a real-time log of the agent's operations directly from the `dd_dev_agent_audit` database table. The logs show the tools executed, timestamps, parameters, and status (allowed/blocked).
* **Code Diffs:** Shows deleted lines (red) and proposed replacement lines (green) for targeted modifications.
* **Warning on Deletions:** If the agent requests a path deletion, a red warning banner is rendered, advising the developer of permanent, recursive directory cleanup.
* **Approve/Reject Controls:** The developer can click **Approve** to authorize the action, or **Reject** (with an explanation) to block it.
* **Custom Timeout:** Rejections or timeouts happen after **10 minutes** to allow the developer ample time to review complex code modifications.

### Use Case Example:
**Scenario:** A developer wants to verify a bug fix in `server.js` and run the project's tests.
1.  **Action:** Open the **Dev Console**.
2.  **Security:** Enter your `DEALDESK_DEV_AGENT_TOKEN`.
3.  **Prompt:** *"Find and replace the legacy port check in server.js, then run the test suite."*
4.  **Flow:**
    *   The agent uses `grep_file` to search.
    *   It requests a `replace_file_content` call. The UI displays the code diff. The developer reviews it and clicks **Approve**.
    *   It requests a `run_command` call with `npm test`. The UI displays the command. The developer clicks **Approve**.
5.  **Outcome:** The files are updated and tests are executed successfully, with all actions audited in `dd_dev_agent_audit` and rendered instantly in the Live Audit Log pane.

### 2.2 Database Schema Migrations
For database schema modifications (such as creating tables, altering columns, or adding indexes):
1.  **Migration File Creation:** The Dev Agent writes a version-controlled SQL migration file to `backend/sql/` (e.g., `002_person.sql`). The UI prompts you to review and approve the file contents.
2.  **Migration Execution:** The agent requests permission to run `node scripts/run-migration.js` via the console's command execution flow.
3.  **Approval Flow:** Review the SQL diff and the command in the approval modal, then click **Approve** to run it safely.

### 2.3 Security Restrictions & Sandbox Limitations (Critical Guardrails)

> [!CAUTION]
> **Sudo Execution and Sandbox Escapes are Strictly Blocked**
> 
> The Dev Agent Bridge does **not** support executing commands with `sudo` (root privileges) or interacting with files/directories outside the authorized home directory sandbox (`/home/servicedepartmen/`).
> 
> **Why these limitations are enforced:**
> 1. **Prevention of Web Shell Vulnerabilities:** Allowing root command execution (`sudo`) or removing path containment would effectively transform the Dev Console into an uncontained, privilege-escalated web shell. If the `DEALDESK_DEV_AGENT_TOKEN` is leaked, exposed, or if a command injection vulnerability is discovered, an attacker would gain complete administrative control of the entire server.
> 2. **Process Privilege Isolation:** The Node.js application process runs under a restricted OS user account. Running commands with `sudo` requires passwordless access in `/etc/sudoers`, which violates the principle of least privilege.
> 3. **Protection Against Destructive Operations:** System-level deletions or modifications (e.g. modifying system config files or system binaries) are prevented at both the application level and the OS-permission level to avoid irreversible damage to the hosting server.

---

## 3. Sibling Web Applications & Sandbox Whitelisting (V3 Orchestrator)

The V3 Dev Agent console has the capability to dynamically spin up and tear down independent sibling web applications (such as a separate public HR system or invoice portal) inside parent-relative hosting directories.

### 3.1 Workspace Safe Directories
The sandboxing rules in `getSafePath` permit operations inside the entire user home directory sandbox:
*   **Authorized Home Directory:** `/home/servicedepartmen/` (enabling access to sibling app directories like `devapps/` and `public_html/` alongside Deal Desk itself).

The primary Deal Desk application directories, base hosting folders, and Git/node_modules files are strictly protected from deletion.

### 3.2 Port Allocation and Sibling App Registry
To prevent port collisions, sibling backend apps are assigned unique ports in the range `3020` to `3050`. The agent maintains a local registry at `backend/storage/dev-agent-ports.json`. When creating an app, the agent:
1. Reads the port registry file to find the next available port.
2. Registers the new app name and allocated port.
3. Writes the updated registry back to disk.

### 3.3 Dynamic Public Routing (Bypassing Dev Auth)
By default, the primary Deal Desk UI is secured by Basic Auth (`.htaccess`). Sibling applications are public by default. To proxy traffic to the sibling backend port, the agent generates an independent `.htaccess` file inside the sibling's public folder (e.g., `/home/servicedepartmen/public_html/app-name/.htaccess`) overriding parent authentication limits:
```htaccess
# Sibling App Public Routing
Satisfy Any
Allow from all

RewriteEngine On
RewriteRule ^api/(.*)$ http://127.0.0.1:PORT/api/$1 [P,L,QSA]
```

### 3.4 Cleaning up / Removing Applications
To clean up or remove an application cleanly, instruct the agent to do so. Under manual developer approvals, the agent will:
1. Stop and delete the PM2 process (`pm2 stop app-name`, `pm2 delete app-name`).
2. Recursively delete the backend folder (`../devapps/app-name`) and the frontend folder (`../public_html/app-name`) using the `delete_path` tool.
3. Remove the app's record from `dev-agent-ports.json` to free the allocated port.

---

## Summary Comparison

| Feature | Standard Frontend | Dev Agent Console |
| :--- | :--- | :--- |
| **Primary Goal** | Business Operations | Technical Diagnostics & Development |
| **Interface** | Buttons, Forms, Tables | Chat (Natural Language) |
| **Data Access** | User-friendly views | Raw DB rows, Source Code, Shell |
| **Action Type** | Write/Edit/Delete (Deals) | **Supervised Read, Write & Delete** (Requires Developer Approval) |
| **Security** | User Login | Dev Agent Token (from `.env` or localhost bypass) |
| **Audit** | Deal History Table | Dev Agent Audit Table (`dd_dev_agent_audit` & Live Panel) |

---

## How to Test/Run
To run both simultaneously in VS Code, use the **Run and Debug** sidebar and select the compound configuration:
*   **Dev Mode (Backend + Console)**

This will launch the backend server and open the Developer Console side-by-side.

### Testing on a Live Linux Server (Deployment & Verification)

#### Step 1: Deploy to the Server
1. Commit and push the changes to your git repository.
2. SSH into your server, navigate to the backend root directory (e.g. `/home/servicedepartmen/dealdesk-backend-2`), and pull the latest changes:
   ```bash
   git pull
   ```
3. Restart the PM2 process manager to load the updated code:
   ```bash
   pm2 restart dealdesk-backend-2
   ```

#### Step 2: Open the Dev Console UI
1. Navigate to the secure Dev Console path in your web browser:
   `https://yourdomain.com/dev-console.html` (or your configured server domain).
2. Authenticate using the system basic auth credentials (stored in `/home/servicedepartmen/.dealdesk_htpasswd`).
3. Enter your secret `DEALDESK_DEV_AGENT_TOKEN` in the top console bar to connect to the agent.

#### Step 3: Run Validation Prompts
You can verify the new junior developer capabilities by sending the following prompts directly in the console:

*   **Test Log Tailing (PM2 logs):**
    *   *Prompt:* `"Show me the last 50 lines of logs for dealdesk-backend-2"`
    *   *Verification:* The agent executes `pm2 logs dealdesk-backend-2 --lines 50` under the hood. Confirm the command automatically appends `--no-daemon` and resolves instantly in the console without hitting connection timeouts.
*   **Test ESLint Autofixing:**
    *   *Prompt:* `"Run the code formatter to fix styles in backend/dev-agent-tools.js"`
    *   *Verification:* Review and approve the `npm run lint -- --fix` command popup. Confirm style warnings are auto-formatted.
*   **Test Dependency Installs:**
    *   *Prompt:* `"Install the public npm package uuid as a development dependency"`
    *   *Verification:* Approve the `npm install uuid -D` command block. Confirm that standard package names are allowed, while path injections (like `npm install ../other-path`) are strictly blocked by the validator.
*   **Test Git Branching & Commits:**
    *   *Prompt:* `"Checkout a new branch called dev-test, stage backend/dev-agent-tools.js, and commit changes with message 'feat: support check_port'"`
    *   *Verification:* Approve each step of the git workflow. Confirm that `git checkout`, `git add`, and `git commit` run successfully inside the sandbox boundaries.
*   **Test Port Conflicts:**
    *   *Prompt:* `"Is port 3020 free on the server?"`
    *   *Verification:* The agent invokes the `check_port` tool. Confirm it returns a JSON response indicating the port status (e.g., `{ "port": 3020, "in_use": false, "status": "free" }`) without needing manual command approvals.

