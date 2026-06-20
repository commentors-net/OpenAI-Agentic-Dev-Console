'use strict';

const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

/**
 * Redacts sensitive information from strings.
 */
function redact(text) {
    if (typeof text !== 'string') return text;
    
    // Patterns to redact
    const patterns = [
        /(OPENAI_API_KEY\s*[:=]\s*['"]?)[^'"\s\n]+(['"]?)/gi,
        /(DB_PASSWORD\s*[:=]\s*['"]?)[^'"\s\n]+(['"]?)/gi,
        /(DEALDESK_DEV_AGENT_TOKEN\s*[:=]\s*['"]?)[^'"\s\n]+(['"]?)/gi,
        /(password\s*[:=]\s*['"]?)[^'"\s\n]+(['"]?)/gi,
        /(bearer\s+)[^'"\s\n]+/gi,
        /(-----BEGIN PRIVATE KEY-----)[\s\S]+(-----END PRIVATE KEY-----)/g
    ];

    let redacted = text;
    patterns.forEach(pattern => {
        redacted = redacted.replace(pattern, (match, p1, p2) => {
            if (p2) return `${p1}[REDACTED]${p2}`;
            return `${p1}[REDACTED]`;
        });
    });

    return redacted;
}

const ROOT_DIR = path.resolve(__dirname, '..');
const parentDir = path.resolve(ROOT_DIR, '..');
const DEVAPPS_DIR = path.resolve(parentDir, 'devapps');
const PUBLIC_HTML_DIR = path.resolve(parentDir, 'public_html');

/**
 * Resolves a given path relative to the project root and checks if it's safe (sandboxed).
 */
function getSafePath(inputPath) {
    if (!inputPath) {
        throw new Error('Path is required.');
    }
    
    // Resolve absolute path
    const resolvedPath = path.isAbsolute(inputPath) 
        ? path.resolve(inputPath) 
        : path.resolve(ROOT_DIR, inputPath);
        
    // Check if it's within whitelisted sandboxes (Deal Desk, devapps, public_html)
    const allowedRoots = [ROOT_DIR, DEVAPPS_DIR, PUBLIC_HTML_DIR];
    const isAllowed = allowedRoots.some(root => resolvedPath.startsWith(root));
    
    if (!isAllowed) {
        throw new Error(`Access Denied: Path '${inputPath}' is outside authorized workspaces.`);
    }
    
    // Prevent modification of Git files/folders
    const relativeParts = path.relative(parentDir, resolvedPath).split(path.sep);
    if (relativeParts.includes('.git')) {
        throw new Error(`Access Denied: Cannot access Git files.`);
    }
    
    // Prevent modification of node_modules
    if (relativeParts.includes('node_modules')) {
        throw new Error(`Access Denied: Cannot access node_modules.`);
    }

    return resolvedPath;
}

/**
 * Whitelisted files for reading/grepping.
 */
const WHITELISTED_FILES = [
    'index.html',
    'dashboard.html',
    'detail.html',
    'input.html',
    'contacts.html',
    'print.html',
    'server.js',
    '.htaccess'
];

/**
 * Tool: read_file
 */
async function read_file(args) {
    const { file_key, file_path, start_line = 1, end_line = 250 } = args;
    
    let filePath;
    if (file_path) {
        filePath = getSafePath(file_path);
    } else if (file_key) {
        if (!WHITELISTED_FILES.includes(file_key)) {
            throw new Error(`Access denied: File '${file_key}' is not whitelisted.`);
        }
        if (file_key === 'server.js') {
            filePath = path.join(__dirname, 'server.js');
        } else {
            filePath = path.join(__dirname, '..', 'frontend', file_key);
        }
    } else {
        throw new Error("Missing parameter: 'file_key' or 'file_path' is required.");
    }

    if (!fs.existsSync(filePath)) {
        throw new Error(`File not found: ${file_path || file_key}`);
    }

    const content = fs.readFileSync(filePath, 'utf8').split('\n');
    const slice = content.slice(start_line - 1, end_line);
    
    return redact(slice.join('\n'));
}

/**
 * Tool: grep_file
 */
async function grep_file(args) {
    const { file_key, file_path, pattern } = args;
    if (!pattern) {
        throw new Error("Missing parameter: 'pattern' is required.");
    }

    let filePath;
    if (file_path) {
        filePath = getSafePath(file_path);
    } else if (file_key) {
        if (!WHITELISTED_FILES.includes(file_key)) {
            throw new Error(`Access denied: File '${file_key}' is not whitelisted.`);
        }
        if (file_key === 'server.js') {
            filePath = path.join(__dirname, 'server.js');
        } else {
            filePath = path.join(__dirname, '..', 'frontend', file_key);
        }
    } else {
        throw new Error("Missing parameter: 'file_key' or 'file_path' is required.");
    }

    if (!fs.existsSync(filePath)) {
        throw new Error(`File not found: ${file_path || file_key}`);
    }

    const content = fs.readFileSync(filePath, 'utf8').split('\n');
    const regex = new RegExp(pattern, 'i');
    
    const matches = content
        .map((line, index) => ({ line, number: index + 1 }))
        .filter(item => regex.test(item.line))
        .slice(0, 200);

    const result = matches.map(m => `L${m.number}: ${m.line}`).join('\n');
    return redact(result || '(No matches found)');
}

/**
 * Tool: write_file
 */
async function write_file(args) {
    const { file_path, content } = args;
    if (!file_path) {
        throw new Error("Missing parameter: 'file_path' is required.");
    }
    if (content === undefined) {
        throw new Error("Missing parameter: 'content' is required.");
    }

    const safePath = getSafePath(file_path);
    
    // Ensure parent directories exist
    const parentDir = path.dirname(safePath);
    if (!fs.existsSync(parentDir)) {
        fs.mkdirSync(parentDir, { recursive: true });
    }

    fs.writeFileSync(safePath, content, 'utf8');
    return `Success: Written file to ${path.relative(ROOT_DIR, safePath)}`;
}

/**
 * Tool: replace_file_content
 */
async function replace_file_content(args) {
    const { file_path, target_content, replacement_content } = args;
    if (!file_path) {
        throw new Error("Missing parameter: 'file_path' is required.");
    }
    if (target_content === undefined) {
        throw new Error("Missing parameter: 'target_content' is required.");
    }
    if (replacement_content === undefined) {
        throw new Error("Missing parameter: 'replacement_content' is required.");
    }

    const safePath = getSafePath(file_path);
    if (!fs.existsSync(safePath)) {
        throw new Error(`File not found: ${path.relative(ROOT_DIR, safePath)}`);
    }

    const fileContent = fs.readFileSync(safePath, 'utf8');
    if (!fileContent.includes(target_content)) {
        throw new Error(`Target content not found in file ${path.relative(ROOT_DIR, safePath)}.`);
    }

    const newContent = fileContent.split(target_content).join(replacement_content);
    fs.writeFileSync(safePath, newContent, 'utf8');
    return `Success: Updated file ${path.relative(ROOT_DIR, safePath)}`;
}

/**
 * Validates that a shell command is whitelisted and contains no dangerous characters.
 */
function validateCommand(command) {
    if (typeof command !== 'string') {
        throw new Error('Command must be a string.');
    }
    
    const trimmed = command.trim();
    if (!trimmed) {
        throw new Error('Command cannot be empty.');
    }

    // Reject command chaining, redirection, subshells, variables, etc.
    const forbiddenPatterns = /[&|;><`$]/;
    if (forbiddenPatterns.test(trimmed)) {
        throw new Error('Access Denied: Dangerous shell characters like &, |, ;, >, <, `, $ are forbidden.');
    }

    // Split into tokens
    const tokens = trimmed.split(/\s+/);
    const baseCmd = tokens[0];

    // Whitelist of allowed base commands (extended for PM2 in V3)
    const allowedCommands = ['git', 'npm', 'node', 'pm2'];
    if (!allowedCommands.includes(baseCmd)) {
        throw new Error(`Access Denied: Command '${baseCmd}' is not whitelisted. Only git, npm, node, and pm2 are allowed.`);
    }

    // Whitelist of allowed subcommands
    if (baseCmd === 'git') {
        const allowedGitSub = ['status', 'diff', 'log', 'show', 'branch'];
        const sub = tokens[1];
        if (!sub || !allowedGitSub.includes(sub)) {
            throw new Error(`Access Denied: 'git ${sub || ""}' is not allowed. Whitelisted git subcommands: ${allowedGitSub.join(', ')}.`);
        }
    } else if (baseCmd === 'npm') {
        const allowedNpmSub = ['run', 'test', 'install', 'build'];
        const sub = tokens[1];
        if (!sub || !allowedNpmSub.includes(sub)) {
            throw new Error(`Access Denied: 'npm ${sub || ""}' is not allowed. Whitelisted npm subcommands: ${allowedNpmSub.join(', ')}.`);
        }
        // If it's npm run, ensure we check the script name
        if (sub === 'run') {
            const script = tokens[2];
            const allowedScripts = ['build', 'test', 'dev', 'start'];
            if (!script || !allowedScripts.includes(script)) {
                throw new Error(`Access Denied: 'npm run ${script || ""}' is not allowed. Whitelisted scripts: ${allowedScripts.join(', ')}.`);
            }
        }
    } else if (baseCmd === 'node') {
        const arg = tokens[1];
        if (arg === 'scripts/run-migration.js') {
            // Allowed
        } else if (arg === '--check') {
            // Validate target path of node --check
            const filePath = tokens[2];
            if (filePath) {
                getSafePath(filePath);
            }
        } else {
            throw new Error(`Access Denied: 'node ${arg || ""}' is not allowed. Only 'node --check' and 'node scripts/run-migration.js' are allowed.`);
        }
    } else if (baseCmd === 'pm2') {
        const allowedPm2Sub = ['status', 'list', 'start', 'restart', 'stop', 'delete', 'describe', 'logs'];
        const sub = tokens[1];
        if (!sub || !allowedPm2Sub.includes(sub)) {
            throw new Error(`Access Denied: 'pm2 ${sub || ""}' is not allowed. Whitelisted pm2 subcommands: ${allowedPm2Sub.join(', ')}.`);
        }
        if (sub === 'start') {
            const script = tokens[2];
            if (script && !script.endsWith('.js') && !script.endsWith('.json')) {
                throw new Error(`Access Denied: Only JS files or ecosystem config files can be launched via PM2.`);
            }
        }
    }

    return trimmed;
}

/**
 * Tool: run_command
 */
async function run_command(args) {
    const { command, cwd } = args;
    const validatedCmd = validateCommand(command);

    let execCwd = ROOT_DIR;
    if (cwd) {
        execCwd = getSafePath(cwd);
    }

    return new Promise((resolve) => {
        // Execute with a timeout of 15 seconds
        exec(validatedCmd, { cwd: execCwd, timeout: 15000 }, (error, stdout, stderr) => {
            let output = '';
            if (stdout) output += stdout;
            if (stderr) output += `\nStderr:\n${stderr}`;
            if (error) {
                if (error.killed) {
                    output += `\nError: Command timed out after 15 seconds.`;
                } else {
                    output += `\nError: Command failed with exit code ${error.code || error.signal}.`;
                }
            }
            resolve(redact(output.trim() || 'Command completed with no output.'));
        });
    });
}

/**
 * Tool: pm2_status
 */
async function pm2_status() {
    return new Promise((resolve) => {
        // On Windows, PM2 might not be in path or named differently, 
        // but the spec expects it. We'll attempt it.
        exec('pm2 status dealdesk-backend-2', (error, stdout, stderr) => {
            resolve(stdout || stderr || 'PM2 command failed or not found.');
        });
    });
}

/**
 * Tool: node_check
 */
async function node_check() {
    return new Promise((resolve) => {
        const serverPath = path.join(__dirname, 'server.js');
        exec(`node --check "${serverPath}"`, (error, stdout, stderr) => {
            resolve(stderr || stdout || 'Syntax OK');
        });
    });
}

/**
 * Whitelisted tables for MySQL interrogation.
 */
const WHITELISTED_TABLES = [
    'dd_deals',
    'dd_transaction_tasks',
    'dd_deal_history',
    'dd_communications',
    'dd_directory_contacts',
    'dd_manager_chat_questions'
];

/**
 * Tool: mysql_schema
 */
async function mysql_schema(args, pool) {
    const { table_name } = args;
    if (!WHITELISTED_TABLES.includes(table_name)) {
        throw new Error(`Access denied: Table '${table_name}' is not whitelisted.`);
    }

    const [cols] = await pool.query(`SHOW COLUMNS FROM ??`, [table_name]);
    return JSON.stringify(cols, null, 2);
}

/**
 * Tool: mysql_select
 */
async function mysql_select(args, pool) {
    let { query } = args;
    
    // Safety checks
    const upper = query.trim().toUpperCase();
    if (!upper.startsWith('SELECT')) {
        throw new Error('Rejected: Only SELECT queries are allowed.');
    }
    if (upper.includes(';') && upper.indexOf(';') !== upper.length - 1) {
        throw new Error('Rejected: Multiple statements are not allowed.');
    }

    const forbidden = ['INSERT', 'UPDATE', 'DELETE', 'DROP', 'ALTER', 'CREATE', 'TRUNCATE', 'REPLACE', 'GRANT', 'LOAD', 'OUTFILE'];
    for (const word of forbidden) {
        if (new RegExp(`\\b${word}\\b`, 'i').test(query)) {
            throw new Error(`Rejected: Forbidden keyword '${word}' detected.`);
        }
    }

    // Check table whitelist in query
    const tableMatches = query.match(/FROM\s+([a-zA-Z0-9_`]+)/i);
    if (tableMatches) {
        const table = tableMatches[1].replace(/`/g, '');
        if (!WHITELISTED_TABLES.includes(table)) {
            throw new Error(`Access denied: Table '${table}' is not whitelisted.`);
        }
    }

    // Enforce LIMIT 100
    if (!/LIMIT\s+\d+/i.test(query)) {
        query += ' LIMIT 100';
    }

    const [rows] = await pool.query(query);
    return redact(JSON.stringify(rows, null, 2));
}

/**
 * Tool: get_deal_clearance_snapshot
 */
async function get_deal_clearance_snapshot(args, pool) {
    const { deal_id } = args;
    
    // Find deal by public_id or address
    const [deals] = await pool.query(
        `SELECT id, public_id, property_address, transaction_status, control_state 
         FROM dd_deals 
         WHERE (public_id = ? OR property_address LIKE ?) AND removed_at IS NULL LIMIT 1`,
        [deal_id, `%${deal_id}%`]
    );

    if (!deals.length) return `Deal not found: ${deal_id}`;
    const deal = deals[0];

    const [tasks] = await pool.query(
        `SELECT task_name, status, control_state, due_date, evidence_note 
         FROM dd_transaction_tasks 
         WHERE deal_id = ?`,
        [deal.id]
    );

    return JSON.stringify({ deal, tasks }, null, 2);
}

/**
 * Tool: get_dashboard_snapshot
 */
async function get_dashboard_snapshot(args, pool) {
    const [[activeRow]] = await pool.query(
        "SELECT COUNT(*) AS count FROM dd_deals WHERE removed_at IS NULL AND transaction_status NOT IN ('Closed','Cancelled','Removed')"
    );

    const [[missingRow]] = await pool.query(
        "SELECT COUNT(*) AS count FROM dd_deals WHERE removed_at IS NULL AND transaction_status = 'Missing Information'"
    );

    const [recentDeals] = await pool.query(
        `SELECT
            d.public_id,
            d.property_address,
            d.transaction_status,
            (SELECT COUNT(*) FROM dd_transaction_tasks t
             WHERE t.deal_id = d.id
               AND LOWER(COALESCE(t.control_state,'open')) NOT IN ('complete','completed','not_applicable','not applicable','na','n/a')
            ) AS waiting_on_count,
            (SELECT COUNT(*) FROM dd_transaction_tasks t
             WHERE t.deal_id = d.id
               AND LOWER(COALESCE(t.control_state,'')) IN ('needs_followup','needs follow-up','needs_follow_up','blocked')
            ) AS blocked_count
         FROM dd_deals d
         WHERE d.removed_at IS NULL
         ORDER BY d.created_at DESC
         LIMIT 10`
    );

    return JSON.stringify({
        summary: {
            active_deals: activeRow.count,
            missing_info: missingRow.count
        },
        recent_deals: recentDeals
    }, null, 2);
}

/**
 * Tool: list_directory
 */
async function list_directory(args) {
    const { dir_path = '.' } = args;
    const safePath = getSafePath(dir_path);
    
    if (!fs.existsSync(safePath)) {
        throw new Error(`Directory not found: ${dir_path}`);
    }
    
    const stats = fs.statSync(safePath);
    if (!stats.isDirectory()) {
        throw new Error(`Path is not a directory: ${dir_path}`);
    }
    
    const entries = fs.readdirSync(safePath, { withFileTypes: true });
    const list = entries
        .filter(entry => {
            const name = entry.name;
            return name !== 'node_modules' && name !== '.git';
        })
        .map(entry => {
            const entryPath = path.join(safePath, entry.name);
            let size = null;
            if (entry.isFile()) {
                try {
                    size = fs.statSync(entryPath).size;
                } catch (e) {
                    // Ignore errors during stat
                }
            }
            return {
                name: entry.name,
                is_directory: entry.isDirectory(),
                is_file: entry.isFile(),
                size
            };
        });
        
    return JSON.stringify(list, null, 2);
}

/**
 * Tool: delete_path
 */
async function delete_path(args) {
    const { path_to_delete } = args;
    if (!path_to_delete) {
        throw new Error("Missing parameter: 'path_to_delete' is required.");
    }

    const safePath = getSafePath(path_to_delete);

    // Safety checks:
    // 1. Cannot delete ROOT_DIR (Deal Desk root), backend folder, or Deal Desk frontend
    if (safePath === ROOT_DIR || safePath === path.join(ROOT_DIR, 'backend')) {
        throw new Error("Access Denied: Cannot delete the primary application backend directory.");
    }
    
    const frontendPath = path.resolve(ROOT_DIR, '..', 'frontend');
    if (safePath === frontendPath) {
        throw new Error("Access Denied: Cannot delete the primary application frontend directory.");
    }

    // 2. Cannot delete the base devapps or public_html directories themselves
    if (safePath === DEVAPPS_DIR || safePath === PUBLIC_HTML_DIR) {
        throw new Error("Access Denied: Cannot delete the root application hosting directories.");
    }

    // Ensure it exists (checked after safety matches)
    if (!fs.existsSync(safePath)) {
        throw new Error(`Path not found: ${path_to_delete}`);
    }

    // Perform removal recursively
    const stats = fs.statSync(safePath);
    if (stats.isDirectory()) {
        fs.rmSync(safePath, { recursive: true, force: true });
    } else {
        fs.unlinkSync(safePath);
    }

    return `Success: Deleted path ${path.relative(parentDir, safePath)}`;
}

module.exports = {
    redact,
    read_file,
    grep_file,
    write_file,
    replace_file_content,
    run_command,
    pm2_status,
    node_check,
    mysql_schema,
    mysql_select,
    get_deal_clearance_snapshot,
    get_dashboard_snapshot,
    list_directory,
    delete_path
};


