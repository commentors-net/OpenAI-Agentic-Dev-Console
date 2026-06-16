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
    const { file_key, start_line = 1, end_line = 250 } = args;
    
    if (!WHITELISTED_FILES.includes(file_key)) {
        throw new Error(`Access denied: File '${file_key}' is not whitelisted.`);
    }

    // Determine if file is in frontend or backend
    let filePath;
    if (file_key === 'server.js') {
        filePath = path.join(__dirname, 'server.js');
    } else {
        // Assume frontend for others based on project structure
        filePath = path.join(__dirname, '..', 'frontend', file_key);
    }

    if (!fs.existsSync(filePath)) {
        throw new Error(`File not found: ${file_key}`);
    }

    const content = fs.readFileSync(filePath, 'utf8').split('\n');
    const slice = content.slice(start_line - 1, end_line);
    
    return redact(slice.join('\n'));
}

/**
 * Tool: grep_file
 */
async function grep_file(args) {
    const { file_key, pattern } = args;
    
    if (!WHITELISTED_FILES.includes(file_key)) {
        throw new Error(`Access denied: File '${file_key}' is not whitelisted.`);
    }

    let filePath;
    if (file_key === 'server.js') {
        filePath = path.join(__dirname, 'server.js');
    } else {
        filePath = path.join(__dirname, '..', 'frontend', file_key);
    }

    if (!fs.existsSync(filePath)) {
        throw new Error(`File not found: ${file_key}`);
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
 * Tool: pm2_status
 */
async function pm2_status() {
    return new Promise((resolve) => {
        // On Windows, PM2 might not be in path or named differently, 
        // but the spec expects it. We'll attempt it.
        exec('pm2 status dealdesk-backend', (error, stdout, stderr) => {
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

module.exports = {
    redact,
    read_file,
    grep_file,
    pm2_status,
    node_check,
    mysql_schema,
    mysql_select,
    get_deal_clearance_snapshot,
    get_dashboard_snapshot
};
