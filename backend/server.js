'use strict';

const http = require('http');
const https = require('https');
const path = require('path');
const crypto = require('crypto');
const nodemailer = require('nodemailer');
const devAgentTools = require('./dev-agent-tools');
require('dotenv').config({ path: path.join(__dirname, '.env') });

const mysql = require('mysql2/promise');

const PORT = Number(process.env.DEALDESK_PORT || 3017);
const HOST = process.env.DEALDESK_HOST || '127.0.0.1';

const pool = mysql.createPool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0
});

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(body);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 1000000) {
        req.destroy();
        reject(new Error('Request body too large'));
      }
    });
    req.on('end', () => {
      if (!body.trim()) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(body));
      } catch (err) {
        reject(new Error('Invalid JSON body'));
      }
    });
    req.on('error', reject);
  });
}

function cleanText(value) {
  if (value === undefined || value === null) return null;
  const text = String(value).trim();
  return text === '' ? null : text;
}

function money(value) {
  if (value === undefined || value === null || value === '') return null;
  const cleaned = String(value).replace(/[$,]/g, '').trim();
  if (cleaned === '') return null;
  const parsed = Number(cleaned);
  if (!Number.isFinite(parsed)) return null;
  return parsed;
}

function datetimeOrNow(value) {
  const v = cleanText(value);
  if (!v) {
    return new Date().toISOString().slice(0, 19).replace('T', ' ');
  }
  return v.replace('T', ' ');
}

function datetimeOrNull(value) {
  const v = cleanText(value);
  if (!v) return null;
  return v.replace('T', ' ');
}

function dateOrNull(value) {
  const text = cleanText(value);
  if (!text) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return null;
  return text;
}

function partyRows(dealId, body) {
  const rows = [
    ['seller', body.seller_name, body.seller_legal_address, null, null, null, null, 10],
    ['purchaser', body.purchaser_name, body.purchaser_legal_address, null, null, null, null, 20],
    ['seller_attorney', body.seller_attorney_name, body.seller_attorney_address, null, null, body.seller_attorney_phone, body.seller_attorney_email, 30],
    ['purchaser_attorney', body.purchaser_attorney_name, body.purchaser_attorney_address, null, null, body.purchaser_attorney_phone, body.purchaser_attorney_email, 40],
    ['seller_agent', body.seller_agent_name, null, body.seller_agent_broker, body.seller_agent_license, body.seller_agent_phone, body.seller_agent_email, 50],
    ['purchaser_agent', body.purchaser_agent_name, null, body.purchaser_agent_broker, body.purchaser_agent_license, body.purchaser_agent_phone, body.purchaser_agent_email, 60],
    ['lender', body.lender_name, body.lender_address, body.lender_company, null, body.lender_phone, body.lender_email, 70]
  ];

  return rows
    .filter(row => cleanText(row[1]) || cleanText(row[2]) || cleanText(row[3]) || cleanText(row[4]) || cleanText(row[5]) || cleanText(row[6]))
    .map(row => [dealId, row[0], cleanText(row[1]), cleanText(row[2]), cleanText(row[3]), cleanText(row[4]), cleanText(row[5]), cleanText(row[6]), row[7]]);
}

async function getDashboard() {
  const [[activeRow]] = await pool.query(
    "SELECT COUNT(*) AS count FROM dd_deals WHERE removed_at IS NULL AND transaction_status NOT IN ('Closed','Cancelled','Removed')"
  );

  const [[missingRow]] = await pool.query(
    "SELECT COUNT(*) AS count FROM dd_deals WHERE removed_at IS NULL AND transaction_status = 'Missing Information'"
  );

  const [[readyRow]] = await pool.query(
    "SELECT COUNT(*) AS count FROM dd_deals WHERE removed_at IS NULL AND transaction_status = 'Ready for Attorney Handoff'"
  );

  const [recentDeals] = await pool.query(
    `SELECT
       d.public_id,
       d.accepted_offer_date,
       d.mls_number,
       d.property_address,
       d.property_type,
       d.transaction_status,
       d.next_action,
       d.created_at,
       (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'seller' LIMIT 1) AS seller_name,
       (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'purchaser' LIMIT 1) AS purchaser_name,
        (SELECT COUNT(*) FROM dd_transaction_tasks t
         WHERE t.deal_id = d.id
           AND LOWER(COALESCE(t.control_state,'open')) NOT IN ('complete','completed','not_applicable','not applicable','na','n/a')
       ) AS waiting_on_count,
        (SELECT COUNT(*) FROM dd_transaction_tasks t
         WHERE t.deal_id = d.id
           AND LOWER(COALESCE(t.control_state,'')) IN ('needs_followup','needs follow-up','needs_follow_up','blocked')
       ) AS blocked_count,
        (SELECT MIN(t.due_date) FROM dd_transaction_tasks t WHERE t.deal_id = d.id AND t.status IN ('Waiting','In Progress','Blocked') AND t.due_date IS NOT NULL) AS next_due_date,
        (SELECT t.task_name FROM dd_transaction_tasks t WHERE t.deal_id = d.id AND t.status IN ('Waiting','In Progress','Blocked') ORDER BY t.due_date IS NULL, t.due_date, t.created_at DESC LIMIT 1) AS next_waiting_on,
        (SELECT COUNT(*) FROM dd_transaction_tasks t
         WHERE t.deal_id = d.id
           AND LOWER(COALESCE(t.control_state,'open')) NOT IN ('complete','completed','not_applicable','not applicable','na','n/a')
       ) AS waiting_on_count,
        (SELECT COUNT(*) FROM dd_transaction_tasks t
         WHERE t.deal_id = d.id
           AND LOWER(COALESCE(t.control_state,'')) IN ('needs_followup','needs follow-up','needs_follow_up','blocked')
       ) AS blocked_count,
        (SELECT MIN(t.due_date) FROM dd_transaction_tasks t WHERE t.deal_id = d.id AND t.status IN ('Waiting','In Progress','Blocked') AND t.due_date IS NOT NULL) AS next_due_date,
        (SELECT t.task_name FROM dd_transaction_tasks t WHERE t.deal_id = d.id AND t.status IN ('Waiting','In Progress','Blocked') ORDER BY t.due_date IS NULL, t.due_date, t.created_at DESC LIMIT 1) AS next_waiting_on
     FROM dd_deals d
     WHERE d.removed_at IS NULL
     ORDER BY d.created_at DESC
     LIMIT 10`
  );

  return {
    accepted_offers: activeRow.count,
    missing_items: missingRow.count,
    ready_for_attorney: readyRow.count,
    pilot_agents: 20,
    recent_deals: recentDeals
  };
}

async function createDeal(body) {
  const propertyAddress = cleanText(body.property_address);
  if (!propertyAddress) {
    const err = new Error('Property address is required');
    err.statusCode = 400;
    throw err;
  }

  const publicId = crypto.randomUUID();
  const status = cleanText(body.transaction_status) || 'Accepted Offer Intake Started';

  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    const [dealResult] = await connection.query(
      `INSERT INTO dd_deals
       (public_id, team_name, brokerage_name, accepted_offer_date, mls_number, property_address, property_type, transaction_status, next_action, property_condition_statement_status, additional_terms, seller_acknowledgment_name, seller_acknowledgment_date, purchaser_acknowledgment_name, purchaser_acknowledgment_date, source_label, created_by, updated_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        publicId,
        cleanText(body.team_name) || 'Pilot Team',
        cleanText(body.brokerage_name),
        dateOrNull(body.accepted_offer_date),
        cleanText(body.mls_number),
        propertyAddress,
        cleanText(body.property_type),
        status,
        cleanText(body.next_action) || 'Review Clearance Path and verify required contacts.',
        cleanText(body.property_condition_statement_status),
        cleanText(body.additional_terms),
        cleanText(body.seller_acknowledgment_name),
        dateOrNull(body.seller_acknowledgment_date),
        cleanText(body.purchaser_acknowledgment_name),
        dateOrNull(body.purchaser_acknowledgment_date),
        cleanText(body.source_label) || 'Accepted Offer Intake',
        cleanText(body.created_by) || 'pilot',
        cleanText(body.updated_by) || 'pilot'
      ]
    );

    const dealId = dealResult.insertId;

    await connection.query(
      `INSERT INTO dd_deal_financials
       (deal_id, purchase_price, seller_concession, contract_deposit, mortgage_amount, cash_at_closing, total_price, commission_paid_by_seller, commission_paid_by_purchaser, contract_date_text, closing_date_text)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        dealId,
        money(body.purchase_price),
        money(body.seller_concession),
        money(body.contract_deposit),
        money(body.mortgage_amount),
        money(body.cash_at_closing),
        money(body.total_price),
        cleanText(body.commission_paid_by_seller),
        cleanText(body.commission_paid_by_purchaser),
        cleanText(body.contract_date_text),
        cleanText(body.closing_date_text)
      ]
    );

    const parties = partyRows(dealId, body);
    if (parties.length) {
      await connection.query(
        `INSERT INTO dd_deal_parties
         (deal_id, role_key, display_name, legal_address, broker_name, license_number, phone, email, sort_order)
         VALUES ?`,
        [parties]
      );
    }

    const checklistItems = [
      ['property_condition_statement', 'Property condition statement reviewed', cleanText(body.property_condition_statement_status) || 'Unknown'],
      ['seller_contact_complete', 'Seller information complete', cleanText(body.seller_name) ? 'Needs Review' : 'Missing'],
      ['purchaser_contact_complete', 'Purchaser information complete', cleanText(body.purchaser_name) ? 'Needs Review' : 'Missing'],
      ['attorney_contacts_complete', 'Attorney contacts complete', cleanText(body.seller_attorney_email) && cleanText(body.purchaser_attorney_email) ? 'Needs Review' : 'Missing'],
      ['agent_contacts_complete', 'Agent contacts complete', cleanText(body.seller_agent_email) && cleanText(body.purchaser_agent_email) ? 'Needs Review' : 'Missing']
    ];

    for (const item of checklistItems) {
      await connection.query(
        `INSERT INTO dd_deal_checklist
         (deal_id, item_key, item_label, status, answer_text)
         VALUES (?, ?, ?, ?, ?)`,
        [dealId, item[0], item[1], item[2], item[2]]
      );
    }

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        dealId,
        'Deal Created',
        'Accepted offer intake record created.',
        cleanText(body.created_by) || 'pilot'
      ]
    );

    await connection.query(
      `INSERT INTO dd_usage_ledger
       (deal_id, item_type, item_id, action_type, action_summary, created_by)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [
        dealId,
        'accepted_offer_record',
        dealId,
        'created',
        'Accepted offer intake was created in the system.',
        cleanText(body.created_by) || 'pilot'
      ]
    );

    await connection.commit();

    return {
      id: dealId,
      public_id: publicId,
      transaction_status: status,
      property_address: propertyAddress
    };
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}


async function removeDeal(publicId, body) {
  const removedBy = cleanText(body.removed_by) || 'pilot';
  const removalReason = cleanText(body.removal_reason) || 'Removed from accepted-offer dashboard by user.';

  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    const [[deal]] = await connection.query(
      `SELECT id, property_address, transaction_status, removed_at
       FROM dd_deals
       WHERE public_id = ?
       LIMIT 1`,
      [publicId]
    );

    if (!deal) {
      await connection.rollback();
      return null;
    }

    if (deal.removed_at) {
      await connection.rollback();
      return {
        already_removed: true,
        property_address: deal.property_address
      };
    }

    await connection.query(
      `UPDATE dd_deals
       SET transaction_status = 'Removed',
           removed_at = NOW(),
           removed_by = ?,
           removal_reason = ?,
           updated_by = ?
       WHERE id = ?`,
      [removedBy, removalReason, removedBy, deal.id]
    );

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, old_value, new_value, created_by)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [
        deal.id,
        'Deal Removed',
        'Accepted offer was removed from the active dashboard.',
        deal.transaction_status,
        'Removed',
        removedBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_usage_ledger
       (deal_id, item_type, item_id, action_type, action_summary, result_notes, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        deal.id,
        'accepted_offer_record',
        deal.id,
        'removed',
        'Accepted offer was removed from active use.',
        removalReason,
        removedBy
      ]
    );

    await connection.commit();

    return {
      already_removed: false,
      property_address: deal.property_address
    };
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}

async function getDeal(publicId) {
  const [[deal]] = await pool.query(
    `SELECT *
     FROM dd_deals
     WHERE public_id = ?
     LIMIT 1`,
    [publicId]
  );

  if (!deal) return null;

  const [[financials]] = await pool.query(
    `SELECT *
     FROM dd_deal_financials
     WHERE deal_id = ?
     LIMIT 1`,
    [deal.id]
  );

  const [parties] = await pool.query(
    `SELECT role_key, display_name, legal_address, broker_name, license_number, phone, email, sort_order
     FROM dd_deal_parties
     WHERE deal_id = ?
     ORDER BY sort_order, id`,
    [deal.id]
  );

  const [checklist] = await pool.query(
    `SELECT item_key, item_label, status, answer_text, reviewed_by, reviewed_at
     FROM dd_deal_checklist
     WHERE deal_id = ?
     ORDER BY id`,
    [deal.id]
  );

  const [history] = await pool.query(
    `SELECT event_type, event_summary, created_by, created_at
     FROM dd_deal_history
     WHERE deal_id = ?
     ORDER BY created_at DESC, id DESC
     LIMIT 20`,
    [deal.id]
  );

  const [generatedItems] = await pool.query(
    `SELECT public_id, item_type, title, generated_text, model, item_status, created_by, created_at
     FROM dd_generated_items
     WHERE deal_id = ?
     ORDER BY created_at DESC, id DESC
     LIMIT 10`,
    [deal.id]
  );

  return {
    deal,
    financials: financials || null,
    parties,
    checklist,
    history,
    generated_items: generatedItems
  };
}


async function listDirectoryContacts(url) {
  const contactType = cleanText(url.searchParams.get('type'));
  const query = cleanText(url.searchParams.get('q'));
  const limitText = cleanText(url.searchParams.get('limit'));
  const limit = Math.min(Math.max(Number(limitText || 25), 1), 100);

  const where = ['is_active = 1'];
  const params = [];

  if (contactType && contactType !== 'all') {
    where.push('contact_type = ?');
    params.push(contactType);
  }

  if (query) {
    where.push(`(
      display_name LIKE ?
      OR company_name LIKE ?
      OR email LIKE ?
      OR phone LIKE ?
      OR broker_name LIKE ?
      OR license_number LIKE ?
    )`);
    const like = `%${query}%`;
    params.push(like, like, like, like, like, like);
  }

  params.push(limit);

  const [rows] = await pool.query(
    `SELECT public_id, contact_type, contact_subtype, display_name, organization_name,
       working_contact_name, working_contact_role, company_name, legal_address,
       broker_name, license_number, phone, email, notes, responsiveness_rating,
       effectiveness_rating, clearance_notes, last_contacted_at,
       clearance_touch_count, clearance_success_count, created_at, updated_at
     FROM dd_directory_contacts
     WHERE ${where.join(' AND ')}
     ORDER BY
       CASE contact_type
         WHEN 'agent' THEN 1
         WHEN 'attorney' THEN 2
         WHEN 'lender' THEN 3
         ELSE 9
       END,
       display_name
     LIMIT ?`,
    params
  );

  return rows;
}

async function createDirectoryContact(body) {
  const displayName = cleanText(body.display_name);
  const contactType = cleanText(body.contact_type) || cleanText(body.type) || 'contact';

  if (!displayName) {
    const err = new Error('Display name is required');
    err.statusCode = 400;
    throw err;
  }

  const publicId = crypto.randomUUID();

  const [result] = await pool.query(
    `INSERT INTO dd_directory_contacts
     (public_id, contact_type, display_name, company_name, legal_address, broker_name, license_number, phone, email, notes, created_by, updated_by)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      publicId,
      contactType,
      displayName,
      cleanText(body.company_name),
      cleanText(body.legal_address),
      cleanText(body.broker_name),
      cleanText(body.license_number),
      cleanText(body.phone),
      cleanText(body.email),
      cleanText(body.notes),
      cleanText(body.created_by) || 'pilot',
      cleanText(body.updated_by) || 'pilot'
    ]
  );

  const [[row]] = await pool.query(
    `SELECT public_id, contact_type, display_name, company_name, legal_address, broker_name, license_number, phone, email, notes, created_at, updated_at
     FROM dd_directory_contacts
     WHERE id = ?
     LIMIT 1`,
    [result.insertId]
  );

  return row;
}



const AOC_AI_INSTRUCTIONS = `You are the AI operating layer for Accepted Offer to Close, a brokerage transaction-management system.

The workflow starts only after an offer has been accepted. Do not treat this as lead generation, sales prospecting, CRM outreach, or pre-offer negotiation.

The MySQL transaction record is the source of truth. If a fact is missing, call it missing. Do not invent facts.

You may identify missing items, inconsistencies, operational risks, contract-readiness issues, and attorney-handoff readiness.

Do not provide legal advice. Do not say a document is legally sufficient. Do not say anything was approved, sent, or used unless the transaction record says so.

Treat every response as a generated review only. It is not approved, sent, or used until a human action records that later.

Return a concise operational review with these sections:
1. Deal Summary
2. Missing Items
3. Discrepancies or Risk Flags
4. Contract Readiness
5. Attorney Handoff Readiness
6. Recommended Next Action
7. Suggested Audit Event`;

const pendingActions = new Map();

async function requestDeveloperApproval(actionType, details, userPrompt) {
  const actionId = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    pendingActions.set(actionId, {
      id: actionId,
      type: actionType,
      details,
      user_prompt: userPrompt,
      resolve,
      reject,
      status: 'pending',
      created_at: Date.now()
    });

    // Timeout after 10 minutes to prevent hanging forever (V3 Upgrade)
    setTimeout(() => {
      if (pendingActions.has(actionId)) {
        const act = pendingActions.get(actionId);
        if (act.status === 'pending') {
          act.status = 'timed_out';
          pendingActions.delete(actionId);
          reject(new Error('Approval request timed out after 10 minutes.'));
        }
      }
    }, 600000);
  });
}

const DEV_AGENT_INSTRUCTIONS = `You are the Deal Desk Dev Agent Bridge (v3). 
Your role is to help the developer interrogate the live application state, modify files securely, and manage/create sibling applications in the workspace context.

RULES:
- You can read, search, write, modify, and delete files within Deal Desk, sibling backend devapps, and sibling public_html directories.
- You can execute whitelisted development commands (such as npm build/test, git diff/status, node check, or pm2 commands) using run_command.
- You can pass a 'cwd' parameter to run_command to execute commands in sibling app directories.
- Always use the provided tools to gather information before answering or writing files.
- Redact all API keys, passwords, and secrets from your final answer.
- When spinning up sibling apps (e.g., an HR system):
  1. Suggest the target path explicitly: Backends go to '../devapps/app-name', Frontends go to '../public_html/app-name'.
  2. Dynamically allocate ports between 3020 and 3050. Read, write, and update 'backend/storage/dev-agent-ports.json' to register allocated ports.
  3. Ensure the sibling app frontend contains a public .htaccess file that maps API routing to its unique port, overriding parent folder authentication basic auth.
  4. Prompt the developer with the exact paths and port you will use before initiating creation.
- When removing/deleting a sibling app:
  1. Stop and delete the PM2 process first using run_command (e.g., "pm2 stop app-name", "pm2 delete app-name").
  2. Use delete_path to remove the backend directory (e.g., "../devapps/app-name") and the frontend directory (e.g., "../public_html/app-name").
  3. Read 'backend/storage/dev-agent-ports.json', remove the deleted app port record, and write it back.
  4. Inform the developer of the completed cleanup steps.`;

const DEV_AGENT_TOOLS = [
  {
    type: 'function',
    function: {
      name: 'read_file',
      description: 'Reads a project file. Specify file_key for whitelisted files or file_path for any safe workspace path.',
      parameters: {
        type: 'object',
        properties: {
          file_key: { type: 'string', enum: ['index.html', 'dashboard.html', 'detail.html', 'input.html', 'contacts.html', 'print.html', 'server.js', '.htaccess'] },
          file_path: { type: 'string', description: 'Relative path in the workspace, e.g., backend/server.js' },
          start_line: { type: 'integer' },
          end_line: { type: 'integer' }
        }
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'grep_file',
      description: 'Searches a project file for a pattern.',
      parameters: {
        type: 'object',
        properties: {
          file_key: { type: 'string', enum: ['index.html', 'dashboard.html', 'detail.html', 'input.html', 'contacts.html', 'print.html', 'server.js', '.htaccess'] },
          file_path: { type: 'string', description: 'Relative path in the workspace' },
          pattern: { type: 'string' }
        },
        required: ['pattern']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'write_file',
      description: 'Creates a new file or overwrites an existing file with the provided content.',
      parameters: {
        type: 'object',
        properties: {
          file_path: { type: 'string', description: 'Relative or absolute path in the workspace.' },
          content: { type: 'string', description: 'Complete content to write to the file.' }
        },
        required: ['file_path', 'content']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'replace_file_content',
      description: 'Replaces a specific substring (target_content) in a file with the replacement_content.',
      parameters: {
        type: 'object',
        properties: {
          file_path: { type: 'string', description: 'Relative or absolute path in the workspace.' },
          target_content: { type: 'string', description: 'The exact substring to replace.' },
          replacement_content: { type: 'string', description: 'The content to replace target_content with.' }
        },
        required: ['file_path', 'target_content', 'replacement_content']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'run_command',
      description: 'Executes a whitelisted shell command (git, npm, node --check, pm2) in the workspace.',
      parameters: {
        type: 'object',
        properties: {
          command: { type: 'string', description: 'The whitelisted command to execute, e.g., "git status", "npm test", "node --check server.js", "pm2 list".' },
          cwd: { type: 'string', description: 'Optional relative or absolute directory path to run the command in.' }
        },
        required: ['command']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'mysql_schema',
      description: 'Shows the schema for a whitelisted table.',
      parameters: {
        type: 'object',
        properties: {
          table_name: { type: 'string', enum: ['dd_deals', 'dd_transaction_tasks', 'dd_deal_history', 'dd_communications', 'dd_directory_contacts', 'dd_manager_chat_questions'] }
        },
        required: ['table_name']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'mysql_select',
      description: 'Runs a read-only SELECT query against approved tables.',
      parameters: {
        type: 'object',
        properties: {
          query: { type: 'string' }
        },
        required: ['query']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'get_deal_clearance_snapshot',
      description: 'Returns a summary of all clearance tasks for a specific deal.',
      parameters: {
        type: 'object',
        properties: {
          deal_id: { type: 'string', description: 'Public ID or property address snippet.' }
        },
        required: ['deal_id']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'get_dashboard_snapshot',
      description: 'Returns a snapshot of the current dashboard counts and recent deals.',
      parameters: { type: 'object', properties: {} }
    }
  },
  {
    type: 'function',
    function: {
      name: 'pm2_status',
      description: 'Checks the status of the dealdesk-backend process.',
      parameters: { type: 'object', properties: {} }
    }
  },
  {
    type: 'function',
    function: {
      name: 'node_check',
      description: 'Runs a syntax check on server.js.',
      parameters: { type: 'object', properties: {} }
    }
  },
  {
    type: 'function',
    function: {
      name: 'list_directory',
      description: 'Lists files and directories in a given workspace folder path.',
      parameters: {
        type: 'object',
        properties: {
          dir_path: { type: 'string', description: 'Relative path in the workspace, e.g. "backend" or "backend/sql". Defaults to root ".".' }
        }
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'delete_path',
      description: 'Deletes a file or directory recursively inside whitelisted workspace directories (devapps or public_html).',
      parameters: {
        type: 'object',
        properties: {
          path_to_delete: { type: 'string', description: 'Relative or absolute directory/file path to delete, e.g., "../devapps/hr-system".' }
        },
        required: ['path_to_delete']
      }
    }
  }
];

function extractOpenAiText(responseJson) {
  if (typeof responseJson.output_text === 'string') return responseJson.output_text.trim();

  const chunks = [];
  for (const item of responseJson.output || []) {
    for (const content of item.content || []) {
      if (content.type === 'output_text' && content.text) chunks.push(content.text);
    }
  }

  return chunks.join('\n').trim();
}

function callOpenAiReview(prompt) {
  return new Promise((resolve, reject) => {
    const apiKey = process.env.OPENAI_API_KEY;
    const model = process.env.OPENAI_MODEL || 'gpt-5.5';

    if (!apiKey || !apiKey.startsWith('sk-')) {
      reject(new Error('OPENAI_API_KEY is missing or invalid'));
      return;
    }

    const payload = JSON.stringify({
      model,
      instructions: AOC_AI_INSTRUCTIONS,
      input: prompt,
      store: false
    });

    const req = https.request({
      hostname: 'api.openai.com',
      path: '/v1/responses',
      method: 'POST',
      timeout: 45000,
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      }
    }, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch (err) {
          reject(new Error('OpenAI returned a non-JSON response'));
          return;
        }

        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(parsed.error && parsed.error.message ? parsed.error.message : 'OpenAI request failed'));
          return;
        }

        const generatedText = extractOpenAiText(parsed);
        if (!generatedText) {
          reject(new Error('OpenAI response did not include text output'));
          return;
        }

        resolve({
          model,
          response_id: parsed.id || null,
          generated_text: generatedText
        });
      });
    });

    req.on('timeout', () => {
      req.destroy(new Error('OpenAI request timed out'));
    });

    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

function publicDealRecordForAi(record) {
  return {
    accepted_offer: {
      public_id: record.deal.public_id,
      accepted_offer_date: record.deal.accepted_offer_date,
      mls_number: record.deal.mls_number,
      property_address: record.deal.property_address,
      transaction_status: record.deal.transaction_status,
      next_action: record.deal.next_action,
      property_condition_statement_status: record.deal.property_condition_statement_status,
      additional_terms: record.deal.additional_terms,
      seller_acknowledgment_name: record.deal.seller_acknowledgment_name,
      seller_acknowledgment_date: record.deal.seller_acknowledgment_date,
      purchaser_acknowledgment_name: record.deal.purchaser_acknowledgment_name,
      purchaser_acknowledgment_date: record.deal.purchaser_acknowledgment_date
    },
    financials: record.financials,
    parties: record.parties,
    checklist: record.checklist,
    transaction_tasks: record.transaction_tasks || [],
    email_messages: record.email_messages || [],
    communication_log: record.communication_log || []
  };
}

async function createAiReview(publicId, body) {
  const record = await getDeal(publicId);
  if (!record) return null;

  if (record.deal.removed_at) {
    const err = new Error('Cannot review a removed accepted offer');
    err.statusCode = 400;
    throw err;
  }

  const createdBy = cleanText(body.created_by) || 'pilot';
  const title = `Offer Review - ${record.deal.property_address}`;

  const prompt = [
    'Review this accepted-offer transaction record.',
    'Use only the facts in this JSON.',
    'Flag missing information instead of guessing.',
    JSON.stringify(publicDealRecordForAi(record), null, 2)
  ].join('\n\n');

  const ai = await callOpenAiReview(prompt);
  const itemPublicId = crypto.randomUUID();

  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    const [generatedResult] = await connection.query(
      `INSERT INTO dd_generated_items
       (public_id, deal_id, item_type, title, prompt_summary, generated_text, model, item_status, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        itemPublicId,
        record.deal.id,
        'ai_accepted_offer_review',
        title,
        'System reviewed accepted-offer record for missing items, discrepancies, contract readiness, attorney handoff readiness, and next action.',
        ai.generated_text,
        ai.model,
        'Generated',
        createdBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        record.deal.id,
        'Offer Review Generated',
        'Offer review generated. It has not been approved, sent, or used.',
        createdBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_usage_ledger
       (deal_id, item_type, item_id, action_type, action_summary, result_notes, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        record.deal.id,
        'ai_accepted_offer_review',
        generatedResult.insertId,
        'generated',
        'System generated an accepted-offer review.',
        'Generated only. Not approved, sent, or used.',
        createdBy
      ]
    );

    await connection.commit();

    return {
      public_id: itemPublicId,
      item_type: 'ai_accepted_offer_review',
      title,
      generated_text: ai.generated_text,
      model: ai.model,
      item_status: 'Generated'
    };
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}




async function updateTransactionTask(publicId, taskPublicId, body) {
  const status = cleanText(body.status) || 'Waiting';

  if (['Received', 'Completed', 'Waived', 'Not Applicable'].includes(status)) {
    const err = new Error('Use Communication Log to close or complete tracker items so the file records who confirmed it and what was verified.');
    err.statusCode = 400;
    throw err;
  }

  const updatedBy = cleanText(body.updated_by) || cleanText(body.created_by) || 'pilot';
  const noteText = cleanText(body.verification_notes) || cleanText(body.notes);
  const noteToAppend = noteText ? `[${new Date().toISOString()}] ${updatedBy}: ${noteText}` : '';

  const [[task]] = await pool.query(
    `SELECT t.id, t.deal_id, t.task_name, d.removed_at
     FROM dd_transaction_tasks t
     JOIN dd_deals d ON d.id = t.deal_id
     WHERE d.public_id = ? AND t.public_id = ?
     LIMIT 1`,
    [publicId, taskPublicId]
  );

  if (!task) return null;

  if (task.removed_at) {
    const err = new Error('Cannot update tracker item for a removed accepted offer');
    err.statusCode = 400;
    throw err;
  }

  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    await connection.query(
      `UPDATE dd_transaction_tasks
       SET status = ?,
           priority = COALESCE(NULLIF(?, ''), priority),
           waiting_on_name = COALESCE(NULLIF(?, ''), waiting_on_name),
           office_contact_name = COALESCE(NULLIF(?, ''), office_contact_name),
           office_contact_role = COALESCE(NULLIF(?, ''), office_contact_role),
           office_contact_phone = COALESCE(NULLIF(?, ''), office_contact_phone),
           office_contact_email = COALESCE(NULLIF(?, ''), office_contact_email),
           due_date = COALESCE(?, due_date),
           verified_at = COALESCE(?, verified_at),
           last_contacted_at = NOW(),
           completed_at = CASE
             WHEN ? IN ('Completed', 'Waived', 'Not Applicable') THEN NOW()
             ELSE completed_at
           END,
           verification_notes = CASE
             WHEN ? <> '' THEN CONCAT_WS('\n', NULLIF(verification_notes, ''), ?)
             ELSE verification_notes
           END,
           updated_by = ?
       WHERE id = ?`,
      [
        status,
        cleanText(body.priority),
        cleanText(body.waiting_on_name),
        cleanText(body.office_contact_name),
        cleanText(body.office_contact_role),
        cleanText(body.office_contact_phone),
        cleanText(body.office_contact_email),
        dateOrNull(body.due_date),
        datetimeOrNull(body.verified_at),
        status,
        noteToAppend,
        noteToAppend,
        updatedBy,
        task.id
      ]
    );

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        task.deal_id,
        'Tracker Item Updated',
        `Tracker item updated: ${task.task_name} is now ${status}.`,
        updatedBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_usage_ledger
       (deal_id, item_type, item_id, action_type, action_summary, result_notes, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        task.deal_id,
        'transaction_tracker_item',
        task.id,
        'updated',
        `Transaction tracker item updated: ${task.task_name}`,
        noteText || `Status changed to ${status}.`,
        updatedBy
      ]
    );

    await connection.commit();

    const [[row]] = await pool.query(
      `SELECT public_id, category, task_name, waiting_on_entity_type, waiting_on_name,
              office_contact_name, office_contact_role, office_contact_phone, office_contact_email,
              status, priority, due_date, last_contacted_at, verified_at, completed_at,
              verification_notes, notes, created_by, updated_by, created_at, updated_at
       FROM dd_transaction_tasks
       WHERE id = ?
       LIMIT 1`,
      [task.id]
    );

    return row;
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}


async function createTransactionTask(publicId, body) {
  const taskName = cleanText(body.task_name);
  const category = cleanText(body.category) || 'Other';

  if (!taskName) {
    const err = new Error('Task name is required');
    err.statusCode = 400;
    throw err;
  }

  const [[deal]] = await pool.query(
    `SELECT id, property_address, removed_at
     FROM dd_deals
     WHERE public_id = ?
     LIMIT 1`,
    [publicId]
  );

  if (!deal) return null;

  if (deal.removed_at) {
    const err = new Error('Cannot add tracker item to a removed accepted offer');
    err.statusCode = 400;
    throw err;
  }

  const taskPublicId = crypto.randomUUID();
  const createdBy = cleanText(body.created_by) || 'pilot';

  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    const [result] = await connection.query(
      `INSERT INTO dd_transaction_tasks
       (public_id, deal_id, category, task_name, waiting_on_entity_type, waiting_on_name,
        office_contact_name, office_contact_role, office_contact_phone, office_contact_email,
        status, priority, due_date, last_contacted_at, verified_at, verification_notes, notes,
        created_by, updated_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        taskPublicId,
        deal.id,
        category,
        taskName,
        cleanText(body.waiting_on_entity_type),
        cleanText(body.waiting_on_name),
        cleanText(body.office_contact_name),
        cleanText(body.office_contact_role),
        cleanText(body.office_contact_phone),
        cleanText(body.office_contact_email),
        cleanText(body.status) || 'Waiting',
        cleanText(body.priority) || 'Normal',
        dateOrNull(body.due_date),
        cleanText(body.last_contacted_at) || null,
        cleanText(body.verified_at) || null,
        cleanText(body.verification_notes),
        cleanText(body.notes),
        createdBy,
        createdBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        deal.id,
        'Tracker Item Added',
        `Tracker item added: ${taskName}`,
        createdBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_usage_ledger
       (deal_id, item_type, item_id, action_type, action_summary, created_by)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [
        deal.id,
        'transaction_tracker_item',
        result.insertId,
        'created',
        `Transaction tracker item created: ${taskName}`,
        createdBy
      ]
    );

    await connection.commit();

    const [[row]] = await pool.query(
      `SELECT public_id, category, task_name, waiting_on_entity_type, waiting_on_name,
              office_contact_name, office_contact_role, office_contact_phone, office_contact_email,
              status, priority, due_date, last_contacted_at, verified_at, completed_at,
              verification_notes, notes, created_by, created_at
       FROM dd_transaction_tasks
       WHERE id = ?
       LIMIT 1`,
      [result.insertId]
    );

    return row;
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}



function findParty(record, roleKey) {
  return (record.parties || []).find(p => p.role_key === roleKey) || {};
}

function smtpSettings() {
  return {
    host: process.env.SMTP_HOST || '',
    port: Number(process.env.SMTP_PORT || 587),
    secure: String(process.env.SMTP_SECURE || '').toLowerCase() === 'true',
    user: process.env.SMTP_USER || '',
    pass: process.env.SMTP_PASS || '',
    fromEmail: process.env.SMTP_FROM_EMAIL || process.env.SMTP_USER || '',
    fromName: process.env.SMTP_FROM_NAME || 'Accepted Offer to Close'
  };
}

function ensureSmtpConfigured() {
  const smtp = smtpSettings();

  if (!smtp.host || !smtp.user || !smtp.pass || !smtp.fromEmail) {
    const err = new Error('SMTP is not configured yet. Add SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM_EMAIL, and SMTP_FROM_NAME to .env before sending.');
    err.statusCode = 400;
    throw err;
  }

  return smtp;
}

function makeTransporter() {
  const smtp = ensureSmtpConfigured();

  return nodemailer.createTransport({
    host: smtp.host,
    port: smtp.port,
    secure: smtp.secure,
    auth: {
      user: smtp.user,
      pass: smtp.pass
    }
  });
}

function moneyText(value) {
  if (value === null || value === undefined || value === '') return 'Not entered';
  const n = Number(value);
  if (!Number.isFinite(n)) return String(value);
  return n.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
}

function line(label, value) {
  return `${label}: ${value || 'Not entered'}`;
}

function dealSummaryLines(record) {
  const deal = record.deal || {};
  const f = record.financials || {};
  const seller = findParty(record, 'seller');
  const purchaser = findParty(record, 'purchaser');
  const sellerAttorney = findParty(record, 'seller_attorney');
  const purchaserAttorney = findParty(record, 'purchaser_attorney');
  const sellerAgent = findParty(record, 'seller_agent');
  const purchaserAgent = findParty(record, 'purchaser_agent');
  const lender = findParty(record, 'lender');

  return [
    line('Property', deal.property_address),
    line('Property Type', deal.property_type),
    line('MLS', deal.mls_number),
    line('Accepted Offer Date', deal.accepted_offer_date),
    line('Purchase Price', moneyText(f.purchase_price)),
    line('Contract Deposit', moneyText(f.contract_deposit)),
    line('Mortgage Amount', moneyText(f.mortgage_amount)),
    line('Seller Concession', moneyText(f.seller_concession)),
    line('On or About Contract Date', f.contract_date_text),
    line('On or About Closing Date', f.closing_date_text),
    line('Seller', seller.display_name),
    line('Purchaser', purchaser.display_name),
    line('Seller Attorney', sellerAttorney.display_name),
    line('Purchaser Attorney', purchaserAttorney.display_name),
    line('Seller Agent', sellerAgent.display_name),
    line('Purchaser Agent', purchaserAgent.display_name),
    line('Lender / Loan Officer', lender.display_name),
    line('Property Condition Statement', deal.property_condition_statement_status),
    line('Additional Terms', deal.additional_terms)
  ];
}

function buildStartEmail(record, recipientRole) {
  const deal = record.deal || {};
  const sellerAttorney = findParty(record, 'seller_attorney');
  const purchaserAttorney = findParty(record, 'purchaser_attorney');
  const lender = findParty(record, 'lender');

  let recipient = null;
  let subject = '';
  let intro = '';

  if (recipientRole === 'seller_attorney') {
    recipient = sellerAttorney;
    subject = `Accepted Offer - ${deal.property_address || 'Property'}`;
    intro = 'We are opening the accepted-offer file and sending the core deal information for attorney coordination and contract preparation.';
  } else if (recipientRole === 'purchaser_attorney') {
    recipient = purchaserAttorney;
    subject = `Accepted Offer - ${deal.property_address || 'Property'}`;
    intro = 'We are opening the accepted-offer file and sending the core deal information for attorney coordination and contract review.';
  } else if (recipientRole === 'lender') {
    recipient = lender;
    subject = `Accepted Offer Financing Coordination - ${deal.property_address || 'Property'}`;
    intro = 'We are opening the accepted-offer file and sending the core deal information for financing coordination.';
  } else {
    return null;
  }

  if (!recipient.email) return null;

  const body = [
    `Hello ${recipient.display_name || ''},`.trim(),
    '',
    intro,
    '',
    'Deal summary:',
    ...dealSummaryLines(record).map(v => `- ${v}`),
    '',
    'Please confirm receipt and let us know who will be handling this file, including the best contact name, phone number, and email for follow-up.',
    '',
    'Thank you,',
    'Accepted Offer to Close'
  ].join('\n');

  return {
    email_type: 'start_process',
    recipient_role: recipientRole,
    to_name: recipient.display_name || null,
    to_email: recipient.email,
    subject,
    body
  };
}

async function createStartEmails(publicId, body) {
  const record = await getDeal(publicId);
  if (!record) return null;

  if (record.deal.removed_at) {
    const err = new Error('Cannot create emails for a removed accepted offer');
    err.statusCode = 400;
    throw err;
  }

  const createdBy = cleanText(body.created_by) || 'pilot';
  const roles = ['seller_attorney', 'purchaser_attorney', 'lender'];
  const drafts = roles.map(role => buildStartEmail(record, role)).filter(Boolean);

  if (!drafts.length) {
    const err = new Error('No attorney or lender email addresses are available on this accepted-offer file.');
    err.statusCode = 400;
    throw err;
  }

  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    const created = [];

    for (const draft of drafts) {
      const msgPublicId = crypto.randomUUID();

      const [result] = await connection.query(
        `INSERT INTO dd_email_messages
         (public_id, deal_id, email_type, recipient_role, to_name, to_email, subject, body, email_status, created_by)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          msgPublicId,
          record.deal.id,
          draft.email_type,
          draft.recipient_role,
          draft.to_name,
          draft.to_email,
          draft.subject,
          draft.body,
          'Draft',
          createdBy
        ]
      );

      await connection.query(
        `INSERT INTO dd_usage_ledger
         (deal_id, item_type, item_id, action_type, action_summary, recipient, result_notes, created_by)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          record.deal.id,
          'start_email',
          result.insertId,
          'generated',
          `Start email draft generated for ${draft.recipient_role}.`,
          draft.to_email,
          'Generated only. Not sent.',
          createdBy
        ]
      );

      created.push({
        public_id: msgPublicId,
        recipient_role: draft.recipient_role,
        to_name: draft.to_name,
        to_email: draft.to_email,
        subject: draft.subject,
        body: draft.body,
        email_status: 'Draft'
      });
    }

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        record.deal.id,
        'Start Emails Generated',
        `Generated ${created.length} start email draft(s). They have not been sent.`,
        createdBy
      ]
    );

    await connection.commit();

    return created;
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}

async function sendEmailMessage(emailPublicId, body) {
  const sentBy = cleanText(body.sent_by) || 'pilot';

  const [[msg]] = await pool.query(
    `SELECT e.*, d.property_address
     FROM dd_email_messages e
     JOIN dd_deals d ON d.id = e.deal_id
     WHERE e.public_id = ?
     LIMIT 1`,
    [emailPublicId]
  );

  if (!msg) return null;

  if (msg.email_status === 'Sent') {
    const err = new Error('This email has already been sent.');
    err.statusCode = 400;
    throw err;
  }

  const smtp = ensureSmtpConfigured();
  const transporter = makeTransporter();

  try {
    const info = await transporter.sendMail({
      from: `"${smtp.fromName}" <${smtp.fromEmail}>`,
      to: msg.to_name ? `"${msg.to_name}" <${msg.to_email}>` : msg.to_email,
      cc: msg.cc_email || undefined,
      subject: msg.subject,
      text: msg.body
    });

    await pool.query(
      `UPDATE dd_email_messages
       SET email_status = 'Sent',
           provider_message_id = ?,
           sent_at = NOW(),
           sent_by = ?,
           failed_at = NULL,
           failure_reason = NULL
       WHERE id = ?`,
      [info.messageId || null, sentBy, msg.id]
    );

    await pool.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        msg.deal_id,
        'Email Sent',
        `Start email sent to ${msg.to_email}.`,
        sentBy
      ]
    );

    await pool.query(
      `INSERT INTO dd_usage_ledger
       (deal_id, item_type, item_id, action_type, action_summary, recipient, result_notes, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        msg.deal_id,
        'start_email',
        msg.id,
        'sent',
        'Start email was sent from the system.',
        msg.to_email,
        info.messageId || null,
        sentBy
      ]
    );

    return {
      public_id: msg.public_id,
      to_email: msg.to_email,
      subject: msg.subject,
      email_status: 'Sent',
      provider_message_id: info.messageId || null
    };
  } catch (err) {
    await pool.query(
      `UPDATE dd_email_messages
       SET email_status = 'Failed',
           failed_at = NOW(),
           failure_reason = ?
       WHERE id = ?`,
      [err.message, msg.id]
    );

    await pool.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        msg.deal_id,
        'Email Failed',
        `Start email failed for ${msg.to_email}: ${err.message}`,
        sentBy
      ]
    );

    throw err;
  }
}



async function updateDealStatus(publicId, body) {
  const allowedStatuses = new Set([
    'Active',
    'Contract Out',
    'In Contract',
    'Closing Scheduled',
    'Closed',
    'Final',
    'On Hold'
  ]);

  const newStatus = cleanText(body.transaction_status);
  const updatedBy = cleanText(body.updated_by) || 'pilot';
  const note = cleanText(body.status_note);

  if (!allowedStatuses.has(newStatus)) {
    const err = new Error('Invalid transaction status');
    err.statusCode = 400;
    throw err;
  }

  const [[deal]] = await pool.query(
    `SELECT id, property_address, transaction_status, removed_at
     FROM dd_deals
     WHERE public_id = ?
     LIMIT 1`,
    [publicId]
  );

  if (!deal) return null;

  if (deal.removed_at) {
    const err = new Error('Cannot update status for a removed accepted offer');
    err.statusCode = 400;
    throw err;
  }

  if (newStatus !== (deal.transaction_status || '')) {
    if (newStatus === 'On Hold' && !note) {
      const err = new Error('Status Note is required when placing a file On Hold.');
      err.statusCode = 400;
      throw err;
    }

    const clearedStates = new Set(['complete', 'completed', 'not_applicable', 'not applicable', 'na', 'n/a']);

    const taskText = (task) => Object.values(task || {})
      .filter(value => value !== null && value !== undefined)
      .join(' ')
      .toLowerCase();

    const taskState = (task) => String(task.control_state || task.status || '').toLowerCase();

    const isCleared = (task) => clearedStates.has(taskState(task));

    const matchesTask = (task, tests) => {
      const text = taskText(task);
      return tests.every(test => test.test(text));
    };

    const [clearanceRows] = await pool.query(
      `SELECT *
       FROM dd_transaction_tasks
       WHERE deal_id = ?
       ORDER BY id`,
      [deal.id]
    );

    const missingRequired = (requirements) => requirements
      .filter(requirement => {
        const found = clearanceRows.find(task => matchesTask(task, requirement.tests));
        return !found || !isCleared(found);
      })
      .map(requirement => requirement.label);

    if (newStatus === 'Contract Out') {
      const blockers = missingRequired([
        { label: 'Seller Attorney', tests: [/seller/, /attorney/] },
        { label: 'Purchaser Attorney', tests: [/(purchaser|buyer)/, /attorney/] },
        { label: 'Inspection', tests: [/inspection/] },
        { label: 'Seller acknowledgment', tests: [/seller/, /acknowledg/] },
        { label: 'Purchaser acknowledgment', tests: [/(purchaser|buyer)/, /acknowledg/] },
        { label: 'Property Condition Statement', tests: [/property/, /condition/] }
      ]);

      if (blockers.length) {
        const err = new Error('Cannot update to Contract Out yet. Clear or mark Not Applicable first: ' + blockers.join(', '));
        err.statusCode = 400;
        err.blockers = blockers;
        throw err;
      }
    }

    if (newStatus === 'In Contract') {
      if (deal.transaction_status !== 'Contract Out') {
        const err = new Error('Cannot update to In Contract yet. File must first be Contract Out.');
        err.statusCode = 400;
        throw err;
      }

      const blockers = missingRequired([
        { label: 'Contract', tests: [/contract/] }
      ]);

      if (blockers.length) {
        const err = new Error('Cannot update to In Contract yet. Clear or mark Not Applicable first: ' + blockers.join(', '));
        err.statusCode = 400;
        err.blockers = blockers;
        throw err;
      }
    }
  }

  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    await connection.query(
      `UPDATE dd_deals
       SET transaction_status = ?,
           next_action = CASE
             WHEN ? IN ('Closed', 'Final') THEN 'File marked ' 
             ELSE next_action
           END,
           updated_at = NOW()
       WHERE id = ?`,
      [newStatus, newStatus, deal.id]
    );

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        deal.id,
        'Status Updated',
        `Status changed from ${deal.transaction_status || 'Not set'} to ${newStatus}.` + (note ? ` Note: ${note}` : ''),
        updatedBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_usage_ledger
       (deal_id, item_type, item_id, action_type, action_summary, result_notes, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        deal.id,
        'accepted_offer_file',
        deal.id,
        'status_updated',
        `Accepted-offer status changed to ${newStatus}.`,
        note || null,
        updatedBy
      ]
    );

    await connection.commit();

    const [[updated]] = await pool.query(
      `SELECT public_id, property_address, transaction_status, next_action
       FROM dd_deals
       WHERE id = ?
       LIMIT 1`,
      [deal.id]
    );

    return updated;
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}



function hasUsefulValue(value) {
  return cleanText(value) !== '';
}

function buildTransactionPlanItems(record) {
  const deal = record.deal || {};
  const financials = record.financials || {};
  const sellerAttorney = findParty(record, 'seller_attorney');
  const purchaserAttorney = findParty(record, 'purchaser_attorney');
  const lender = findParty(record, 'lender');

  const items = [];

  function add(category, taskName, entityType, entityName, status, priority, notes) {
    items.push({
      category,
      task_name: taskName,
      waiting_on_entity_type: entityType,
      waiting_on_name: entityName || '',
      status: status || 'Waiting',
      priority: priority || 'Normal',
      notes: notes || ''
    });
  }

  add(
    'Attorney',
    'Confirm who is handling the file at seller attorney office',
    'Attorney Office',
    sellerAttorney.display_name || 'Seller attorney office',
    sellerAttorney.email ? 'Waiting' : 'Blocked',
    sellerAttorney.email ? 'Normal' : 'High',
    sellerAttorney.email ? 'Confirm paralegal / assistant contact and best email for follow-up.' : 'Seller attorney email is missing from the accepted-offer file.'
  );

  add(
    'Attorney',
    'Confirm who is handling the file at purchaser attorney office',
    'Attorney Office',
    purchaserAttorney.display_name || 'Purchaser attorney office',
    purchaserAttorney.email ? 'Waiting' : 'Blocked',
    purchaserAttorney.email ? 'Normal' : 'High',
    purchaserAttorney.email ? 'Confirm paralegal / assistant contact and best email for follow-up.' : 'Purchaser attorney email is missing from the accepted-offer file.'
  );

  add(
    'Attorney',
    'Track contract preparation / contract out',
    'Attorney Office',
    sellerAttorney.display_name || 'Seller attorney office',
    'Waiting',
    'High',
    'Track whether contract has been requested, prepared, sent out, revised, and fully executed.'
  );

  add(
    'Lender',
    'Confirm lender / loan officer and financing status',
    'Lender Office',
    lender.display_name || lender.broker_name || 'Lender / loan officer',
    lender.email || hasUsefulValue(financials.mortgage_amount) ? 'Waiting' : 'Blocked',
    'High',
    lender.email ? 'Confirm loan officer, processor, application status, and next financing deadline.' : 'Lender email is not entered. Confirm lender / loan officer contact.'
  );

  add(
    'Inspection',
    'Track inspection status',
    'Inspector',
    'Inspector / inspection company',
    deal.additional_terms && deal.additional_terms.toLowerCase().includes('inspection completed') ? 'Completed' : 'Waiting',
    'Normal',
    deal.additional_terms && deal.additional_terms.toLowerCase().includes('inspection completed') ? 'Additional terms indicate inspection completed. Verify whether any issues remain.' : 'Confirm whether inspection is scheduled, completed, waived, or has unresolved issues.'
  );

  add(
    'Appraisal',
    'Track appraisal status',
    'Appraiser',
    'Appraiser / lender appraisal desk',
    hasUsefulValue(financials.mortgage_amount) ? 'Waiting' : 'Not Applicable',
    'Normal',
    hasUsefulValue(financials.mortgage_amount) ? 'Confirm whether appraisal is ordered, scheduled, completed, and whether value issues exist.' : 'No mortgage amount entered; confirm whether appraisal tracking is applicable.'
  );

  add(
    'Title',
    'Confirm title contact / title order status',
    'Title Company',
    'Title company',
    'Waiting',
    'Normal',
    'Confirm title company, title contact, title order status, and any title issues.'
  );

  add(
    'Seller',
    'Confirm seller acknowledgment of receipt',
    'Seller',
    'Seller',
    hasUsefulValue(deal.seller_acknowledgment_name) && hasUsefulValue(deal.seller_acknowledgment_date) ? 'Completed' : 'Waiting',
    'Normal',
    'Confirm seller acknowledgment name and date are complete.'
  );

  add(
    'Buyer',
    'Confirm purchaser acknowledgment of receipt',
    'Buyer',
    'Purchaser',
    hasUsefulValue(deal.purchaser_acknowledgment_name) && hasUsefulValue(deal.purchaser_acknowledgment_date) ? 'Completed' : 'Waiting',
    'Normal',
    'Confirm purchaser acknowledgment name and date are complete.'
  );

  add(
    'Buyer',
    'Confirm property condition statement status',
    'Buyer',
    'Purchaser / buyer representative',
    hasUsefulValue(deal.property_condition_statement_status) ? 'Received' : 'Waiting',
    'Normal',
    'Confirm whether buyer or buyer representative received the property condition statement, or whether the file is exempt.'
  );

  return items;
}

async function buildTransactionPlan(publicId, body) {
  const record = await getDeal(publicId);
  if (!record) return null;

  if (record.deal.removed_at) {
    const err = new Error('Cannot build a transaction plan for a removed accepted offer');
    err.statusCode = 400;
    throw err;
  }

  const createdBy = cleanText(body.created_by) || 'pilot';
  const planItems = buildTransactionPlanItems(record);
  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    const created = [];
    const skipped = [];

    for (const item of planItems) {
      const [[existing]] = await connection.query(
        `SELECT id, public_id
         FROM dd_transaction_tasks
         WHERE deal_id = ? AND category = ? AND task_name = ?
         LIMIT 1`,
        [record.deal.id, item.category, item.task_name]
      );

      if (existing) {
        skipped.push(item.task_name);
        continue;
      }

      const taskPublicId = crypto.randomUUID();

      const [result] = await connection.query(
        `INSERT INTO dd_transaction_tasks
         (public_id, deal_id, category, task_name, waiting_on_entity_type, waiting_on_name,
          status, priority, notes, created_by, updated_by)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          taskPublicId,
          record.deal.id,
          item.category,
          item.task_name,
          item.waiting_on_entity_type,
          item.waiting_on_name,
          item.status,
          item.priority,
          item.notes,
          createdBy,
          createdBy
        ]
      );

      await connection.query(
        `INSERT INTO dd_usage_ledger
         (deal_id, item_type, item_id, action_type, action_summary, result_notes, created_by)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [
          record.deal.id,
          'transaction_plan_item',
          result.insertId,
          'created',
          `Transaction plan item created: ${item.task_name}`,
          item.notes,
          createdBy
        ]
      );

      created.push({
        public_id: taskPublicId,
        category: item.category,
        task_name: item.task_name,
        status: item.status,
        priority: item.priority
      });
    }

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        record.deal.id,
        'Transaction Plan Built',
        `Built transaction plan: ${created.length} item(s) added, ${skipped.length} existing item(s) skipped.`,
        createdBy
      ]
    );

    await connection.commit();

    return {
      created_count: created.length,
      skipped_count: skipped.length,
      created,
      skipped
    };
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}




function categoryFromEntityType(entityType) {
  const v = cleanText(entityType).toLowerCase();

  if (v.includes('attorney')) return 'Attorney';
  if (v.includes('lender')) return 'Lender';
  if (v.includes('title')) return 'Title';
  if (v.includes('inspector')) return 'Inspection';
  if (v.includes('appraiser')) return 'Appraisal';
  if (v.includes('buyer')) return 'Buyer';
  if (v.includes('seller')) return 'Seller';
  if (v.includes('agent')) return 'Agent';
  if (v.includes('brokerage')) return 'Brokerage';

  return 'Other';
}


async function updateDirectoryFromCommunication(connection, body, deal, createdBy) {
  const contactEmail = cleanText(body.contact_email).toLowerCase();
  const contactPhone = cleanText(body.contact_phone);
  const contactName = cleanText(body.contact_name);
  const entityName = cleanText(body.entity_name);
  const taskResultStatus = cleanText(body.task_result_status);
  const successStatuses = ['Received', 'Completed', 'Waived', 'Not Applicable'];
  const successIncrement = successStatuses.includes(taskResultStatus) ? 1 : 0;

  const where = [];
  const params = [];

  if (contactEmail) {
    where.push('LOWER(email) = ?');
    params.push(contactEmail);
  }

  if (contactPhone) {
    where.push('phone = ?');
    params.push(contactPhone);
  }

  if (contactName) {
    where.push('(LOWER(working_contact_name) = LOWER(?) OR LOWER(display_name) = LOWER(?))');
    params.push(contactName, contactName);
  }

  if (entityName) {
    where.push('(LOWER(organization_name) = LOWER(?) OR LOWER(company_name) = LOWER(?) OR LOWER(broker_name) = LOWER(?) OR LOWER(display_name) = LOWER(?))');
    params.push(entityName, entityName, entityName, entityName);
  }

  if (!where.length) {
    return null;
  }

  const communicationSummary = [
    cleanText(body.communication_type) || 'Communication',
    contactName ? `with ${contactName}` : '',
    entityName ? `at ${entityName}` : '',
    taskResultStatus && taskResultStatus !== 'No Change' ? `result: ${taskResultStatus}` : ''
  ].filter(Boolean).join(' ');

  const note = `[${new Date().toISOString()}] ${createdBy}: ${communicationSummary}`;

  const [result] = await connection.query(
    `UPDATE dd_directory_contacts
     SET last_contacted_at = NOW(),
         clearance_touch_count = COALESCE(clearance_touch_count, 0) + 1,
         clearance_success_count = COALESCE(clearance_success_count, 0) + ?,
         clearance_notes = CASE
           WHEN clearance_notes IS NULL OR clearance_notes = '' THEN ?
           ELSE clearance_notes
         END,
         updated_at = NOW()
     WHERE ${where.join(' OR ')}`,
    [successIncrement, note, ...params]
  );

  return result.affectedRows || 0;
}


async function createCommunicationLog(publicId, body) {
  const summary = cleanText(body.summary);

  if (!summary) {
    const err = new Error('Communication summary is required');
    err.statusCode = 400;
    throw err;
  }

  const [[deal]] = await pool.query(
    `SELECT id, property_address, removed_at
     FROM dd_deals
     WHERE public_id = ?
     LIMIT 1`,
    [publicId]
  );

  if (!deal) return null;

  if (deal.removed_at) {
    const err = new Error('Cannot add communication log to a removed accepted offer');
    err.statusCode = 400;
    throw err;
  }

  const commPublicId = crypto.randomUUID();
  const createdBy = cleanText(body.created_by) || 'pilot';

  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    const [result] = await connection.query(
      `INSERT INTO dd_communication_log
       (public_id, deal_id, related_task_id, communication_type, entity_type, entity_name,
        contact_name, contact_role, contact_phone, contact_email, direction,
        communication_at, summary, confirmed_items, follow_up_needed, follow_up_due_date, task_result_status, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        commPublicId,
        deal.id,
        null,
        cleanText(body.communication_type) || 'Phone',
        cleanText(body.entity_type),
        cleanText(body.entity_name),
        cleanText(body.contact_name),
        cleanText(body.contact_role),
        cleanText(body.contact_phone),
        cleanText(body.contact_email),
        cleanText(body.direction) || 'Outgoing',
        datetimeOrNow(body.communication_at),
        summary,
        cleanText(body.confirmed_items),
        cleanText(body.follow_up_needed),
        dateOrNull(body.follow_up_due_date),
        cleanText(body.task_result_status),
        createdBy
      ]
    );

    const relatedTaskPublicId = cleanText(body.related_task_public_id);
    const taskResultStatus = cleanText(body.task_result_status);

    if (relatedTaskPublicId && taskResultStatus && taskResultStatus !== 'No Change') {
      const [[relatedTask]] = await connection.query(
        `SELECT id, task_name, status
         FROM dd_transaction_tasks
         WHERE public_id = ? AND deal_id = ?
         LIMIT 1`,
        [relatedTaskPublicId, deal.id]
      );

      if (relatedTask) {
        await connection.query(
          `UPDATE dd_communication_log
           SET related_task_id = ?
           WHERE id = ?`,
          [relatedTask.id, result.insertId]
        );

        await connection.query(
          `UPDATE dd_transaction_tasks
           SET status = ?,
               office_contact_name = COALESCE(NULLIF(?, ''), office_contact_name),
               office_contact_role = COALESCE(NULLIF(?, ''), office_contact_role),
               office_contact_phone = COALESCE(NULLIF(?, ''), office_contact_phone),
               office_contact_email = COALESCE(NULLIF(?, ''), office_contact_email),
               last_contacted_at = NOW(),
               verified_at = CASE
                 WHEN ? IN ('Received', 'Completed', 'Waived', 'Not Applicable') THEN NOW()
                 ELSE verified_at
               END,
               completed_at = CASE
                 WHEN ? IN ('Completed', 'Waived', 'Not Applicable') THEN NOW()
                 ELSE completed_at
               END,
               verification_notes = CONCAT_WS('\n', NULLIF(verification_notes, ''), ?),
               updated_by = ?
           WHERE id = ?`,
          [
            taskResultStatus,
            cleanText(body.contact_name),
            cleanText(body.contact_role),
            cleanText(body.contact_phone),
            cleanText(body.contact_email),
            taskResultStatus,
            taskResultStatus,
            `[${new Date().toISOString()}] ${createdBy}: ${summary}` + (cleanText(body.confirmed_items) ? ` Confirmed: ${cleanText(body.confirmed_items)}` : ''),
            createdBy,
            relatedTask.id
          ]
        );

        await connection.query(
          `INSERT INTO dd_deal_history
           (deal_id, event_type, event_summary, created_by)
           VALUES (?, ?, ?, ?)`,
          [
            deal.id,
            'Tracker Item Updated From Communication',
            `Communication updated tracker item "${relatedTask.task_name}" from ${relatedTask.status} to ${taskResultStatus}.`,
            createdBy
          ]
        );

        await connection.query(
          `INSERT INTO dd_usage_ledger
           (deal_id, item_type, item_id, action_type, action_summary, result_notes, created_by)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
          [
            deal.id,
            'transaction_tracker_item',
            relatedTask.id,
            'updated_from_communication',
            `Tracker item updated from communication log.`,
            summary,
            createdBy
          ]
        );
      }
    }

    await updateDirectoryFromCommunication(connection, body, deal, createdBy);

    const followUpNeeded = cleanText(body.follow_up_needed);

    if (followUpNeeded) {
      const followUpTaskPublicId = crypto.randomUUID();

      const [followUpResult] = await connection.query(
        `INSERT INTO dd_transaction_tasks
         (public_id, deal_id, category, task_name, waiting_on_entity_type, waiting_on_name,
          office_contact_name, office_contact_role, office_contact_phone, office_contact_email,
          status, priority, due_date, verification_notes, notes, created_by, updated_by)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          followUpTaskPublicId,
          deal.id,
          categoryFromEntityType(body.entity_type),
          followUpNeeded,
          cleanText(body.entity_type),
          cleanText(body.entity_name),
          cleanText(body.contact_name),
          cleanText(body.contact_role),
          cleanText(body.contact_phone),
          cleanText(body.contact_email),
          'Waiting',
          cleanText(body.follow_up_due_date) ? 'High' : 'Normal',
          dateOrNull(body.follow_up_due_date),
          cleanText(body.confirmed_items),
          `Created automatically from communication log: ${summary}`,
          createdBy,
          createdBy
        ]
      );

      await connection.query(
        `INSERT INTO dd_deal_history
         (deal_id, event_type, event_summary, created_by)
         VALUES (?, ?, ?, ?)`,
        [
          deal.id,
          'Follow-Up Created From Communication',
          `Follow-up tracker item created: ${followUpNeeded}`,
          createdBy
        ]
      );

      await connection.query(
        `INSERT INTO dd_usage_ledger
         (deal_id, item_type, item_id, action_type, action_summary, result_notes, created_by)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [
          deal.id,
          'transaction_tracker_item',
          followUpResult.insertId,
          'created_from_communication',
          `Follow-up tracker item created from communication log.`,
          followUpNeeded,
          createdBy
        ]
      );
    }

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        deal.id,
        'Communication Logged',
        `Communication logged with ${cleanText(body.contact_name) || cleanText(body.entity_name) || cleanText(body.entity_type) || 'transaction contact'}.`,
        createdBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_usage_ledger
       (deal_id, item_type, item_id, action_type, action_summary, result_notes, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        deal.id,
        'communication_log',
        result.insertId,
        'created',
        'Communication log entry created.',
        summary,
        createdBy
      ]
    );

    await connection.commit();

    const [[row]] = await pool.query(
      `SELECT public_id, communication_type, entity_type, entity_name, contact_name, contact_role,
              contact_phone, contact_email, direction, communication_at, summary, confirmed_items,
              follow_up_needed, follow_up_due_date, created_by, created_at
       FROM dd_communication_log
       WHERE id = ?
       LIMIT 1`,
      [result.insertId]
    );

    return row;
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}



const MANAGER_CHAT_INSTRUCTIONS = `You are Manager Chat for Accepted Offer to Close.

You answer managers' questions about accepted-offer files using only the live database context provided.

Rules:
- Be direct and operational.
- Answer the specific question asked first. Do not over-explain unless needed.
- Use the recent chat history to resolve pronouns like his, her, their, that agent, that attorney, or that deal.
- If a pronoun is still ambiguous, ask a short clarifying question instead of guessing.
- Do not invent missing facts.
- Before saying a person, agent, attorney, lender, inspector, appraiser, title contact, buyer, or seller is not on file, check the deal_parties records in the context.
- For license-number questions, match the license to the exact person and role being asked about. Never use the seller agent license as the purchaser agent license, or vice versa.
- If the requested person has no license number shown, say that clearly. You may separately mention that another party has a license only if it helps avoid confusion.
- If the record does not show something after checking deal_parties and deal summary fields, say it is not shown in the file.
- Do not provide legal advice.
- Do not say an item is complete unless the transaction tracker, communication log, or status shows it.
- Treat this as brokerage transaction coordination from accepted offer through closing follow-through.
- Use the words "accepted offer" where helpful.
- If a user asks what to do next, prioritize blockers, waiting-on items, due dates, attorney handoff, lender follow-up, inspection, appraisal, title, and communication history.
- This chat is read-only. Do not claim to change records.`;

async function getManagerChatContext() {
  const dashboard = await getDashboard();

  const [deals] = await pool.query(
    `SELECT
       d.id,
       d.public_id,
       d.accepted_offer_date,
       d.mls_number,
       d.property_address,
       d.property_type,
       d.transaction_status,
       d.next_action,
       d.property_condition_statement_status,
       d.additional_terms,
       d.created_at,
       d.updated_at,
       (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'seller' LIMIT 1) AS seller_name,
       (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'purchaser' LIMIT 1) AS purchaser_name,
       (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'seller_attorney' LIMIT 1) AS seller_attorney,
       (SELECT p.email FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'seller_attorney' LIMIT 1) AS seller_attorney_email,
       (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'purchaser_attorney' LIMIT 1) AS purchaser_attorney,
       (SELECT p.email FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'purchaser_attorney' LIMIT 1) AS purchaser_attorney_email,
       (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'seller_agent' LIMIT 1) AS seller_agent,
       (SELECT p.email FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'seller_agent' LIMIT 1) AS seller_agent_email,
       (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'purchaser_agent' LIMIT 1) AS purchaser_agent,
       (SELECT p.email FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'purchaser_agent' LIMIT 1) AS purchaser_agent_email,
       (SELECT p.broker_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'purchaser_agent' LIMIT 1) AS purchaser_agent_broker,
       (SELECT p.phone FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'purchaser_agent' LIMIT 1) AS purchaser_agent_phone,
       (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'lender' LIMIT 1) AS lender,
       (SELECT p.email FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'lender' LIMIT 1) AS lender_email
     FROM dd_deals d
     WHERE d.removed_at IS NULL
     ORDER BY d.created_at DESC
     LIMIT 30`
  );

  const [dealParties] = await pool.query(
    `SELECT
       d.public_id AS deal_public_id,
       d.property_address,
       p.role_key,
       p.display_name,
       p.legal_address,
       p.broker_name,
       p.license_number,
       p.phone,
       p.email,
       p.sort_order
     FROM dd_deal_parties p
     JOIN dd_deals d ON d.id = p.deal_id
     WHERE d.removed_at IS NULL
     ORDER BY d.created_at DESC, p.sort_order, p.role_key`
  );

  const [tasks] = await pool.query(
    `SELECT
       d.public_id AS deal_public_id,
       d.property_address,
       t.public_id,
       t.category,
       t.task_name,
       t.waiting_on_entity_type,
       t.waiting_on_name,
       t.office_contact_name,
       t.office_contact_role,
       t.status,
       t.priority,
       t.due_date,
       t.last_contacted_at,
       t.verified_at,
       t.completed_at,
       t.verification_notes,
       t.notes,
       t.created_at,
       t.updated_at
     FROM dd_transaction_tasks t
     JOIN dd_deals d ON d.id = t.deal_id
     WHERE d.removed_at IS NULL
     ORDER BY
       CASE t.status
         WHEN 'Blocked' THEN 1
         WHEN 'Waiting' THEN 2
         WHEN 'In Progress' THEN 3
         WHEN 'Received' THEN 4
         WHEN 'Completed' THEN 8
         WHEN 'Waived' THEN 9
         ELSE 5
       END,
       t.due_date IS NULL,
       t.due_date,
       t.updated_at DESC
     LIMIT 120`
  );

  const [communications] = await pool.query(
    `SELECT
       d.public_id AS deal_public_id,
       d.property_address,
       c.communication_type,
       c.entity_type,
       c.entity_name,
       c.contact_name,
       c.contact_role,
       c.direction,
       c.communication_at,
       c.summary,
       c.confirmed_items,
       c.follow_up_needed,
       c.follow_up_due_date,
       c.task_result_status,
       c.created_by,
       c.created_at
     FROM dd_communication_log c
     JOIN dd_deals d ON d.id = c.deal_id
     WHERE d.removed_at IS NULL
     ORDER BY c.communication_at DESC, c.id DESC
     LIMIT 120`
  );

  const [reviews] = await pool.query(
    `SELECT
       d.public_id AS deal_public_id,
       d.property_address,
       g.title,
       g.item_status,
       LEFT(g.generated_text, 1200) AS review_excerpt,
       g.created_at
     FROM dd_generated_items g
     JOIN dd_deals d ON d.id = g.deal_id
     WHERE d.removed_at IS NULL
     ORDER BY g.created_at DESC, g.id DESC
     LIMIT 30`
  );

  return {
    generated_at: new Date().toISOString(),
    dashboard,
    active_deals: deals,
    deal_parties: dealParties,
    transaction_tasks: tasks,
    communication_log: communications,
    offer_reviews: reviews
  };
}

function callManagerChatOpenAi(question, context, history) {
  return new Promise((resolve, reject) => {
    const apiKey = process.env.OPENAI_API_KEY;
    const model = process.env.OPENAI_MODEL || 'gpt-5.5';

    if (!apiKey || !apiKey.startsWith('sk-')) {
      reject(new Error('OPENAI_API_KEY is missing or invalid'));
      return;
    }

    const prompt = [
      'Recent manager chat history, newest last:',
      JSON.stringify(Array.isArray(history) ? history : [], null, 2),
      '',
      'Current manager question:',
      question,
      '',
      'Live Accepted Offer to Close database context:',
      JSON.stringify(context, null, 2)
    ].join('\n');

    const payload = JSON.stringify({
      model,
      instructions: MANAGER_CHAT_INSTRUCTIONS,
      input: prompt,
      store: false
    });

    const req = https.request({
      hostname: 'api.openai.com',
      path: '/v1/responses',
      method: 'POST',
      timeout: 45000,
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      }
    }, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch (err) {
          reject(new Error('OpenAI returned a non-JSON response'));
          return;
        }

        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(parsed.error && parsed.error.message ? parsed.error.message : 'OpenAI request failed'));
          return;
        }

        let answer = '';
        if (typeof parsed.output_text === 'string') {
          answer = parsed.output_text.trim();
        } else if (typeof extractOpenAiText === 'function') {
          answer = extractOpenAiText(parsed);
        }

        if (!answer) {
          reject(new Error('Manager Chat did not return an answer'));
          return;
        }

        resolve({
          answer,
          model,
          response_id: parsed.id || null
        });
      });
    });

    req.on('timeout', () => {
      req.destroy(new Error('Manager Chat request timed out'));
    });

    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}


function normalizeManagerLookupText(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/jonus/g, 'jonas')
    .replace(/buyer'?s/g, 'buyer')
    .replace(/seller'?s/g, 'seller')
    .replace(/purchaser'?s/g, 'purchaser')
    .replace(/[^a-z0-9]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function managerRoleLabel(roleKey) {
  const labels = {
    seller: 'Seller',
    purchaser: 'Purchaser',
    seller_attorney: 'Seller Attorney',
    purchaser_attorney: 'Purchaser Attorney',
    seller_agent: 'Seller Agent / Listing Agent',
    purchaser_agent: "Purchaser Agent / Buyer's Agent",
    lender: 'Lender'
  };

  return labels[roleKey] || String(roleKey || 'Party').replace(/_/g, ' ');
}

function inferManagerRequestedRole(question) {
  const q = normalizeManagerLookupText(question);

  if (q.includes('agent')) {
    if (q.includes('buyer') || q.includes('purchaser')) return 'purchaser_agent';
    if (q.includes('seller') || q.includes('listing')) return 'seller_agent';
  }

  if (q.includes('attorney') || q.includes('lawyer')) {
    if (q.includes('buyer') || q.includes('purchaser')) return 'purchaser_attorney';
    if (q.includes('seller')) return 'seller_attorney';
  }

  if (q.includes('lender') || q.includes('mortgage')) return 'lender';
  if (q.includes('buyer') || q.includes('purchaser')) return 'purchaser';
  if (q.includes('seller')) return 'seller';

  return null;
}

function managerQuestionWantsLicense(question) {
  const q = normalizeManagerLookupText(question);
  return q.includes('license') || q.includes('licence') || q.includes('lic number') || q.includes('lic no');
}

function managerQuestionWantsPartyLookup(question) {
  const q = normalizeManagerLookupText(question);

  return (
    q.includes('who is') ||
    q.includes('who are') ||
    q.includes('agent') ||
    q.includes('attorney') ||
    q.includes('lawyer') ||
    q.includes('lender') ||
    q.includes('license') ||
    q.includes('licence') ||
    q.includes('phone') ||
    q.includes('email')
  );
}

function findManagerDealIds(question, context) {
  const q = normalizeManagerLookupText(question);
  const deals = Array.isArray(context.active_deals) ? context.active_deals : [];
  const matches = [];

  for (const deal of deals) {
    const address = normalizeManagerLookupText(deal.property_address);
    const mls = normalizeManagerLookupText(deal.mls_number);

    if (!address && !mls) continue;

    const addressWords = address.split(' ').filter(w => w.length >= 4);
    const hasAddressWord = addressWords.some(w => q.includes(w));
    const hasMls = mls && q.includes(mls);

    if (hasAddressWord || hasMls) {
      matches.push(deal.public_id);
    }
  }

  return [...new Set(matches)];
}

function findManagerMentionedParty(question, context, history) {
  const parties = Array.isArray(context.deal_parties) ? context.deal_parties : [];
  const sources = [question];

  if (Array.isArray(history)) {
    for (let i = history.length - 1; i >= 0; i--) {
      sources.push(history[i].answer || '');
      sources.push(history[i].question || '');
    }
  }

  const normalizedSources = sources.map(normalizeManagerLookupText).filter(Boolean);

  for (const source of normalizedSources) {
    for (const party of parties) {
      const name = normalizeManagerLookupText(party.display_name);
      if (name && name.length >= 3 && source.includes(name)) {
        return party;
      }
    }
  }

  return null;
}

function formatManagerPartyAnswer(party, options = {}) {
  const includeLicense = options.includeLicense !== false;
  const lines = [];

  lines.push(`${managerRoleLabel(party.role_key)} for ${party.property_address || 'this accepted offer'}:`);
  lines.push(`Name: ${party.display_name || 'Not shown in the file.'}`);

  if (party.broker_name) lines.push(`Broker: ${party.broker_name}`);
  if (includeLicense && String(party.role_key || '').includes('agent')) {
    lines.push(`License Number: ${party.license_number || 'Not shown in the file.'}`);
  }
  if (party.phone) lines.push(`Phone: ${party.phone}`);
  if (party.email) lines.push(`Email: ${party.email}`);

  return lines.join('\n');
}

function answerManagerExactPartyQuestion(question, context, history) {
  if (!managerQuestionWantsPartyLookup(question)) return null;

  const parties = Array.isArray(context.deal_parties) ? context.deal_parties : [];
  if (!parties.length) return null;

  const wantsLicense = managerQuestionWantsLicense(question);
  const requestedRole = inferManagerRequestedRole(question);
  const dealIds = findManagerDealIds(question, context);
  const mentionedParty = findManagerMentionedParty(question, context, history);

  if (wantsLicense && mentionedParty) {
    const license = mentionedParty.license_number;

    if (license) {
      return `${mentionedParty.display_name} is the ${managerRoleLabel(mentionedParty.role_key)} for ${mentionedParty.property_address || 'this accepted offer'}.\nLicense Number: ${license}`;
    }

    let extra = '';
    if (mentionedParty.role_key === 'purchaser_agent') {
      const sameDealSellerAgent = parties.find(p =>
        p.deal_public_id === mentionedParty.deal_public_id &&
        p.role_key === 'seller_agent' &&
        p.license_number
      );

      if (sameDealSellerAgent) {
        extra = `\n\nDo not use ${sameDealSellerAgent.display_name}'s license number for this answer. ${sameDealSellerAgent.display_name} is the seller/listing agent, which is a different party.`;
      }
    }

    return `No. The file does not show a license number for ${mentionedParty.display_name}, the ${managerRoleLabel(mentionedParty.role_key)} for ${mentionedParty.property_address || 'this accepted offer'}.${extra}`;
  }

  let matches = parties.slice();

  if (requestedRole) {
    matches = matches.filter(p => p.role_key === requestedRole);
  }

  if (dealIds.length) {
    matches = matches.filter(p => dealIds.includes(p.deal_public_id));
  }

  if (wantsLicense && requestedRole && matches.length) {
    return matches.map(p => {
      if (p.license_number) {
        return `${p.display_name || managerRoleLabel(p.role_key)} — ${managerRoleLabel(p.role_key)} for ${p.property_address || 'this accepted offer'}\nLicense Number: ${p.license_number}`;
      }

      return `${p.display_name || managerRoleLabel(p.role_key)} — ${managerRoleLabel(p.role_key)} for ${p.property_address || 'this accepted offer'}\nLicense Number: Not shown in the file.`;
    }).join('\n\n');
  }

  if (requestedRole && matches.length) {
    return matches.map(p => formatManagerPartyAnswer(p, { includeLicense: true })).join('\n\n');
  }

  if (wantsLicense && !requestedRole && !mentionedParty) {
    return 'Which person or role do you mean? For license questions, ask for a specific agent, such as purchaser agent or seller agent, so I do not use the wrong party record.';
  }

  return null;
}


async function logDevAgentAudit(data) {
  try {
    await pool.query(
      `INSERT INTO dd_dev_agent_audit 
       (public_id, user_prompt, tool_name, tool_args_json, tool_result_preview, allowed, blocked_reason, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        data.public_id || crypto.randomUUID(),
        data.user_prompt || null,
        data.tool_name,
        JSON.stringify(data.tool_args || {}),
        data.result_preview || null,
        data.allowed ? 1 : 0,
        data.blocked_reason || null,
        data.created_by || 'dev-agent'
      ]
    );
  } catch (err) {
    console.error('Audit logging failed:', err.message);
  }
}

function validateProposedJsSyntax(name, args) {
  const fs = require('fs');
  const path = require('path');
  const vm = require('vm');

  const filePath = args.file_path || '';
  const isJs = filePath.endsWith('.js');
  const isJson = filePath.endsWith('.json');
  if (!isJs && !isJson) return;

  let contentToValidate = '';
  const ROOT_DIR = path.resolve(__dirname, '..');
  const resolvedPath = path.isAbsolute(filePath)
    ? path.resolve(filePath)
    : path.resolve(ROOT_DIR, filePath);

  if (!resolvedPath.startsWith(ROOT_DIR)) {
    throw new Error(`Access Denied: Path '${filePath}' is outside the project workspace.`);
  }

  if (name === 'write_file') {
    contentToValidate = args.content || '';
  } else if (name === 'replace_file_content') {
    if (!fs.existsSync(resolvedPath)) {
      throw new Error(`File not found: ${filePath}`);
    }
    const fileContent = fs.readFileSync(resolvedPath, 'utf8');
    const { target_content, replacement_content } = args;
    if (target_content === undefined || replacement_content === undefined) {
      throw new Error("Missing target_content or replacement_content");
    }
    if (!fileContent.includes(target_content)) {
      throw new Error(`Target content not found in file ${filePath}.`);
    }
    contentToValidate = fileContent.split(target_content).join(replacement_content);
  }

  if (isJs) {
    try {
      new vm.Script(contentToValidate);
    } catch (err) {
      throw new Error(`Syntax Error in JavaScript code: ${err.message}`);
    }
  } else if (isJson) {
    try {
      JSON.parse(contentToValidate);
    } catch (err) {
      throw new Error(`Syntax Error in JSON content: ${err.message}`);
    }
  }
}

async function callDevAgentOpenAi(prompt, history = []) {
  const apiKey = process.env.OPENAI_API_KEY;
  const model = process.env.OPENAI_MODEL || 'gpt-4o'; // Standard model for tool calling
  const auditPublicId = crypto.randomUUID();

  const messages = [
    { role: 'system', content: DEV_AGENT_INSTRUCTIONS },
    ...history,
    { role: 'user', content: prompt }
  ];

  // We use standard chat completions for tool support
  const url = 'https://api.openai.com/v1/chat/completions';
  
  async function runCompletion(msgs) {
    const payload = JSON.stringify({
      model,
      messages: msgs,
      tools: DEV_AGENT_TOOLS,
      tool_choice: 'auto'
    });

    const response = await new Promise((resolve, reject) => {
      const req = https.request(url, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload)
        }
      }, (res) => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
          try {
            const parsed = JSON.parse(body);
            if (res.statusCode >= 200 && res.statusCode < 300) resolve(parsed);
            else reject(new Error(parsed.error?.message || `HTTP ${res.statusCode}`));
          } catch (err) {
            reject(new Error('Invalid JSON from OpenAI'));
          }
        });
      });
      req.on('error', reject);
      req.write(payload);
      req.end();
    });

    const message = response.choices[0].message;
    if (message.tool_calls) {
      msgs.push(message);
      for (const toolCall of message.tool_calls) {
        const name = toolCall.function.name;
        const args = JSON.parse(toolCall.function.arguments);
        let result;
        let allowed = true;
        let blocked_reason = null;

        try {
          // Pre-validation syntax check for code changes (V3 Self-Healing)
          if (['write_file', 'replace_file_content'].includes(name)) {
            validateProposedJsSyntax(name, args);
          }

          // Check if this tool requires human-in-the-loop approval (V3 Deletion included)
          const requiresApproval = ['write_file', 'replace_file_content', 'run_command', 'delete_path'].includes(name);
          if (requiresApproval) {
            // Wait for developer approval, passing the user prompt as context
            await requestDeveloperApproval(name, args, prompt);
          }

          if (typeof devAgentTools[name] === 'function') {
            // Check if tool needs pool
            if (name.startsWith('mysql_') || name.startsWith('get_')) {
              result = await devAgentTools[name](args, pool);
            } else {
              result = await devAgentTools[name](args);
            }
          } else {
            throw new Error(`Tool ${name} not implemented`);
          }
        } catch (err) {
          allowed = false;
          blocked_reason = err.message;
          result = `Error: ${err.message}`;
        }

        // Audit log
        await logDevAgentAudit({
          public_id: auditPublicId,
          user_prompt: prompt,
          tool_name: name,
          tool_args: args,
          result_preview: typeof result === 'string' ? result.slice(0, 500) : JSON.stringify(result).slice(0, 500),
          allowed,
          blocked_reason,
          created_by: 'dev-agent'
        });

        msgs.push({
          role: 'tool',
          tool_call_id: toolCall.id,
          name: name,
          content: typeof result === 'string' ? result : JSON.stringify(result)
        });
      }
      return runCompletion(msgs);
    }

    return message.content;
  }

  const finalContent = await runCompletion(messages);
  return { answer: finalContent, audit_id: auditPublicId };
}

async function answerManagerChat(body) {
  const question = cleanText(body.question);

  if (!question) {
    const err = new Error('Question is required');
    err.statusCode = 400;
    throw err;
  }

  if (question.length > 1200) {
    const err = new Error('Question is too long');
    err.statusCode = 400;
    throw err;
  }

  const createdBy = cleanText(body.created_by) || 'manager';
  const context = await getManagerChatContext();
  const rawHistory = Array.isArray(body.history) ? body.history : [];
  const history = rawHistory.slice(-8).map(item => ({
    question: cleanText(item.question).slice(0, 600),
    answer: cleanText(item.answer).slice(0, 1200)
  })).filter(item => item.question || item.answer);

  const exactAnswer = answerManagerExactPartyQuestion(question, context, history);

  const ai = exactAnswer
    ? {
        answer: exactAnswer,
        model: 'exact-field-lookup'
      }
    : await callManagerChatOpenAi(question, context, history);
  const publicId = crypto.randomUUID();

  await pool.query(
    `INSERT INTO dd_manager_chat_log
     (public_id, question, answer, model, created_by)
     VALUES (?, ?, ?, ?, ?)`,
    [publicId, question, ai.answer, ai.model, createdBy]
  );

  return {
    public_id: publicId,
    question,
    answer: ai.answer
  };
}



async function getSmartManagerSnapshot() {
  const [deals] = await pool.query(
    `SELECT
       d.*,
       f.purchase_price,
       f.seller_concession,
       f.contract_deposit,
       f.mortgage_amount,
       f.cash_at_closing,
       f.total_price,
       f.commission_paid_by_seller,
       f.commission_paid_by_purchaser,
       f.contract_date_text,
       f.closing_date_text
     FROM dd_deals d
     LEFT JOIN dd_deal_financials f ON f.deal_id = d.id
     WHERE d.removed_at IS NULL
     ORDER BY d.created_at DESC`
  );

  const [parties] = await pool.query(
    `SELECT
       d.public_id AS deal_public_id,
       d.property_address,
       p.*
     FROM dd_deal_parties p
     JOIN dd_deals d ON d.id = p.deal_id
     WHERE d.removed_at IS NULL
     ORDER BY d.created_at DESC, p.sort_order, p.role_key`
  );

  const [clearance] = await pool.query(
    `SELECT
       d.public_id AS deal_public_id,
       d.property_address,
       t.*
     FROM dd_transaction_tasks t
     JOIN dd_deals d ON d.id = t.deal_id
     WHERE d.removed_at IS NULL
     ORDER BY d.created_at DESC, t.status, t.due_date IS NULL, t.due_date, t.updated_at DESC`
  );

  const [communications] = await pool.query(
    `SELECT
       d.public_id AS deal_public_id,
       d.property_address,
       c.*
     FROM dd_communication_log c
     JOIN dd_deals d ON d.id = c.deal_id
     WHERE d.removed_at IS NULL
     ORDER BY c.communication_at DESC, c.id DESC
     LIMIT 500`
  );

  const [reviews] = await pool.query(
    `SELECT
       d.public_id AS deal_public_id,
       d.property_address,
       g.public_id,
       g.item_type,
       g.title,
       g.item_status,
       LEFT(g.generated_text, 2500) AS generated_text_excerpt,
       g.created_by,
       g.created_at
     FROM dd_generated_items g
     JOIN dd_deals d ON d.id = g.deal_id
     WHERE d.removed_at IS NULL
     ORDER BY g.created_at DESC, g.id DESC
     LIMIT 100`
  );

  const activeDeals = deals.filter(d => !['Closed', 'Final', 'Removed'].includes(String(d.transaction_status || '')));

  const totals = activeDeals.reduce((acc, deal) => {
    const purchase = Number(deal.purchase_price || deal.total_price || 0);
    const deposit = Number(deal.contract_deposit || 0);
    const mortgage = Number(deal.mortgage_amount || 0);

    acc.purchase_price += Number.isFinite(purchase) ? purchase : 0;
    acc.contract_deposit += Number.isFinite(deposit) ? deposit : 0;
    acc.mortgage_amount += Number.isFinite(mortgage) ? mortgage : 0;

    return acc;
  }, {
    purchase_price: 0,
    contract_deposit: 0,
    mortgage_amount: 0
  });

  const openClearance = clearance.filter(t => ['Waiting', 'In Progress', 'Blocked'].includes(String(t.status || '')));
  const blockedClearance = clearance.filter(t => String(t.status || '') === 'Blocked');

  return {
    generated_at: new Date().toISOString(),
    summary: {
      active_contract_count: activeDeals.length,
      visible_deal_count: deals.length,
      open_clearance_count: openClearance.length,
      blocked_clearance_count: blockedClearance.length,
      totals
    },
    active_deals: activeDeals,
    all_visible_deals: deals,
    parties,
    clearance_items: clearance,
    communications,
    offer_reviews: reviews
  };
}

function managerMoney(value) {
  const n = Number(value || 0);
  return n.toLocaleString('en-US', {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: 0
  });
}

function normalizeSmartManagerQuestion(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/contracs/g, 'contracts')
    .replace(/jonus/g, 'jonas')
    .replace(/buyers/g, 'buyer')
    .replace(/sellers/g, 'seller')
    .replace(/purchasers/g, 'purchaser')
    .replace(/[^a-z0-9 ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}


function parseManagerCommissionAmount(deal) {
  const raw = String(deal.commission_paid_by_seller || '').trim();
  const price = Number(deal.purchase_price || deal.total_price || 0);

  if (!raw) {
    return {
      amount: 0,
      status: 'not_shown',
      pct: null,
      note: 'purchase price shown, but no seller-paid commission field shown'
    };
  }

  const amountMatches = raw.match(/(?:\$?\s*)(\d{1,3}(?:,\d{3})+(?:\.\d{2})|\d+\.\d{2})/g) || [];
  const amounts = amountMatches
    .map(v => Number(String(v).replace(/[$,\s]/g, '')))
    .filter(v => Number.isFinite(v) && v > 1000);

  if (amounts.length) {
    return {
      amount: amounts[amounts.length - 1],
      status: 'shown_amount',
      pct: null,
      note: raw
    };
  }

  const pctMatch = raw.match(/(\d+(?:\.\d+)?)\s*%/);
  if (pctMatch && Number.isFinite(price) && price > 0) {
    const pct = Number(pctMatch[1]);
    return {
      amount: Math.round(price * pct) / 100,
      status: 'calculated_from_percent',
      pct,
      note: raw
    };
  }

  return {
    amount: 0,
    status: 'unable_to_calculate',
    pct: null,
    note: raw || 'commission not calculable from current file data'
  };
}

function buildCommissionOutstandingAnswer(snapshot) {
  const sortedDeals = [...snapshot.active_deals].sort((a, b) => {
    const at = new Date(a.created_at || a.accepted_offer_date || 0).getTime();
    const bt = new Date(b.created_at || b.accepted_offer_date || 0).getTime();
    return at - bt;
  });

  const rows = sortedDeals.map((deal) => {
    const parsed = parseManagerCommissionAmount(deal);
    return {
      address: deal.property_address,
      price: Number(deal.purchase_price || deal.total_price || 0),
      commission_text: String(deal.commission_paid_by_seller || '').trim(),
      amount: parsed.amount,
      status: parsed.status,
      pct: parsed.pct,
      note: parsed.note
    };
  });

  const included = rows.filter(row => row.amount > 0);
  const missing = rows.filter(row => row.amount <= 0);
  const total = included.reduce((sum, row) => sum + row.amount, 0);

  const lines = [
    `Estimated seller-paid commissions outstanding from active accepted-offer files: ${managerMoney(total)}.`,
    '',
    'Included / calculable from the deal sheets:',
    ''
  ];

  included.forEach((row, idx) => {
    if (row.status === 'shown_amount') {
      lines.push(`${idx + 1}. ${row.address} — commission shown as ${managerMoney(row.amount)}`);
    } else if (row.pct) {
      lines.push(`${idx + 1}. ${row.address} — ${managerMoney(row.price)} x ${row.pct}% = ${managerMoney(row.amount)}`);
    } else {
      lines.push(`${idx + 1}. ${row.address} — ${managerMoney(row.amount)}`);
    }
  });

  if (missing.length) {
    lines.push('', 'Not included because seller-paid commission is not shown on the current deal sheet data:', '');
    missing.forEach((row, idx) => {
      lines.push(`${included.length + idx + 1}. ${row.address} — ${row.note}.`);
    });
  }

  lines.push(
    '',
    'Important: I am treating outstanding as expected commission from active deal-sheet data. I do not see a payment/receipt ledger showing whether any commission has actually been paid, received, split, or closed.'
  );

  return lines.join('\n');
}

function smartExactAnswer(question, snapshot) {
  const q = normalizeSmartManagerQuestion(question);


  if (
    (q.includes('commission') || q.includes('commision') || q.includes('commsion') || q.includes('commsions')) &&
    (q.includes('outstanding') || q.includes('total') || q.includes('owed') || q.includes('due'))
  ) {
    return buildCommissionOutstandingAnswer(snapshot);
  }


  if ((q.includes('total') || q.includes('sum')) && (q.includes('contract') || q.includes('deal') || q.includes('offer'))) {
    const lines = snapshot.active_deals.map((deal, index) => {
      const amount = Number(deal.purchase_price || deal.total_price || 0);
      return `${index + 1}. ${deal.property_address} — ${managerMoney(amount)}`;
    });

    return [
      `There are ${snapshot.summary.active_contract_count} active accepted-offer contracts.`,
      '',
      `Total purchase price: ${managerMoney(snapshot.summary.totals.purchase_price)}`,
      `Total contract deposits: ${managerMoney(snapshot.summary.totals.contract_deposit)}`,
      `Total mortgage amount shown: ${managerMoney(snapshot.summary.totals.mortgage_amount)}`,
      '',
      'Active contracts included:',
      ...lines
    ].join('\n');
  }

  if ((q.includes('list') || q.includes('show')) && (q.includes('active') || q.includes('contract') || q.includes('deal') || q.includes('offer'))) {
    return [
      `There are ${snapshot.summary.active_contract_count} active accepted-offer contracts:`,
      '',
      ...snapshot.active_deals.map((deal, index) => {
        const amount = Number(deal.purchase_price || deal.total_price || 0);
        return `${index + 1}. ${deal.property_address} — MLS ${deal.mls_number || 'not shown'} — ${managerMoney(amount)} — ${deal.transaction_status || 'Status not shown'}`;
      })
    ].join('\n');
  }

  return null;
}

function callSmartManagerOpenAI(question, snapshot, history) {
  return new Promise((resolve, reject) => {
    const apiKey = process.env.OPENAI_API_KEY;
    const model = process.env.OPENAI_MODEL || 'gpt-5.5';

    if (!apiKey || !apiKey.startsWith('sk-')) {
      reject(new Error('OPENAI_API_KEY is missing or invalid'));
      return;
    }

    const instructions = `You are Manager Chat for Accepted Offer to Close.

You are a live brokerage transaction manager assistant.
You must answer from the MySQL snapshot provided in this request.
The database snapshot is refreshed on every question.
Do not invent facts.
If a field is missing, say it is not shown in the file.
For totals, counts, prices, deposits, mortgages, names, attorneys, agents, license numbers, phone numbers, emails, statuses, clearance items, and communications, use the database fields exactly.
If the manager asks a broad question, analyze all active accepted-offer files, not just one.
If the manager asks about all contracts, include all active accepted-offer contracts.
If the manager asks about a specific deal, use address, MLS, party name, attorney, or agent clues to identify it.
Be useful, direct, and operational.
This chat is read-only. Do not claim to update records.`;

    const prompt = [
      'Recent chat history:',
      JSON.stringify(Array.isArray(history) ? history.slice(-8) : [], null, 2),
      '',
      'Manager question:',
      question,
      '',
      'LIVE MYSQL SNAPSHOT:',
      JSON.stringify(snapshot, null, 2)
    ].join('\n');

    const payload = JSON.stringify({
      model,
      instructions,
      input: prompt,
      store: false
    });

    const req = https.request({
      hostname: 'api.openai.com',
      path: '/v1/responses',
      method: 'POST',
      timeout: 60000,
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      }
    }, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch (err) {
          reject(new Error('OpenAI returned non-JSON'));
          return;
        }

        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(parsed.error && parsed.error.message ? parsed.error.message : 'OpenAI request failed'));
          return;
        }

        let answer = '';

        if (typeof parsed.output_text === 'string') {
          answer = parsed.output_text.trim();
        } else if (Array.isArray(parsed.output)) {
          for (const item of parsed.output) {
            if (Array.isArray(item.content)) {
              for (const c of item.content) {
                if (c.text) answer += c.text;
              }
            }
          }
          answer = answer.trim();
        }

        if (!answer) {
          reject(new Error('No answer returned'));
          return;
        }

        resolve({
          answer,
          model
        });
      });
    });

    req.on('timeout', () => req.destroy(new Error('Manager Chat timed out')));
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

async function answerSmartManagerChat(body) {
  const question = cleanText(body.question);

  if (!question) {
    const err = new Error('Question is required');
    err.statusCode = 400;
    throw err;
  }

  const snapshot = await getSmartManagerSnapshot();
  const exact = smartExactAnswer(question, snapshot);

  if (exact) {
    return {
      public_id: crypto.randomUUID(),
      question,
      answer: exact,
      mode: 'live-sql-exact',
      snapshot_time: snapshot.generated_at
    };
  }

  const ai = await callSmartManagerOpenAI(question, snapshot, Array.isArray(body.history) ? body.history : []);

  return {
    public_id: crypto.randomUUID(),
    question,
    answer: ai.answer,
    mode: 'live-sql-ai',
    snapshot_time: snapshot.generated_at
  };
}


function classifyManagerChatQuestion(question) {
  const q = normalizeSmartManagerQuestion
    ? normalizeSmartManagerQuestion(question)
    : String(question || '').toLowerCase();

  if (q.includes('commission') || q.includes('commision') || q.includes('commsion') || q.includes('commsions')) {
    return 'commission_question';
  }

  if ((q.includes('total') || q.includes('sum')) && (q.includes('contract') || q.includes('deal') || q.includes('offer') || q.includes('purchase'))) {
    return 'contract_total_question';
  }

  if (q.includes('attorney') || q.includes('lawyer') || q.includes('law office') || q.includes('firm')) {
    return 'attorney_question';
  }

  if (q.includes('agent') || q.includes('broker')) {
    return 'agent_question';
  }

  if (q.includes('clearance') || q.includes('waiting') || q.includes('blocked') || q.includes('stuck')) {
    return 'clearance_status_question';
  }

  if (q.includes('inspection')) {
    return 'inspection_question';
  }

  if (q.includes('deposit')) {
    return 'deposit_question';
  }

  if (q.includes('closing') || q.includes('contract date')) {
    return 'date_question';
  }

  if (q.includes('missing') || q.includes('not shown') || q.includes('hole') || q.includes('incomplete')) {
    return 'data_quality_question';
  }

  return 'general_manager_question';
}

async function logManagerChatQuestion(entry) {
  try {
    const question = cleanText(entry.question || '');
    if (!question) return;

    const answer = entry.answer ? String(entry.answer) : null;
    const answerPreview = answer ? answer.slice(0, 500) : null;
    const matchedRule = entry.matched_rule || classifyManagerChatQuestion(question);

    await pool.query(
      `INSERT INTO dd_manager_chat_questions
       (public_id, question, answer, answer_preview, answer_mode, matched_rule, snapshot_time, error_message, duration_ms, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        crypto.randomUUID(),
        question,
        answer,
        answerPreview,
        entry.answer_mode || null,
        matchedRule,
        entry.snapshot_time || null,
        entry.error_message || null,
        entry.duration_ms || null,
        cleanText(entry.created_by || '') || 'manager'
      ]
    );
  } catch (logErr) {
    console.error('Manager Chat tracking failed:', logErr.message);
  }
}


function normalizeClearanceControlState(value, currentStatus) {
  const v = String(value || '').toLowerCase().replace(/[^a-z_]/g, '_');

  if (['complete', 'completed', 'cleared', 'closed', 'done'].includes(v)) return 'complete';
  if (['needs_followup', 'needs_follow_up', 'followup', 'follow_up', 'blocked'].includes(v)) return 'needs_followup';
  if (['not_applicable', 'na', 'n_a', 'notapplicable'].includes(v)) return 'not_applicable';
  if (['open', 'waiting', 'pending', 'in_progress'].includes(v)) return 'open';

  const s = String(currentStatus || '').toLowerCase();
  if (s === 'complete' || s === 'completed') return 'complete';
  if (s === 'blocked' || s.includes('follow')) return 'needs_followup';
  if (s.includes('not applicable') || s === 'na') return 'not_applicable';

  return 'open';
}

function clearanceStatusFromControlState(state) {
  if (state === 'complete') return 'Complete';
  if (state === 'needs_followup') return 'Blocked';
  if (state === 'not_applicable') return 'Not Applicable';
  return 'Waiting';
}

async function getDealClearanceControls(dealPublicId) {
  const [deals] = await pool.query(
    `SELECT id, public_id, property_address, transaction_status, additional_terms
     FROM dd_deals
     WHERE public_id = ? AND removed_at IS NULL
     LIMIT 1`,
    [dealPublicId]
  );

  if (!deals.length) {
    const err = new Error('Deal not found');
    err.statusCode = 404;
    throw err;
  }

  const deal = deals[0];

  const [items] = await pool.query(
    `SELECT
       public_id,
       category,
       task_name,
       status,
       priority,
       waiting_on_entity_type,
       waiting_on_name,
       office_contact_name,
       office_contact_role,
       office_contact_phone,
       office_contact_email,
       email_sent_at,
       email_sent_by,
       email_sent_proof_note,
       response_received_at,
       response_from_name,
       response_from_email,
       response_summary,
       response_body,
       manager_proof_note,
       manager_override_by,
       manager_override_at,
       due_date,
       last_contacted_at,
       verified_at,
       completed_at,
       notes,
       verification_notes,
       control_state,
       clearance_source,
       clearance_evidence,
       operator_status_note,
       operator_confirmed_by,
       operator_confirmed_at,
       created_at,
       updated_at
     FROM dd_transaction_tasks
     WHERE deal_id = ?
     ORDER BY
       CASE
         WHEN COALESCE(control_state, '') = 'needs_followup' OR status = 'Blocked' THEN 1
         WHEN COALESCE(control_state, '') = 'open' OR status IN ('Waiting', 'In Progress') THEN 2
         WHEN COALESCE(control_state, '') = 'complete' OR status = 'Complete' THEN 3
         ELSE 4
       END,
       due_date IS NULL,
       due_date,
       id`,
    [deal.id]
  );

  const [draftRows] = await pool.query(
    `SELECT
       public_id,
       email_type,
       recipient_role,
       to_name,
       to_email,
       cc_email,
       subject,
       body,
       email_status,
       created_at,
       updated_at
     FROM dd_email_messages
     WHERE deal_id = ?
       AND email_type LIKE 'clearance_%'
       AND email_status IN ('Draft', 'Sent')
     ORDER BY id DESC`,
    [deal.id]
  );

  const draftByTask = new Map();
  for (const row of draftRows) {
    const taskId = String(row.email_type || '').replace(/^clearance_/, '');
    if (taskId && !draftByTask.has(taskId)) {
      draftByTask.set(taskId, row);
    }
  }

  const controls = items.map(item => {
    const controlState = normalizeClearanceControlState(item.control_state, item.status);
    return {
      ...item,
      control_state: controlState,
      control_label:
        controlState === 'complete' ? 'Complete' :
        controlState === 'needs_followup' ? 'Needs Follow-up' :
        controlState === 'not_applicable' ? 'Not Applicable' :
        'Open',
      visual_symbol:
        controlState === 'complete' ? '[x]' :
        controlState === 'needs_followup' ? '[!]' :
        controlState === 'not_applicable' ? '[na]' :
        '[ ]',
      clearance_source: item.clearance_source || 'system_default',
      clearance_evidence: item.clearance_evidence || item.verification_notes || item.notes || '',
      draft_email: draftByTask.get(item.public_id) || null
    };
  });

  return {
    deal,
    clearance_items: controls
  };
}


function smartNextActionFromClearanceTask(task) {
  const taskName = cleanText(task.task_name) || cleanText(task.category) || 'next clearance item';
  const waitingOn = cleanText(task.waiting_on_name);
  const text = [
    task.category,
    task.task_name,
    task.status,
    task.control_state,
    task.waiting_on_entity_type,
    task.waiting_on_name,
    task.notes,
    task.verification_notes,
    task.clearance_evidence,
    task.operator_status_note
  ].filter(Boolean).join(' ').toLowerCase();

  if (text.includes('seller') && text.includes('attorney')) return 'Confirm seller attorney contact.';
  if ((text.includes('purchaser') || text.includes('buyer')) && text.includes('attorney')) return 'Confirm purchaser attorney contact.';
  if (text.includes('inspection') || text.includes('inspector')) return 'Confirm inspection status.';
  if (text.includes('appraisal') || text.includes('appraiser')) return 'Confirm appraisal status.';
  if (text.includes('title')) return 'Confirm title order status.';
  if (text.includes('property') && text.includes('condition')) return 'Confirm Property Condition Statement status.';
  if (text.includes('seller') && text.includes('acknowledg')) return 'Clear seller acknowledgment.';
  if ((text.includes('purchaser') || text.includes('buyer')) && text.includes('acknowledg')) return 'Clear purchaser acknowledgment.';
  if (text.includes('lender') || text.includes('loan') || text.includes('financing') || text.includes('mortgage')) return 'Confirm lender / financing status.';
  if (text.includes('contract')) return 'Confirm contract status.';

  if (waitingOn) return `Follow up with ${waitingOn} about ${taskName}.`;

  return `Clear ${taskName}.`;
}

async function smartNextActionForDeal(dealId) {
  const [[deal]] = await pool.query(
    `SELECT transaction_status
     FROM dd_deals
     WHERE id = ?
     LIMIT 1`,
    [dealId]
  );

  const [tasks] = await pool.query(
    `SELECT
       category,
       task_name,
       status,
       control_state,
       waiting_on_entity_type,
       waiting_on_name,
       due_date,
       notes,
       verification_notes,
       clearance_evidence,
       operator_status_note
     FROM dd_transaction_tasks
     WHERE deal_id = ?
       AND LOWER(COALESCE(control_state,'open')) NOT IN ('complete','completed','not_applicable','not applicable','na','n/a')
     ORDER BY
       CASE
         WHEN LOWER(COALESCE(control_state,'')) IN ('needs_followup','needs follow-up','needs_follow_up','blocked') OR status = 'Blocked' THEN 1
         WHEN LOWER(COALESCE(control_state,'open')) = 'open' OR status IN ('Waiting','In Progress') THEN 2
         ELSE 3
       END,
       due_date IS NULL,
       due_date,
       task_name
     LIMIT 1`,
    [dealId]
  );

  if (tasks.length) {
    return smartNextActionFromClearanceTask(tasks[0]);
  }

  const status = cleanText(deal && deal.transaction_status);

  if (!status || status === 'Active' || status === 'Accepted Offer Intake Started') {
    return 'Ready to move to Contract Out.';
  }

  if (status === 'Contract Out') return 'Ready to move to In Contract.';
  if (status === 'In Contract') return 'Ready to schedule closing.';
  if (status === 'Closing Scheduled') return 'Ready for closing confirmation.';
  if (status === 'Closed') return 'Review final file status.';
  if (status === 'Final') return 'File complete.';

  return 'Review Clearance Path and verify required contacts.';
}

async function refreshDealNextAction(dealId) {
  const nextAction = await smartNextActionForDeal(dealId);

  await pool.query(
    `UPDATE dd_deals
     SET next_action = ?,
         updated_at = NOW()
     WHERE id = ?`,
    [nextAction, dealId]
  );

  return nextAction;
}

async function updateDealClearanceControl(dealPublicId, taskPublicId, body) {
  const [deals] = await pool.query(
    `SELECT id, public_id, property_address
     FROM dd_deals
     WHERE public_id = ? AND removed_at IS NULL
     LIMIT 1`,
    [dealPublicId]
  );

  if (!deals.length) {
    const err = new Error('Deal not found');
    err.statusCode = 404;
    throw err;
  }

  const [[existingTask]] = await pool.query(
    `SELECT
       id,
       control_state,
       status,
       clearance_evidence,
       operator_status_note,
       email_sent_at,
       response_received_at,
       manager_proof_note
     FROM dd_transaction_tasks
     WHERE deal_id = ? AND public_id = ?
     LIMIT 1`,
    [deals[0].id, taskPublicId]
  );

  if (!existingTask) {
    const err = new Error('Clearance item not found');
    err.statusCode = 404;
    throw err;
  }

  const state = normalizeClearanceControlState(body.control_state || body.state, existingTask.status);
  const status = clearanceStatusFromControlState(state);
  const source = cleanText(body.clearance_source || body.source) || 'operator_entered';
  const evidence = cleanText(body.clearance_evidence || body.evidence_note || body.note) || '';
  const operator = cleanText(body.updated_by || body.operator || body.created_by) || 'operator';

  const contactName = cleanText(body.office_contact_name || body.contact_name || body.to_name || body.waiting_on_name) || null;
  const contactRole = cleanText(body.office_contact_role || body.contact_role || body.recipient_role) || null;
  const contactPhone = cleanText(body.office_contact_phone || body.contact_phone || body.to_phone) || null;
  const contactEmail = cleanText(body.office_contact_email || body.contact_email || body.to_email) || null;

  const proofAction = cleanText(body.proof_action || body.action);
  const markSent = proofAction === 'mark_sent' || body.email_marked_sent === true;
  const logResponse = proofAction === 'log_response' || body.response_received === true;

  const sentProofNote = cleanText(body.email_sent_proof_note || body.sent_proof_note || body.proof_note) || null;
  const responseFromName = cleanText(body.response_from_name) || null;
  const responseFromEmail = cleanText(body.response_from_email) || null;
  const responseSummary = cleanText(body.response_summary) || null;
  const responseBody = cleanText(body.response_body) || null;
  const managerProofNote = cleanText(body.manager_proof_note || body.manager_note) || null;

  if (state === 'complete') {
    const hasProof =
      evidence ||
      sentProofNote ||
      responseSummary ||
      responseBody ||
      managerProofNote ||
      existingTask.clearance_evidence ||
      existingTask.operator_status_note ||
      existingTask.email_sent_at ||
      existingTask.response_received_at ||
      existingTask.manager_proof_note;

    if (!hasProof) {
      const err = new Error('Complete requires proof: add evidence, mark sent, log a response, or enter a manager proof note.');
      err.statusCode = 400;
      throw err;
    }
  }

  const [result] = await pool.query(
    `UPDATE dd_transaction_tasks
     SET
       control_state = ?,
       status = ?,
       clearance_source = ?,
       clearance_evidence = ?,
       operator_status_note = ?,
       office_contact_name = COALESCE(?, office_contact_name),
       office_contact_role = COALESCE(?, office_contact_role),
       office_contact_phone = COALESCE(?, office_contact_phone),
       office_contact_email = COALESCE(?, office_contact_email),
       waiting_on_name = COALESCE(?, waiting_on_name),
       email_sent_at = CASE WHEN ? THEN COALESCE(email_sent_at, NOW()) ELSE email_sent_at END,
       email_sent_by = CASE WHEN ? THEN ? ELSE email_sent_by END,
       email_sent_proof_note = COALESCE(?, email_sent_proof_note),
       response_received_at = CASE WHEN ? THEN COALESCE(response_received_at, NOW()) ELSE response_received_at END,
       response_from_name = COALESCE(?, response_from_name),
       response_from_email = COALESCE(?, response_from_email),
       response_summary = COALESCE(?, response_summary),
       response_body = COALESCE(?, response_body),
       manager_proof_note = COALESCE(?, manager_proof_note),
       manager_override_by = CASE WHEN ? IS NOT NULL THEN ? ELSE manager_override_by END,
       manager_override_at = CASE WHEN ? IS NOT NULL THEN COALESCE(manager_override_at, NOW()) ELSE manager_override_at END,
       operator_confirmed_by = ?,
       operator_confirmed_at = NOW(),
       completed_at = CASE WHEN ? IN ('complete', 'not_applicable') THEN COALESCE(completed_at, NOW()) ELSE NULL END,
       updated_at = NOW()
     WHERE deal_id = ? AND public_id = ?`,
    [
      state,
      status,
      source,
      evidence,
      evidence,
      contactName,
      contactRole,
      contactPhone,
      contactEmail,
      contactName,
      markSent,
      markSent,
      operator,
      sentProofNote,
      logResponse,
      responseFromName,
      responseFromEmail,
      responseSummary,
      responseBody,
      managerProofNote,
      managerProofNote,
      operator,
      managerProofNote,
      operator,
      state,
      deals[0].id,
      taskPublicId
    ]
  );

  if (!result.affectedRows) {
    const err = new Error('Clearance item not found');
    err.statusCode = 404;
    throw err;
  }

  if (markSent) {
    await pool.query(
      `UPDATE dd_email_messages
       SET email_status = 'Sent',
           sent_at = COALESCE(sent_at, NOW()),
           sent_by = ?,
           provider_message_id = COALESCE(provider_message_id, 'manual'),
           updated_at = NOW()
       WHERE deal_id = ?
         AND email_type = ?
         AND email_status = 'Draft'
       ORDER BY id DESC
       LIMIT 1`,
      [operator, deals[0].id, `clearance_${taskPublicId}`]
    );
  }

  let eventSummary = `Clearance item updated to ${status}.`;
  if (markSent) eventSummary = 'Clearance email marked sent by operator.';
  if (logResponse) eventSummary = 'Clearance email response logged by operator.';
  if (managerProofNote) eventSummary = 'Manager proof note added to clearance item.';

  await pool.query(
    `INSERT INTO dd_deal_history
     (deal_id, event_type, event_summary, created_by)
     VALUES (?, ?, ?, ?)`,
    [
      deals[0].id,
      markSent ? 'Clearance Email Marked Sent' : logResponse ? 'Clearance Response Logged' : managerProofNote ? 'Clearance Manager Proof Added' : 'Clearance Control Updated',
      eventSummary,
      operator
    ]
  );

  await refreshDealNextAction(deals[0].id);
  return getDealClearanceControls(dealPublicId);
}


function inferClearanceDraftRole(task, body) {
  const supplied = cleanText(body.recipient_role || body.role_key);
  if (supplied) return supplied;

  const text = [
    task.category,
    task.task_name,
    task.waiting_on_entity_type,
    task.waiting_on_name,
    task.notes,
    task.clearance_evidence,
    task.operator_status_note
  ].filter(Boolean).join(' ').toLowerCase();

  if (text.includes('seller') && text.includes('attorney')) return 'seller_attorney';
  if ((text.includes('purchaser') || text.includes('buyer')) && text.includes('attorney')) return 'purchaser_attorney';
  if ((text.includes('seller') || text.includes('listing')) && text.includes('agent')) return 'seller_agent';
  if ((text.includes('purchaser') || text.includes('buyer')) && text.includes('agent')) return 'purchaser_agent';
  if (text.includes('lender') || text.includes('loan') || text.includes('financing') || text.includes('mortgage')) return 'lender';
  if (text.includes('inspection') || text.includes('inspector')) return 'inspector';
  if (text.includes('appraisal') || text.includes('appraiser')) return 'appraiser';
  if (text.includes('title')) return 'title';
  if (text.includes('seller')) return 'seller';
  if (text.includes('purchaser') || text.includes('buyer')) return 'purchaser';

  return 'operator_verified';
}

function clearanceDraftAsk(task) {
  const text = [
    task.category,
    task.task_name,
    task.waiting_on_entity_type,
    task.waiting_on_name
  ].filter(Boolean).join(' ').toLowerCase();

  if (text.includes('inspection')) {
    return 'Please confirm whether inspection is scheduled, completed, waived, or has unresolved issues.';
  }

  if (text.includes('appraisal')) {
    return 'Please confirm appraisal status, scheduling, completion, or any outstanding issue affecting the file.';
  }

  if (text.includes('title')) {
    return 'Please confirm title order status, assigned title contact, and any known title issues.';
  }

  if (text.includes('attorney') || text.includes('contract')) {
    return 'Please confirm receipt, the person handling this file, and any immediate contract items needed from our side.';
  }

  if (text.includes('lender') || text.includes('loan') || text.includes('financing') || text.includes('mortgage')) {
    return 'Please confirm the best loan contact or processor for this file and any immediate financing or appraisal next steps.';
  }

  return 'Please confirm the current status of this clearance item and advise what, if anything, is still needed.';
}

async function createClearanceDraftEmail(dealPublicId, taskPublicId, body) {
  const record = await getDeal(dealPublicId);
  if (!record) return null;

  if (record.deal.removed_at) {
    const err = new Error('Cannot create email drafts for a removed accepted offer');
    err.statusCode = 400;
    throw err;
  }

  const [[task]] = await pool.query(
    `SELECT *
     FROM dd_transaction_tasks
     WHERE deal_id = ? AND public_id = ?
     LIMIT 1`,
    [record.deal.id, taskPublicId]
  );

  if (!task) {
    const err = new Error('Clearance item not found');
    err.statusCode = 404;
    throw err;
  }

  const createdBy = cleanText(body.created_by || body.updated_by) || 'operator';
  const recipientRole = inferClearanceDraftRole(task, body);
  const party = findParty(record, recipientRole);

  const toEmail = cleanText(body.to_email) || cleanText(task.office_contact_email) || cleanText(party.email);
  const toName = cleanText(body.to_name) || cleanText(task.office_contact_name) || cleanText(party.display_name) || cleanText(task.waiting_on_name) || null;
  const ccEmail = cleanText(body.cc_email) || null;

  if (!toEmail) {
    const err = new Error('No recipient email is available for this clearance item. Verify the clearance contact and enter the email address before drafting.');
    err.statusCode = 400;
    throw err;
  }

  const taskLabel = cleanText(task.task_name) || cleanText(task.category) || 'Clearance item';
  const emailType = `clearance_${taskPublicId}`;

  const [[existing]] = await pool.query(
    `SELECT public_id, email_type, recipient_role, to_name, to_email, cc_email, subject, body, email_status
     FROM dd_email_messages
     WHERE deal_id = ? AND email_type = ? AND email_status IN ('Draft', 'Sent')
     LIMIT 1`,
    [record.deal.id, emailType]
  );

  if (existing) {
    return {
      ...existing,
      reused: true
    };
  }

  const subject = cleanText(body.subject) ||
    `Clearance Needed: ${taskLabel} - ${record.deal.property_address || 'Property'}`;

  const messageBody = cleanText(body.message_body) || [
    `Hello ${toName || ''},`.trim(),
    '',
    'We are working through the accepted-offer clearance path for this file and need to confirm the item below.',
    '',
    'Clearance item:',
    `- ${taskLabel}`,
    '',
    'Deal summary:',
    ...dealSummaryLines(record).map(v => `- ${v}`),
    '',
    clearanceDraftAsk(task),
    '',
    'Thank you,',
    'Accepted Offer to Close'
  ].join('\n');

  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    const msgPublicId = crypto.randomUUID();

    const [result] = await connection.query(
      `INSERT INTO dd_email_messages
       (public_id, deal_id, email_type, recipient_role, to_name, to_email, cc_email, subject, body, email_status, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        msgPublicId,
        record.deal.id,
        emailType,
        recipientRole,
        toName,
        toEmail,
        ccEmail,
        subject,
        messageBody,
        'Draft',
        createdBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_deal_history
       (deal_id, event_type, event_summary, created_by)
       VALUES (?, ?, ?, ?)`,
      [
        record.deal.id,
        'Clearance Email Draft Generated',
        `Draft email generated for clearance item: ${taskLabel}.`,
        createdBy
      ]
    );

    await connection.query(
      `INSERT INTO dd_usage_ledger
       (deal_id, item_type, item_id, action_type, action_summary, recipient, result_notes, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        record.deal.id,
        'clearance_email',
        result.insertId,
        'generated',
        `Clearance email draft generated for ${taskLabel}.`,
        toEmail,
        'Generated only. Not sent.',
        createdBy
      ]
    );

    await connection.commit();

    return {
      public_id: msgPublicId,
      email_type: emailType,
      recipient_role: recipientRole,
      to_name: toName,
      to_email: toEmail,
      cc_email: ccEmail,
      subject,
      body: messageBody,
      email_status: 'Draft',
      reused: false
    };
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}



// CLAIRE_EMAIL_TO_INTAKE_API_V1
function claireSafeJsonParse(value, fallback) {
  if (value === null || value === undefined || value === '') return fallback;
  if (typeof value !== 'string') return value;
  try { return JSON.parse(value); } catch (err) { return fallback; }
}
function claireEmailAddress(value) {
  return cleanText(value || '').replace(/^.*<([^>]+)>.*$/, '$1');
}
function claireExtractIntakeFromEmail(payload) {
  const body = cleanText(payload.body_text || payload.text || '');
  const subject = cleanText(payload.subject || '');
  const attachmentText = Array.isArray(payload.attachments) ? payload.attachments.map(a => cleanText(a.text_extract || '')).filter(Boolean).join('\n') : '';
  const allText = [subject, body, attachmentText].filter(Boolean).join('\n');
  function matchFirst(patterns) { for (const pattern of patterns) { const m = allText.match(pattern); if (m && m[1]) return cleanText(m[1]); } return ''; }
  const priceRaw = matchFirst([/(?:purchase\s*price|price|accepted\s*price)\s*[:\-]?\s*\$?\s*([0-9,]+(?:\.\d{2})?)/i,/\$\s*([0-9]{3,}(?:,[0-9]{3})+(?:\.\d{2})?)/i]);
  const propertyAddress = matchFirst([/(?:property|address|property\s*address)\s*[:\-]\s*([^\n\r]+)/i,/(?:accepted\s*offer|offer)\s*[-:]\s*([0-9][^\n\r]+)/i]);
  const seller = matchFirst([/(?:seller|owner)\s*[:\-]\s*([^\n\r]+)/i]);
  const purchaser = matchFirst([/(?:purchaser|buyer)\s*[:\-]\s*([^\n\r]+)/i]);
  const sellerAttorney = matchFirst([/seller\s*attorney\s*[:\-]\s*([^\n\r]+)/i]);
  const purchaserAttorney = matchFirst([/(?:purchaser|buyer)\s*attorney\s*[:\-]\s*([^\n\r]+)/i]);
  const financing = matchFirst([/(?:financing|loan|mortgage)\s*[:\-]\s*([^\n\r]+)/i]) || (/\bcash\b/i.test(allText) ? 'Cash' : '');
  const inspection = matchFirst([/inspection\s*[:\-]\s*([^\n\r]+)/i]) || (/\binspection\s+waived\b/i.test(allText) ? 'Inspection waived' : '');
  const propertyCondition = matchFirst([/property\s*condition(?:\s*statement)?\s*[:\-]\s*([^\n\r]+)/i]);
  const emails = Array.from(new Set((allText.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/ig) || []).map(v => v.toLowerCase())));
  const extracted = { property_address: propertyAddress, purchase_price: priceRaw ? Number(String(priceRaw).replace(/[^0-9.]/g, '')) : null, seller_names: seller ? [seller] : [], purchaser_names: purchaser ? [purchaser] : [], seller_attorney_name: sellerAttorney, purchaser_attorney_name: purchaserAttorney, financing_status: financing, inspection_status: inspection, property_condition_status: propertyCondition, emails_found: emails, source_subject: subject, extraction_method: 'CLAIRE heuristic email intake parser v1' };
  const missing = [];
  if (!extracted.property_address) missing.push('property address');
  if (!extracted.purchase_price) missing.push('purchase price');
  if (!seller) missing.push('seller');
  if (!purchaser) missing.push('purchaser');
  if (!sellerAttorney) missing.push('seller attorney');
  if (!purchaserAttorney) missing.push('purchaser attorney');
  if (!propertyCondition) missing.push('property condition statement status');
  const confidence = Math.max(10, Math.round(((7 - missing.length) / 7) * 100));
  return { extracted, missing_fields: missing, confidence_score: confidence, property_address: extracted.property_address || '' };
}
async function clairePossibleDuplicateSummary(propertyAddress) {
  const addr = cleanText(propertyAddress);
  if (!addr) return { possible_duplicate: false, matches: [] };
  const [rows] = await pool.query(`SELECT public_id, property_address, transaction_status, updated_at FROM dd_deals WHERE removed_at IS NULL AND property_address LIKE ? ORDER BY updated_at DESC LIMIT 5`, [`%${addr.slice(0, 60)}%`]);
  return { possible_duplicate: rows.length > 0, matches: rows };
}
async function claireCreateIntakeDraftFromPayload(payload) {
  const source = claireExtractIntakeFromEmail(payload);
  const duplicateCheck = await clairePossibleDuplicateSummary(source.property_address);
  const draftPublicId = crypto.randomUUID();
  const emailPublicId = crypto.randomUUID();
  const messageId = cleanText(payload.message_id || payload.messageId || '') || null;
  const fromEmail = claireEmailAddress(payload.from_email || payload.from || '');
  const fromName = cleanText(payload.from_name || '');
  const toEmail = claireEmailAddress(payload.to_email || payload.to || '');
  const subject = cleanText(payload.subject || '');
  const receivedAt = cleanText(payload.received_at || payload.date || '') || null;
  const bodyText = cleanText(payload.body_text || payload.text || '');
  const bodyHtml = typeof payload.body_html === 'string' ? payload.body_html : '';
  const rawJson = JSON.stringify(payload).slice(0, 16000000);
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    let emailId = null;
    if (messageId) { const [[existingEmail]] = await connection.query(`SELECT id FROM dd_inbound_emails WHERE message_id = ? LIMIT 1`, [messageId]); if (existingEmail) emailId = existingEmail.id; }
    if (!emailId) {
      const [emailResult] = await connection.query(`INSERT INTO dd_inbound_emails (public_id, message_id, from_email, from_name, to_email, subject, received_at, body_text, body_html, raw_json, processing_status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, [emailPublicId, messageId, fromEmail || null, fromName || null, toEmail || null, subject || null, receivedAt ? new Date(receivedAt) : new Date(), bodyText || null, bodyHtml || null, rawJson, 'Draft Created']);
      emailId = emailResult.insertId;
      if (Array.isArray(payload.attachments)) {
        for (const att of payload.attachments) {
          await connection.query(`INSERT INTO dd_inbound_email_attachments (public_id, email_id, filename, mime_type, file_path, text_extract) VALUES (?, ?, ?, ?, ?, ?)`, [crypto.randomUUID(), emailId, cleanText(att.filename || '') || null, cleanText(att.mime_type || att.contentType || '') || null, cleanText(att.file_path || '') || null, cleanText(att.text_extract || '') || null]);
        }
      }
    }
    const [[existingDraft]] = await connection.query(`SELECT public_id FROM dd_intake_drafts WHERE inbound_email_id = ? ORDER BY id DESC LIMIT 1`, [emailId]);
    if (existingDraft) { await connection.commit(); return getClaireIntakeDraft(existingDraft.public_id); }
    const status = source.confidence_score >= 75 && !duplicateCheck.possible_duplicate ? 'Ready to Review' : 'Needs Review';
    await connection.query(`INSERT INTO dd_intake_drafts (public_id, inbound_email_id, draft_status, property_address, extracted_json, confidence_score, missing_fields_json, duplicate_check_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, [draftPublicId, emailId, status, source.property_address || null, JSON.stringify(source.extracted), source.confidence_score, JSON.stringify(source.missing_fields), JSON.stringify(duplicateCheck)]);
    await connection.commit();
    return getClaireIntakeDraft(draftPublicId);
  } catch (err) { await connection.rollback(); throw err; } finally { connection.release(); }
}
async function listClaireIntakeDrafts() {
  const [rows] = await pool.query(`SELECT d.public_id, d.draft_status, d.property_address, d.confidence_score, d.missing_fields_json, d.duplicate_check_json, d.created_at, d.updated_at, e.from_email, e.from_name, e.subject, e.received_at FROM dd_intake_drafts d LEFT JOIN dd_inbound_emails e ON e.id = d.inbound_email_id ORDER BY CASE WHEN d.draft_status = 'Needs Review' THEN 1 WHEN d.draft_status = 'Ready to Review' THEN 2 WHEN d.draft_status = 'Rejected' THEN 9 WHEN d.draft_status = 'Created' THEN 10 ELSE 5 END, d.created_at DESC LIMIT 100`);
  return rows.map(row => ({ ...row, missing_fields: claireSafeJsonParse(row.missing_fields_json, []), duplicate_check: claireSafeJsonParse(row.duplicate_check_json, {}) }));
}
async function getClaireIntakeDraft(publicId) {
  const [[row]] = await pool.query(`SELECT d.*, e.public_id AS inbound_email_public_id, e.message_id, e.from_email, e.from_name, e.to_email, e.subject, e.received_at, e.body_text, e.body_html FROM dd_intake_drafts d LEFT JOIN dd_inbound_emails e ON e.id = d.inbound_email_id WHERE d.public_id = ? LIMIT 1`, [publicId]);
  if (!row) return null;
  const [attachments] = await pool.query(`SELECT public_id, filename, mime_type, file_path, text_extract, created_at FROM dd_inbound_email_attachments WHERE email_id = ? ORDER BY id`, [row.inbound_email_id]);
  return { ...row, extracted: claireSafeJsonParse(row.extracted_json, {}), missing_fields: claireSafeJsonParse(row.missing_fields_json, []), duplicate_check: claireSafeJsonParse(row.duplicate_check_json, {}), attachments };
}
async function updateClaireIntakeDraftStatus(publicId, status, operator) {
  const allowed = new Set(['Needs Review', 'Ready to Review', 'Rejected', 'Created']);
  const next = allowed.has(status) ? status : 'Needs Review';
  const [result] = await pool.query(`UPDATE dd_intake_drafts SET draft_status = ?, reviewed_by = ?, reviewed_at = NOW(), updated_at = NOW() WHERE public_id = ?`, [next, cleanText(operator || 'operator'), publicId]);
  if (!result.affectedRows) return null;
  return getClaireIntakeDraft(publicId);
}
// END_CLAIRE_EMAIL_TO_INTAKE_API_V1


// CLAIRE_CREATE_DEAL_DOCUMENTS_V1
async function claireTableExists(tableName) {
  const [[row]] = await pool.query(
    `SELECT COUNT(*) AS c
     FROM INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = ?`,
    [tableName]
  );
  return Number(row && row.c || 0) > 0;
}

async function claireTableColumnsForClient(client, tableName) {
  const [rows] = await client.query(
    `SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA
     FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = ?
     ORDER BY ORDINAL_POSITION`,
    [tableName]
  );
  return rows;
}

function claireColumnMap(columns) {
  const map = {};
  for (const col of columns) map[col.COLUMN_NAME] = col;
  return map;
}

function clairePickColumn(map, names) {
  for (const name of names) {
    if (map[name]) return name;
  }
  return null;
}

function claireColumnFallbackValue(col) {
  const type = String(col.DATA_TYPE || '').toLowerCase();
  if (type.includes('int') || type.includes('decimal') || type.includes('float') || type.includes('double')) return 0;
  if (type === 'date') return new Date();
  if (type.includes('time') || type.includes('year')) return new Date();
  if (type === 'json') return '{}';
  return '';
}

async function claireDynamicInsert(client, tableName, preferred) {
  if (!(await claireTableExists(tableName))) return null;

  const columns = await claireTableColumnsForClient(client, tableName);
  const map = claireColumnMap(columns);
  const values = {};

  for (const [key, value] of Object.entries(preferred || {})) {
    if (map[key] && value !== undefined) values[key] = value;
  }

  for (const col of columns) {
    const name = col.COLUMN_NAME;
    if (values[name] !== undefined) continue;
    if (String(col.EXTRA || '').toLowerCase().includes('auto_increment')) continue;

    const nullable = String(col.IS_NULLABLE || '').toUpperCase() === 'YES';
    const hasDefault = col.COLUMN_DEFAULT !== null && col.COLUMN_DEFAULT !== undefined;

    if (!nullable && !hasDefault) {
      values[name] = claireColumnFallbackValue(col);
    }
  }

  const keys = Object.keys(values);
  if (!keys.length) throw new Error('No insertable columns found for ' + tableName);

  const placeholders = keys.map(() => '?').join(', ');
  const sql = `INSERT INTO ${tableName} (${keys.map(k => '`' + k + '`').join(', ')}) VALUES (${placeholders})`;
  const [result] = await client.query(sql, keys.map(k => values[k]));
  return result.insertId;
}

function claireFirstArrayValue(value) {
  if (Array.isArray(value)) return cleanText(value[0] || '');
  return cleanText(value || '');
}

function claireInferDocumentType(filename, mimeType) {
  const name = String(filename || '').toLowerCase();
  const mime = String(mimeType || '').toLowerCase();
  if (name.includes('deal') && name.includes('sheet')) return 'Deal Sheet';
  if (name.includes('offer')) return 'Offer';
  if (name.includes('mls')) return 'MLS Sheet';
  if (name.includes('attorney')) return 'Attorney Information';
  if (name.includes('condition')) return 'Property Condition';
  if (name.includes('disclosure')) return 'Signed Disclosure';
  if (mime.includes('pdf')) return 'PDF Document';
  if (mime.includes('word') || name.endsWith('.docx')) return 'Word Document';
  return 'Other';
}

function claireSafeStorageName(filename) {
  const crypto = require('crypto');
  const clean = String(filename || 'document').replace(/[^a-zA-Z0-9._-]+/g, '_').slice(0, 120);
  return crypto.randomUUID() + '-' + clean;
}

async function claireFindDealByPublicOrId(dealRef) {
  const value = cleanText(dealRef || '');
  if (!value) return null;

  const params = [value];
  let numericSql = '';
  if (/^\d+$/.test(value)) {
    numericSql = ' OR id = ?';
    params.push(Number(value));
  }

  const [[deal]] = await pool.query(
    `SELECT *
     FROM dd_deals
     WHERE public_id = ?${numericSql}
     LIMIT 1`,
    params
  );

  return deal || null;
}

async function claireListDealDocuments(dealRef) {
  const deal = await claireFindDealByPublicOrId(dealRef);
  if (!deal) return { deal: null, documents: [] };

  const [rows] = await pool.query(
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
  );

  return { deal, documents: rows };
}

async function claireGetDocumentForView(docId) {
  const [[row]] = await pool.query(
    `SELECT *
     FROM dd_deal_documents
     WHERE id = ?
     LIMIT 1`,
    [docId]
  );
  return row || null;
}

async function claireCreateDealFromDraft(publicId, operator) {
  if (typeof getClaireIntakeDraft !== 'function') {
    throw new Error('Missing getClaireIntakeDraft helper. Run the email-to-intake setup first.');
  }

  const fs = require('fs');
  const path = require('path');
  const crypto = require('crypto');

  const draft = await getClaireIntakeDraft(publicId);
  if (!draft) throw new Error('Intake draft not found');

  if (draft.created_deal_id) {
    const [[existingDeal]] = await pool.query(
      `SELECT public_id, id, property_address
       FROM dd_deals
       WHERE id = ?
       LIMIT 1`,
      [draft.created_deal_id]
    );

    if (existingDeal) {
      const docs = await claireListDealDocuments(existingDeal.public_id);
      return {
        deal: existingDeal,
        already_created: true,
        documents: docs.documents || []
      };
    }
  }

  const extracted = draft.extracted || {};
  const propertyAddress = cleanText(
    extracted.property_address ||
    draft.property_address ||
    'Accepted Offer'
  );

  const purchasePrice = Number(extracted.purchase_price || 0) || null;
  const sellerName = claireFirstArrayValue(extracted.seller_names);
  const purchaserName = claireFirstArrayValue(extracted.purchaser_names);
  const sellerAttorney = cleanText(extracted.seller_attorney_name || '');
  const purchaserAttorney = cleanText(extracted.purchaser_attorney_name || '');
  const financing = cleanText(extracted.financing_status || '');
  const inspection = cleanText(extracted.inspection_status || '');
  const propertyCondition = cleanText(extracted.property_condition_status || '');

  const dealPublicId = crypto.randomUUID();
  const connection = await pool.getConnection();

  try {
    await connection.beginTransaction();

    const dealCols = await claireTableColumnsForClient(connection, 'dd_deals');
    const dealMap = claireColumnMap(dealCols);

    const preferredDeal = {
      public_id: dealPublicId,
      property_address: propertyAddress,
      address: propertyAddress,
      purchase_price: purchasePrice,
      accepted_price: purchasePrice,
      sales_price: purchasePrice,
      price: purchasePrice,
      transaction_status: 'Accepted Offer / Intake Started',
      file_status: 'Accepted Offer / Intake Started',
      status: 'Accepted Offer / Intake Started',
      deal_status: 'Accepted Offer / Intake Started',
      next_action: 'Review CLAIRE intake draft and clear missing items',
      created_by: cleanText(operator || 'CLAIRE'),
      updated_by: cleanText(operator || 'CLAIRE'),
      source: 'Email Intake',
      intake_source: 'CLAIRE Email-to-Intake',
      seller_name: sellerName,
      purchaser_name: purchaserName,
      buyer_name: purchaserName,
      seller_attorney_name: sellerAttorney,
      purchaser_attorney_name: purchaserAttorney,
      buyer_attorney_name: purchaserAttorney,
      financing_status: financing,
      inspection_status: inspection,
      property_condition_status: propertyCondition,
      notes: 'Created from CLAIRE Email-to-Intake draft.'
    };

    for (const col of Object.keys(preferredDeal)) {
      if (!dealMap[col]) delete preferredDeal[col];
    }

    const dealId = await claireDynamicInsert(connection, 'dd_deals', preferredDeal);

    if (!dealId) throw new Error('Could not create deal record.');

    async function insertParty(role, name, email, sortOrder) {
      if (!name && !email) return;
      try {
        await claireDynamicInsert(connection, 'dd_deal_parties', {
          deal_id: dealId,
          role_key: role,
          display_name: name || email,
          email: email || null,
          sort_order: sortOrder
        });
      } catch (err) {
        console.warn('Party insert skipped:', role, err.message);
      }
    }

    await insertParty('seller', sellerName, '', 10);
    await insertParty('purchaser', purchaserName, '', 20);
    await insertParty('seller_attorney', sellerAttorney, cleanText(extracted.seller_attorney_email || ''), 30);
    await insertParty('purchaser_attorney', purchaserAttorney, cleanText(extracted.purchaser_attorney_email || ''), 40);

    const clearanceItems = [
      ['Attorney', 'Confirm who is handling the file at seller attorney office'],
      ['Attorney', 'Confirm who is handling the file at purchaser attorney office'],
      ['Attorney', 'Track contract preparation / contract out'],
      ['Lender', 'Confirm lender / loan officer and financing status'],
      ['Inspection', 'Track inspection status'],
      ['Appraisal', 'Track appraisal status'],
      ['Title', 'Confirm title contact / title order status'],
      ['Seller', 'Confirm seller acknowledgment of receipt'],
      ['Buyer', 'Confirm purchaser acknowledgment of receipt'],
      ['Buyer', 'Confirm property condition statement status']
    ];

    if (await claireTableExists('dd_transaction_tasks')) {
      for (const [category, title] of clearanceItems) {
        try {
          await claireDynamicInsert(connection, 'dd_transaction_tasks', {
            public_id: crypto.randomUUID(),
            deal_id: dealId,
            category: category,
            task_category: category,
            clearance_category: category,
            title: title,
            task_title: title,
            task_name: title,
            name: title,
            item: title,
            label: title,
            status: 'Open',
            task_status: 'Open',
            control_state: 'Open',
            sort_order: clearanceItems.findIndex(v => v[1] === title) + 1,
            created_by: 'CLAIRE'
          });
        } catch (err) {
          console.warn('Clearance task insert skipped:', title, err.message);
        }
      }
    }

    const dealDocsRoot = path.join(__dirname, 'storage', 'deal-documents', dealPublicId);
    fs.mkdirSync(dealDocsRoot, { recursive: true });

    const createdDocuments = [];

    for (const att of draft.attachments || []) {
      const sourcePath = cleanText(att.file_path || '');
      if (!sourcePath || !fs.existsSync(sourcePath)) continue;

      const original = cleanText(att.filename || 'document');
      const stored = claireSafeStorageName(original);
      const targetPath = path.join(dealDocsRoot, stored);

      fs.copyFileSync(sourcePath, targetPath);

      const docPublicId = crypto.randomUUID();
      await connection.query(
        `INSERT INTO dd_deal_documents
         (deal_id, document_type, document_title, file_path, document_status, created_by)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [
          dealId,
          claireInferDocumentType(original, att.mime_type),
          original,
          targetPath,
          'Created',
          cleanText(operator || 'CLAIRE')
        ]
      );

      const [docInsertResult] = await connection.query(`SELECT LAST_INSERT_ID() AS id`);
      const docId = docInsertResult[0] && docInsertResult[0].id;

      createdDocuments.push({
        id: docId,
        original_filename: original,
        mime_type: cleanText(att.mime_type || ''),
        document_type: claireInferDocumentType(original, att.mime_type)
      });
    }

    if (await claireTableExists('dd_deal_history')) {
      try {
        await claireDynamicInsert(connection, 'dd_deal_history', {
          deal_id: dealId,
          event_type: 'CLAIRE Email-to-Intake',
          event_summary: `Created deal file for ${propertyAddress}. Documents attached: ${createdDocuments.length}.`,
          created_by: cleanText(operator || 'CLAIRE')
        });
      } catch (err) {
        console.warn('Deal history insert skipped:', err.message);
      }
    }

    await connection.query(
      `UPDATE dd_intake_drafts
       SET draft_status = 'Created',
           reviewed_by = ?,
           reviewed_at = NOW(),
           created_deal_id = ?,
           updated_at = NOW()
       WHERE public_id = ?`,
      [cleanText(operator || 'operator'), dealId, publicId]
    );

    await connection.commit();

    return {
      deal: {
        id: dealId,
        public_id: dealPublicId,
        property_address: propertyAddress,
        transaction_status: 'Accepted Offer / Intake Started'
      },
      already_created: false,
      documents: createdDocuments
    };
  } catch (err) {
    await connection.rollback();
    throw err;
  } finally {
    connection.release();
  }
}
// END_CLAIRE_CREATE_DEAL_DOCUMENTS_V1



// CLAIRE_EMAIL_PICKER_V1
function clairePickerShort(value, max = 220) {
  const v = String(value || '').replace(/\s+/g, ' ').trim();
  return v.length > max ? v.slice(0, max) + '...' : v;
}

function clairePickerSafeName(name) {
  return String(name || 'attachment').replace(/[^a-zA-Z0-9._-]+/g, '_').slice(0, 160);
}

function clairePickerConfig() {
  const fs = require('fs');
  const path = require('path');
  const configPath = path.join(__dirname, 'email-intake.config.json');
  if (!fs.existsSync(configPath)) throw new Error('Missing email-intake.config.json');
  return JSON.parse(fs.readFileSync(configPath, 'utf8'));
}

function clairePickerAddressList(list) {
  if (!Array.isArray(list)) return '';
  return list.map(v => {
    if (!v) return '';
    if (v.name && v.address) return `${v.name} <${v.address}>`;
    return v.name || v.address || '';
  }).filter(Boolean).join(', ');
}

function clairePickerFlags(flags) {
  if (!flags) return [];
  if (Array.isArray(flags)) return flags;
  if (typeof flags[Symbol.iterator] === 'function') return Array.from(flags);
  return [];
}

async function clairePickerWithMailbox(fn) {
  const { ImapFlow } = require('imapflow');
  const config = clairePickerConfig();
  const mailboxName = (config.processing && config.processing.mailbox) || 'INBOX';

  const client = new ImapFlow({
    host: config.mailbox.host,
    port: config.mailbox.port || 993,
    secure: config.mailbox.secure !== false,
    auth: { user: config.mailbox.user, pass: config.mailbox.pass }
  });

  await client.connect();
  const lock = await client.getMailboxLock(mailboxName);

  try {
    return await fn(client, config, mailboxName);
  } finally {
    lock.release();
    await client.logout();
  }
}

async function clairePickerExtractAttachmentText(att) {
  const contentType = String(att.contentType || '').toLowerCase();
  const filename = String(att.filename || '').toLowerCase();

  try {
    if (contentType.startsWith('text/') || filename.endsWith('.txt') || filename.endsWith('.csv')) {
      return att.content.toString('utf8').slice(0, 500000);
    }

    if (contentType.includes('pdf') || filename.endsWith('.pdf')) {
      try {
        const { PDFParse } = require('pdf-parse');
        const parser = new PDFParse({ data: att.content });
        const result = await parser.getText();
        await parser.destroy();
        return String(result.text || '').slice(0, 750000);
      } catch (err) {
        return '[PDF text extraction failed: ' + err.message + ']';
      }
    }

    if (contentType.includes('wordprocessingml') || filename.endsWith('.docx')) {
      try {
        const mammoth = require('mammoth');
        const result = await mammoth.extractRawText({ buffer: att.content });
        return String(result.value || '').slice(0, 750000);
      } catch (err) {
        return '[DOCX text extraction failed: ' + err.message + ']';
      }
    }
  } catch (err) {
    return '[Attachment text extraction failed: ' + err.message + ']';
  }
  return '';
}

async function clairePickerListEmails(limit) {
  limit = Math.max(1, Math.min(Number(limit || 25), 100));

  return clairePickerWithMailbox(async (client, config, mailboxName) => {
    const messages = [];

    for await (const msg of client.fetch('1:*', { uid: true, envelope: true, flags: true })) {
      const env = msg.envelope || {};
      const flags = clairePickerFlags(msg.flags);
      messages.push({
        uid: msg.uid,
        from: clairePickerAddressList(env.from || []),
        to: clairePickerAddressList(env.to || []),
        subject: env.subject || '',
        date: env.date || null,
        message_id: env.messageId || '',
        seen: flags.includes('\\Seen'),
        flagged: flags.includes('\\Flagged'),
        flags
      });
    }

    messages.sort((a, b) => Number(b.uid || 0) - Number(a.uid || 0));
    return { mailbox: mailboxName, user: config.mailbox && config.mailbox.user, count: messages.length, messages: messages.slice(0, limit) };
  });
}

async function clairePickerImportEmailUid(uid) {
  uid = Number(uid);
  if (!uid) throw new Error('Missing UID');

  const fs = require('fs');
  const path = require('path');
  const crypto = require('crypto');
  const { simpleParser } = require('mailparser');

  if (typeof claireCreateIntakeDraftFromPayload !== 'function') {
    throw new Error('Missing CLAIRE intake import helper. Run email-to-intake setup first.');
  }

  return clairePickerWithMailbox(async (client, config, mailboxName) => {
    const msg = await client.fetchOne(String(uid), { uid: true, envelope: true, source: true, flags: true }, { uid: true });
    if (!msg || !msg.source) throw new Error('Email UID not found: ' + uid);

    const parsed = await simpleParser(msg.source);
    const fromText = parsed.from && parsed.from.text || '';
    const subjectText = parsed.subject || '';
    const storageRoot = config.storage_root || path.join(__dirname, 'storage', 'inbound-email');
    const attachmentRoot = path.join(storageRoot, 'attachments');
    fs.mkdirSync(attachmentRoot, { recursive: true });

    console.log('[CLAIRE PICKER] Importing selected email');
    console.log('  UID:', uid);
    console.log('  From:', clairePickerShort(fromText));
    console.log('  Subject:', clairePickerShort(subjectText));
    console.log('  Attachments:', (parsed.attachments || []).length);

    const attachmentPayloads = [];

    for (const att of parsed.attachments || []) {
      const folder = path.join(attachmentRoot, new Date().toISOString().slice(0, 10));
      fs.mkdirSync(folder, { recursive: true });

      const filename = clairePickerSafeName(att.filename || ('attachment-' + crypto.randomUUID()));
      const outPath = path.join(folder, crypto.randomUUID() + '-' + filename);
      fs.writeFileSync(outPath, att.content);

      let textExtract = '';
      try {
        textExtract = await clairePickerExtractAttachmentText(att);
      } catch (err) {
        textExtract = '[Attachment text extraction failed: ' + err.message + ']';
      }

      attachmentPayloads.push({
        filename: att.filename || filename,
        mime_type: att.contentType || '',
        file_path: outPath,
        text_extract: textExtract
      });
    }

    const payload = {
      message_id: parsed.messageId || String(uid),
      from_email: fromText,
      from_name: parsed.from && parsed.from.value && parsed.from.value[0] && parsed.from.value[0].name || '',
      to_email: parsed.to && parsed.to.text || '',
      subject: subjectText,
      received_at: parsed.date ? parsed.date.toISOString() : new Date().toISOString(),
      body_text: parsed.text || '',
      body_html: parsed.html || '',
      attachments: attachmentPayloads
    };

    const draft = await claireCreateIntakeDraftFromPayload(payload);
    await client.messageFlagsAdd(uid, ['\\Seen'], { uid: true });

    return { uid, from: fromText, subject: subjectText, draft };
  });
}

async function clairePickerSkipEmailUid(uid) {
  uid = Number(uid);
  if (!uid) throw new Error('Missing UID');

  return clairePickerWithMailbox(async (client, config, mailboxName) => {
    await client.messageFlagsAdd(uid, ['\\Seen'], { uid: true });
    return { uid, skipped: true };
  });
}
// END_CLAIRE_EMAIL_PICKER_V1


// CLAIRE_INTAKE_ATTACHMENT_VIEW_V1
async function claireGetInboundAttachmentForView(publicId) {
  const [[row]] = await pool.query(
    `SELECT
       a.*,
       e.public_id AS email_public_id,
       e.subject AS email_subject,
       e.from_email AS email_from
     FROM dd_inbound_email_attachments a
     LEFT JOIN dd_inbound_emails e ON e.id = a.email_id
     WHERE a.public_id = ?
     LIMIT 1`,
    [publicId]
  );
  return row || null;
}
// END_CLAIRE_INTAKE_ATTACHMENT_VIEW_V1


// CLAIRE_DOCUMENT_REREAD_V1
async function claireDocColumns(tableName) {
  const [rows] = await pool.query(`SHOW COLUMNS FROM ${tableName}`);
  return new Set(rows.map(r => r.Field));
}

function claireDocShort(value, max = 750000) {
  return String(value || '').slice(0, max);
}

function claireDocCleanLine(line) {
  return String(line || '').replace(/\s+/g, ' ').trim();
}

function claireDocMoneyToNumber(value) {
  const s = String(value || '').replace(/[^0-9.]/g, '');
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function claireDocFirstMatch(text, patterns) {
  for (const p of patterns) {
    const m = text.match(p);
    if (m && m[1]) return claireDocCleanLine(m[1]);
  }
  return '';
}

function claireDocFindPhone(text) {
  const m = String(text || '').match(/(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/);
  return m ? m[0] : '';
}

function claireDocFindEmail(text) {
  const m = String(text || '').match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
  return m ? m[0] : '';
}

function claireDocFindAddress(text) {
  const lines = String(text || '').split(/\r?\n/).map(claireDocCleanLine).filter(Boolean);

  const labeled = [
    /(?:property|premises|address|property address|subject property)\s*[:\-]\s*(.+)/i,
    /(?:location)\s*[:\-]\s*(.+)/i
  ];

  for (const line of lines) {
    for (const p of labeled) {
      const m = line.match(p);
      if (m && m[1] && /\d{1,6}\s+/.test(m[1])) return claireDocCleanLine(m[1]);
    }
  }

  const suffix = "(?:Street|St\\.?|Avenue|Ave\\.?|Road|Rd\\.?|Lane|Ln\\.?|Court|Ct\\.?|Drive|Dr\\.?|Way|Place|Pl\\.?|Trail|Trl\\.?|Boulevard|Blvd\\.?|Circle|Cir\\.?|Terrace|Ter\\.?|Turnpike|Tpke\\.?|Highway|Hwy\\.?)";
  const addressRe = new RegExp("\\b\\d{1,6}\\s+[A-Za-z0-9.' -]+\\s+" + suffix + "\\b(?:[, ]+[A-Za-z .'-]+)?(?:[, ]+NY|New York)?(?:[, ]+\\d{5})?", "i");

  for (const line of lines) {
    const m = line.match(addressRe);
    if (m && !/phone|fax|license|mls/i.test(line)) return claireDocCleanLine(m[0]);
  }

  const all = String(text || '').replace(/\s+/g, ' ');
  const m = all.match(addressRe);
  return m ? claireDocCleanLine(m[0]) : '';
}

function claireDocSection(text, labels) {
  const lines = String(text || '').split(/\r?\n/);
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const clean = claireDocCleanLine(lines[i]);
    if (!clean) continue;
    if (labels.some(label => clean.toLowerCase().includes(label.toLowerCase()))) {
      out.push(clean);
      for (let j = 1; j <= 4 && i + j < lines.length; j++) {
        const next = claireDocCleanLine(lines[i + j]);
        if (next) out.push(next);
      }
      break;
    }
  }
  return out.join("\n");
}

function claireDocNamesFromLabel(text, labelWords) {
  const lines = String(text || '').split(/\r?\n/).map(claireDocCleanLine).filter(Boolean);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const low = line.toLowerCase();
    if (!labelWords.some(w => low.includes(w))) continue;

    const afterColon = line.split(/[:\-]/).slice(1).join(' ').trim();
    if (afterColon && !/attorney|email|phone|fax|address/i.test(afterColon)) return [afterColon];

    for (let j = 1; j <= 3 && i + j < lines.length; j++) {
      const next = lines[i + j];
      if (next && !/attorney|email|phone|fax|address|price|inspection|mortgage/i.test(next)) return [next];
    }
  }

  return [];
}



// CLAIRE_MEMO_TABLE_PARSE_V1
// Parses the OneKey "Seller | Buyer" two-column table found in
// MEMORANDUM OF OFFER TO PURCHASE/SELL documents.
function claireDocParseSellerBuyerTable(text) {
  const lines = String(text || '').split(/\r?\n/);
  const out = {
    seller_names: [], purchaser_names: [],
    property_address: '',
    seller_attorney_name: '', seller_attorney_email: '', seller_attorney_phone: '',
    purchaser_attorney_name: '', purchaser_attorney_email: '', purchaser_attorney_phone: '',
    listing_agent_name: '', listing_agent_email: '', listing_agent_phone: '',
    selling_agent_name: '', selling_agent_email: '', selling_agent_phone: ''
  };

  // Find the header row "Seller ... Buyer" to confirm table presence.
  const headerIdx = lines.findIndex(l => /^\s*Seller\s+Buyer\s*$/i.test(l.trim()) || /Seller\s{3,}Buyer/i.test(l));
  if (headerIdx === -1) return out;

  // Split a row into [leftValue, rightValue] based on whitespace gap after the label.
  function splitRow(line, labelRe) {
    const m = line.match(labelRe);
    if (!m) return null;
    const rest = line.slice(m[0].length);
    const parts = rest.split(/\s{2,}/).map(s => s.trim()).filter(Boolean);
    if (parts.length >= 2) return [parts[0], parts[1]];
    if (parts.length === 1) return [parts[0], ''];
    return ['', ''];
  }

  const sellerNames = [];
  const buyerNames = [];
  let sellerAgent = '', buyerAgent = '';
  let sellerBroker = '', buyerBroker = '';

  for (let i = headerIdx; i < Math.min(headerIdx + 30, lines.length); i++) {
    const line = lines[i];

    let row = splitRow(line, /^\s*Name:\s*/i);
    if (row) { if (row[0]) sellerNames.push(row[0]); if (row[1]) buyerNames.push(row[1]); continue; }

    row = splitRow(line, /^\s*Name 2:\s*/i);
    if (row) { if (row[0]) sellerNames.push(row[0]); if (row[1]) buyerNames.push(row[1]); continue; }

    row = splitRow(line, /^\s*Address:\s*/i);
    if (row && row[1]) out._buyerAddress = row[1];
    if (row && row[0]) out._sellerAddress = row[0];

    row = splitRow(line, /^\s*City, State ZIP:\s*/i);
    if (row) {
      if (row[0] && out._sellerAddress) out._sellerFullAddress = out._sellerAddress + ', ' + row[0];
      if (row[1] && out._buyerAddress) out._buyerFullAddress = out._buyerAddress + ', ' + row[1];
    }

    row = splitRow(line, /^\s*Agent Name:\s*/i);
    if (row) { sellerAgent = row[0] || ''; buyerAgent = row[1] || ''; }

    row = splitRow(line, /^\s*Broker:\s*/i);
    if (row) { sellerBroker = row[0] || ''; buyerBroker = row[1] || ''; }

    // Attorney / Email / Phone rows appear after agent rows, single or dual column.
    row = splitRow(line, /^\s*Attorney:\s*/i);
    if (row) { out.seller_attorney_name = row[0] || out.seller_attorney_name; out.purchaser_attorney_name = row[1] || out.purchaser_attorney_name; }

    row = splitRow(line, /^\s*Email:\s*/i);
    if (row) {
      const e0 = (row[0] || '').match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
      const e1 = (row[1] || '').match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
      if (e0) out.seller_attorney_email = e0[0];
      if (e1) out.purchaser_attorney_email = e1[0];
    }

    row = splitRow(line, /^\s*Phone:\s*/i);
    if (row) {
      const p0 = (row[0] || '').match(/\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/);
      const p1 = (row[1] || '').match(/\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/);
      if (p0) out.seller_attorney_phone = p0[0];
      if (p1) out.purchaser_attorney_phone = p1[0];
    }

    // Stop once we hit "Property Location" (end of table area)
    if (/Property Location/i.test(line)) break;
  }

  if (sellerNames.length) out.seller_names = sellerNames;
  if (buyerNames.length) out.purchaser_names = buyerNames;

  if (out._buyerFullAddress) out.property_address = out._buyerFullAddress; // fallback only
  delete out._buyerAddress;
  delete out._sellerAddress;
  delete out._buyerFullAddress;
  delete out._sellerFullAddress;

  // Listing/selling agent assignment: seller-side = listing agent, buyer-side = selling agent.
  if (sellerAgent) out.listing_agent_name = sellerAgent;
  if (buyerAgent) out.selling_agent_name = buyerAgent;

  // Email/phone for buyer-side agent appear on dedicated rows after Agent Name in this layout.
  for (let i = headerIdx; i < Math.min(headerIdx + 30, lines.length); i++) {
    const line = lines[i];
    if (/Property Location/i.test(line)) break;
    const row = splitRow(line, /^\s*Email:\s*/i);
    if (row && row[1] && /@/.test(row[1]) && !out.selling_agent_email && !out.purchaser_attorney_email) {
      // ambiguous - handled above for attorney; agent email/phone for John Brady captured via section fallback
    }
  }

  return out;
}
// END_CLAIRE_MEMO_TABLE_PARSE_V1

function claireDocParseAcceptedOfferText(text) {
  const full = String(text || '');
  const one = full.replace(/\s+/g, ' ');

  function clean(v) {
    return String(v || '').replace(/\s+/g, ' ').trim();
  }

  function moneyToNumber(v) {
    if (v == null) return null;
    let s = String(v).trim();

    // Fix common OCR/form extraction typo: $1,200.000.00 -> 1200000.00
    if (/^\$?\s*\d{1,3},\d{3}\.\d{3}\.\d{2}$/.test(s)) {
      s = s.replace(/\./, ',');
    }

    s = s.replace(/[^0-9.]/g, '');
    if (!s) return null;

    const parts = s.split('.');
    if (parts.length > 2) {
      s = parts.slice(0, -1).join('') + '.' + parts[parts.length - 1];
    }

    const n = Number(s);
    return Number.isFinite(n) && n > 0 ? n : null;
  }

  function firstMatch(src, patterns) {
    for (const p of patterns) {
      const m = String(src || '').match(p);
      if (m && m[1]) return clean(m[1]);
    }
    return '';
  }

  function findPhone(src) {
    const m = String(src || '').match(/(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/);
    return m ? m[0] : '';
  }

  function findEmail(src) {
    const m = String(src || '').match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
    return m ? m[0] : '';
  }

  function lines() {
    return full.split(/\r?\n/).map(clean).filter(Boolean);
  }

  function findAddress() {
    // Strongest source first: Property Location line or value after it.
    const ls = lines();

    for (let i = 0; i < ls.length; i++) {
      if (/property location/i.test(ls[i])) {
        for (let j = 0; j <= 8 && i + j < ls.length; j++) {
          const m = ls[i + j].match(/\b\d{1,6}\s+[A-Za-z0-9.' -]+(?:Street|St\.?|Avenue|Ave\.?|Road|Rd\.?|Lane|Ln\.?|Court|Ct\.?|Drive|Dr\.?|Way|Place|Pl\.?|Trail|Trl\.?|Boulevard|Blvd\.?|Circle|Cir\.?|Terrace|Ter\.?)\b(?:[, ]+[A-Za-z .'-]+)?(?:[, ]+NY|New York)?(?:[, ]+\d{5})?/i);
          if (m) return clean(m[0]);
        }
      }
    }

    const addressRe = /\b\d{1,6}\s+[A-Za-z0-9.' -]+(?:Street|St\.?|Avenue|Ave\.?|Road|Rd\.?|Lane|Ln\.?|Court|Ct\.?|Drive|Dr\.?|Way|Place|Pl\.?|Trail|Trl\.?|Boulevard|Blvd\.?|Circle|Cir\.?|Terrace|Ter\.?)\b(?:[, ]+[A-Za-z .'-]+)?(?:[, ]+NY|New York)?(?:[, ]+\d{5})?/i;
    for (const line of ls) {
      const m = line.match(addressRe);
      if (m && !/phone|fax|license|mls|nmls|office/i.test(line)) return clean(m[0]);
    }

    const m = one.match(addressRe);
    return m ? clean(m[0]) : '';
  }

  function sectionAround(labels, span = 10) {
    const ls = lines();
    const out = [];
    for (let i = 0; i < ls.length; i++) {
      const low = ls[i].toLowerCase();
      if (labels.some(label => low.includes(label.toLowerCase()))) {
        for (let j = 0; j < span && i + j < ls.length; j++) out.push(ls[i + j]);
        break;
      }
    }
    return out.join("\n");
  }

  function namesFromLabel(labelRegexes) {
    const ls = lines();

    for (let i = 0; i < ls.length; i++) {
      const line = ls[i];
      if (!labelRegexes.some(r => r.test(line))) continue;

      const after = line.split(/[:\-]/).slice(1).join(' ').trim();
      if (after && !/attorney|email|phone|fax|address|property/i.test(after)) return [after];

      const names = [];
      for (let j = 1; j <= 4 && i + j < ls.length; j++) {
        const next = ls[i + j];
        if (/address|city|state|zip|broker|agent|attorney|email|phone|property|price|inspection|mortgage|loan/i.test(next)) break;
        if (/^[A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,4}$/.test(next)) names.push(next);
      }
      if (names.length) return names;
    }

    return [];
  }

  function memoFilledValues() {
    // OneKey memorandum PDFs often extract labels first, then all typed values in order.
    // This catches the common sequence visible in the uploaded document.
    const ls = lines();
    const idx = ls.findIndex(l => /MEMORANDUM OF OFFER TO PURCHASE\/SELL/i.test(l));
    if (idx < 0) return {};

    const values = ls.slice(idx).filter(l => {
      if (/^(REV\.|Page|MEMORANDUM|This document|BROKER COMPENSATION|THE RATE|CLIENT\.|Seller Buyer|Name:?|Name 2:?|Address:?|City, State ZIP:?|Broker:?|Broker Lic\.|Agent Name:?|Agent Lic\.|Email:?|Phone:?|Attorney:?|Property Location|OneKey|Proposed|Seller|Buyer|Signatures|Personal Property|Other|Financing|Home Inspection|Sale of Other)/i.test(l)) return false;
      if (/^[_\s]+$/.test(l)) return false;
      return true;
    });

    return { values };
  }

  function memorandumPurchasePrice() {
    const ls = lines();
    const memo = /MEMORANDUM OF OFFER TO PURCHASE\/SELL/i.test(full);

    if (memo) {
      // Prefer the first 7-figure comma number in the memorandum after proposed terms.
      const start = Math.max(0, ls.findIndex(l => /Proposed Financial Terms/i.test(l)));
      const part = ls.slice(start >= 0 ? start : 0).join("\n");

      const candidates = [];
      const re = /(?:\$?\s*)\b(\d{1,3}(?:,\d{3}){1,2})(?:\.\d{2})?\b/g;
      let m;
      while ((m = re.exec(part))) {
        const n = moneyToNumber(m[1]);
        if (n && n >= 200000 && n <= 10000000) {
          const before = part.slice(Math.max(0, m.index - 120), m.index).toLowerCase();
          const after = part.slice(m.index, m.index + 120).toLowerCase();

          // Avoid obvious loan/mortgage/down payment/broker compensation lines.
          const context = before + " " + after;
          let penalty = 0;
          if (/loan amount|mortgage amount|mortgage|pre-approved|preapproved|down payment|balance due|seller.?s payment|commission|broker|concession|net to seller|proof of funds/.test(context)) penalty += 50;
          if (/purchase price|financial terms|proposed financial/i.test(context)) penalty -= 30;
          if (n >= 700000) penalty -= 10;

          candidates.push({ n, penalty, raw: m[1], index: m.index });
        }
      }

      candidates.sort((a, b) => (a.penalty - b.penalty) || (a.index - b.index));
      if (candidates.length) return candidates[0].n;

      // Handle extracted "1,185,000" without dollar sign near the filled value area.
      const joined = ls.join(" ");
      const m2 = joined.match(/\b(\d{1,3},\d{3},\d{3})\b/);
      if (m2) return moneyToNumber(m2[1]);
    }

    const labeled = firstMatch(one, [
      /(?:purchase price|accepted price|sales price|sale price|offer price|offer amount)\s*[:\-]?\s*(\$?\s*[0-9][0-9,]*(?:[.][0-9]{2})?)/i
    ]);
    return moneyToNumber(labeled);
  }

  function preapprovalLoanInfo() {
    const pre = /pre-approved|preapproval|loan estimate|loan officer|guaranteed rate|gr affinity/i.test(full);
    if (!pre) return {};

    const offerRaw = firstMatch(one, [/Offer price\s*\$?\s*([0-9][0-9,]*(?:\.\d{2})?)/i]);
    const loanRaw = firstMatch(one, [/Loan amount\s*\$?\s*([0-9][0-9,]*(?:\.\d{2})?)/i]);
    const preRaw = firstMatch(one, [/pre-approved for\s*\$?\s*([0-9][0-9,]*(?:\.\d{2})?)/i]);

    return {
      preapproval_amount: moneyToNumber(preRaw),
      preapproval_offer_price: moneyToNumber(offerRaw),
      loan_amount: moneyToNumber(loanRaw),
      lender_name: /GR Affinity|Guaranteed Rate/i.test(full) ? 'GR Affinity / Guaranteed Rate Affinity' : '',
      loan_officer_name: firstMatch(full, [/Sincerely,\s*([A-Z][A-Za-z .'-]+)/i]),
      loan_officer_email: findEmail(full),
      loan_officer_phone: findPhone(full)
    };
  }

  const sellerAttorneySection = sectionAround(['seller attorney', "seller's attorney", 'listing attorney'], 8);
  const purchaserAttorneySection = sectionAround(['purchaser attorney', 'buyer attorney', "buyer's attorney"], 8);
  const sellerAgentSection = sectionAround(['listing agent', 'seller agent'], 8);
  const buyerAgentSection = sectionAround(['selling agent', 'buyer agent', 'purchaser agent'], 8);
  const memoValues = memoFilledValues();
  const loan = preapprovalLoanInfo();

  const extracted = {
    property_address: findAddress(),
    purchase_price: memorandumPurchasePrice(),
    seller_names: namesFromLabel([/^seller:?$/i, /^seller\(s\)/i, /seller name/i, /^sellers$/i]),
    purchaser_names: namesFromLabel([/^purchaser:?$/i, /^buyer:?$/i, /^purchaser\(s\)/i, /^buyer\(s\)/i, /buyer name/i, /^purchasers$/i, /^buyers$/i]),
    seller_attorney_name: firstMatch(sellerAttorneySection, [
      /seller'?s?\s+attorney\s*[:\-]\s*([^\n]+)/i,
      /attorney\s*[:\-]\s*([^\n]+)/i,
      /^([A-Z][A-Za-z .,'&-]{3,80})/m
    ]),
    seller_attorney_email: findEmail(sellerAttorneySection),
    seller_attorney_phone: findPhone(sellerAttorneySection),
    purchaser_attorney_name: firstMatch(purchaserAttorneySection, [
      /(?:purchaser|buyer)'?s?\s+attorney\s*[:\-]\s*([^\n]+)/i,
      /attorney\s*[:\-]\s*([^\n]+)/i,
      /^([A-Z][A-Za-z .,'&-]{3,80})/m
    ]),
    purchaser_attorney_email: findEmail(purchaserAttorneySection),
    purchaser_attorney_phone: findPhone(purchaserAttorneySection),
    listing_agent_name: firstMatch(sellerAgentSection, [
      /(?:listing|seller)\s+agent\s*[:\-]\s*([^\n]+)/i,
      /^([A-Z][A-Za-z .,'&-]{3,80})/m
    ]),
    listing_agent_email: findEmail(sellerAgentSection),
    listing_agent_phone: findPhone(sellerAgentSection),
    selling_agent_name: firstMatch(buyerAgentSection, [
      /(?:selling|buyer|purchaser)\s+agent\s*[:\-]\s*([^\n]+)/i,
      /^([A-Z][A-Za-z .,'&-]{3,80})/m
    ]),
    selling_agent_email: findEmail(buyerAgentSection),
    selling_agent_phone: findPhone(buyerAgentSection),
    inspection_status: /Home Inspection/i.test(one) && /\u2714\s*Financing\s*\u2714\s*Home Inspection|\u2713\s*Financing\s*\u2713\s*Home Inspection|Financing.{0,5}Home Inspection/i.test(one) ? 'checked' : firstMatch(one, [/inspection\s*[:\-]?\s*([A-Za-z0-9 ,.'-]{2,40})/i]),
    mortgage_status: firstMatch(one, [/Length of Proposed Financing Contingency\D{0,40}?(\d+\s*days)/i, /Financing Contingency\D{0,40}?(\d+\s*days)/i]) || firstMatch(one, [/(?:mortgage|financing|loan)\s*[:\-]?\s*([A-Za-z0-9 ,.'-]{2,40})/i]),
    property_condition_statement_status: firstMatch(one, [/(?:property condition statement|pcs)\s*[:\-]?\s*([A-Za-z0-9 ,.'-]{2,120})/i]),
    ...loan
  };

  // CLAIRE_MEMO_TABLE_OVERRIDE_V1
  const tableData = claireDocParseSellerBuyerTable(full);
  if (tableData.seller_names && tableData.seller_names.length) extracted.seller_names = tableData.seller_names;
  if (tableData.purchaser_names && tableData.purchaser_names.length) extracted.purchaser_names = tableData.purchaser_names;
  if (!extracted.seller_attorney_name && tableData.seller_attorney_name) extracted.seller_attorney_name = tableData.seller_attorney_name;
  if (!extracted.seller_attorney_email && tableData.seller_attorney_email) extracted.seller_attorney_email = tableData.seller_attorney_email;
  if (!extracted.seller_attorney_phone && tableData.seller_attorney_phone) extracted.seller_attorney_phone = tableData.seller_attorney_phone;
  if (!extracted.purchaser_attorney_name && tableData.purchaser_attorney_name) extracted.purchaser_attorney_name = tableData.purchaser_attorney_name;
  if (!extracted.purchaser_attorney_email && tableData.purchaser_attorney_email) extracted.purchaser_attorney_email = tableData.purchaser_attorney_email;
  if (!extracted.purchaser_attorney_phone && tableData.purchaser_attorney_phone) extracted.purchaser_attorney_phone = tableData.purchaser_attorney_phone;
  if (!extracted.listing_agent_name && tableData.listing_agent_name) extracted.listing_agent_name = tableData.listing_agent_name;
  if (!extracted.selling_agent_name && tableData.selling_agent_name) extracted.selling_agent_name = tableData.selling_agent_name;
  // END_CLAIRE_MEMO_TABLE_OVERRIDE_V1

  // Generic fallback for this known OneKey filled-values layout.
  if (memoValues.values && memoValues.values.length) {
    const vals = memoValues.values;

    if (!extracted.seller_names.length && vals[0] && vals[1]) {
      extracted.seller_names = [vals[0], vals[1]].filter(v => /^[A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,4}$/.test(v));
    }

    const sigIdx = vals.findIndex(v => /^Signature$/i.test(v));
    if (!extracted.purchaser_names.length && sigIdx >= 0) {
      const possible = vals.slice(sigIdx + 2, sigIdx + 4).filter(v => /^[A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,4}$/.test(v));
      if (possible.length) extracted.purchaser_names = possible;
    }

    if (!extracted.property_address) {
      const addr = vals.find(v => /\d{1,6}\s+.*(?:Street|St|Avenue|Ave|Road|Rd|Lane|Ln|Court|Ct|Drive|Dr)/i.test(v));
      if (addr) extracted.property_address = addr;
    }
  }

  Object.keys(extracted).forEach(k => {
    if (typeof extracted[k] === 'string') extracted[k] = clean(extracted[k]);
  });

  const missing = [];
  if (!extracted.property_address) missing.push('property_address');
  if (!extracted.purchase_price) missing.push('purchase_price');
  if (!extracted.seller_names || !extracted.seller_names.length) missing.push('seller_names');
  if (!extracted.purchaser_names || !extracted.purchaser_names.length) missing.push('purchaser_names');

  let score = 20;
  if (extracted.property_address) score += 22;
  if (extracted.purchase_price) score += 28;
  if (extracted.seller_names && extracted.seller_names.length) score += 12;
  if (extracted.purchaser_names && extracted.purchaser_names.length) score += 12;
  if (extracted.seller_attorney_name || extracted.seller_attorney_email) score += 3;
  if (extracted.purchaser_attorney_name || extracted.purchaser_attorney_email) score += 3;

  // Never claim high confidence when required fields are missing.
  if (missing.includes('purchase_price')) score = Math.min(score, 72);
  if (missing.includes('property_address')) score = Math.min(score, 70);
  if (missing.length >= 2) score = Math.min(score, 65);

  return {
    extracted,
    missing_fields: missing,
    confidence_score: Math.max(0, Math.min(score, 98))
  };
}


// CLAIRE_REREAD_INTAKE_DOCUMENTS_V1
async function claireRereadIntakeDraftDocuments(publicId) {
  const fs = require('fs');

  const [[draft]] = await pool.query(
    `SELECT * FROM dd_intake_drafts WHERE public_id = ? LIMIT 1`,
    [publicId]
  );
  if (!draft) return null;

  const [attachments] = await pool.query(
    `SELECT * FROM dd_inbound_email_attachments WHERE email_id = ? ORDER BY id`,
    [draft.inbound_email_id]
  );

  async function ensureText(att) {
    if (att.text_extract && att.text_extract.trim() && !/^\[PDF text extraction failed/.test(att.text_extract.trim())) return att.text_extract;
    if (!att.file_path || !fs.existsSync(att.file_path)) return '';
    try {
      const buf = fs.readFileSync(att.file_path);
      if ((att.mime_type || '').includes('pdf') || /\.pdf$/i.test(att.filename || '')) {
        const { PDFParse } = require('pdf-parse');
        const parser = new PDFParse({ data: buf });
        const result = await parser.getText();
        await parser.destroy();
        const text = claireDocShort(result.text || '');
        await pool.query(
          `UPDATE dd_inbound_email_attachments SET text_extract = ? WHERE id = ?`,
          [text, att.id]
        );
        return text;
      }
      return '';
    } catch (err) {
      return '[PDF text extraction failed: ' + err.message + ']';
    }
  }

  let memoText = '';
  let preapprovalText = '';

  for (const att of attachments) {
    const text = await ensureText(att);
    const name = String(att.filename || '').toLowerCase();
    const isMemo = /memorandum|offer.*purchase|purchase.*sell/i.test(name) ||
      /MEMORANDUM OF OFFER TO PURCHASE/i.test(text);
    const isPreapproval = /preapproval|pre-approval|pre approved/i.test(name) ||
      /pre-approved|loan estimate|guaranteed rate|gr affinity/i.test(text);

    if (isMemo && !memoText) {
      memoText = text;
    } else if (isPreapproval && !preapprovalText) {
      preapprovalText = text;
    } else if (!memoText) {
      memoText = text;
    }
  }

  const primaryText = memoText || preapprovalText || '';
  const parsed = claireDocParseAcceptedOfferText(primaryText);
  const extracted = parsed.extracted || {};

  // Merge preapproval-only loan/financing info if not already present.
  if (preapprovalText) {
    const preParsed = claireDocParseAcceptedOfferText(preapprovalText);
    const preExtracted = preParsed.extracted || {};
    for (const key of ['preapproval_amount', 'preapproval_offer_price', 'loan_amount', 'lender_name', 'loan_officer_name', 'loan_officer_email', 'loan_officer_phone']) {
      if (!extracted[key] && preExtracted[key]) extracted[key] = preExtracted[key];
    }
  }

  const missing = parsed.missing_fields || [];
  const confidence = parsed.confidence_score || 0;

  await pool.query(
    `UPDATE dd_intake_drafts
     SET extracted_json = ?,
         property_address = ?,
         confidence_score = ?,
         missing_fields_json = ?,
         updated_at = NOW()
     WHERE public_id = ?`,
    [
      JSON.stringify(extracted),
      extracted.property_address || draft.property_address || null,
      confidence,
      JSON.stringify(missing),
      publicId
    ]
  );

  return {
    public_id: publicId,
    property_address: extracted.property_address || draft.property_address || null,
    confidence_score: confidence,
    extracted_json: extracted,
    missing_fields_json: missing
  };
}
// END_CLAIRE_REREAD_INTAKE_DOCUMENTS_V1

  // END_CLAIRE_INTAKE_ATTACHMENT_VIEW_ROUTES_V1

// DEALDESK_RESTORED_HANDLE_REQUEST_WRAPPER_V1
async function handleRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  // Serve static files from frontend folder
  if (req.method === 'GET' && !url.pathname.startsWith('/api/')) {
    const fs = require('fs');
    const path = require('path');
    
    let filePath = url.pathname;
    if (filePath === '/' || filePath === '') filePath = '/index.html';
    
    // Use FRONTEND_PATH from .env or default to ../frontend
    const frontendBase = process.env.FRONTEND_PATH 
      ? path.resolve(__dirname, process.env.FRONTEND_PATH)
      : path.join(__dirname, '..', 'frontend');
    
    const fullPath = path.join(frontendBase, filePath);
    
    if (fs.existsSync(fullPath) && fs.statSync(fullPath).isFile()) {
      const ext = path.extname(fullPath).toLowerCase();
      const mimeTypes = {
        '.html': 'text/html',
        '.css': 'text/css',
        '.js': 'text/javascript',
        '.png': 'image/png',
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.svg': 'image/svg+xml'
      };
      
      res.writeHead(200, { 'Content-Type': mimeTypes[ext] || 'application/octet-stream' });
      fs.createReadStream(fullPath).pipe(res);
      return;
    }
  }
// END_DEALDESK_RESTORED_HANDLE_REQUEST_WRAPPER_V1
// CLAIRE_REREAD_AND_ATTACHMENT_VIEW_ROUTES_V1
  const claireIntakeAttachmentViewMatch =
    url.pathname.match(/^\/api\/intake-attachments\/([^/]+)\/view$/) ||
    url.pathname.match(/^\/api\/dealdesk\/intake-attachments\/([^/]+)\/view$/) ||
    url.pathname.match(/^\/api\/email-intake\/attachments\/([^/]+)\/view$/) ||
    url.pathname.match(/^\/api\/dealdesk\/email-intake\/attachments\/([^/]+)\/view$/);

  if (req.method === 'GET' && claireIntakeAttachmentViewMatch) {
    const fsv = require('fs');
    const att = await claireGetInboundAttachmentForView(claireIntakeAttachmentViewMatch[1]);
    if (!att || !att.file_path || !fsv.existsSync(att.file_path)) {
      sendJson(res, 404, { ok: false, error: 'Attachment not found' });
      return;
    }
    const mime = att.mime_type || 'application/octet-stream';
    const name = att.filename || 'document';
    res.writeHead(200, {
      'Content-Type': mime,
      'Content-Disposition': 'inline; filename="' + String(name).replace(/"/g, '') + '"',
      'Cache-Control': 'private, max-age=60'
    });
    fsv.createReadStream(att.file_path).pipe(res);
    return;
  }

  const claireRereadDocsMatch =
    url.pathname.match(/^\/api\/intake-drafts\/([^/]+)\/reread-documents$/) ||
    url.pathname.match(/^\/api\/dealdesk\/intake-drafts\/([^/]+)\/reread-documents$/);

  if (req.method === 'POST' && claireRereadDocsMatch) {
    const result = await claireRereadIntakeDraftDocuments(claireRereadDocsMatch[1]);
    if (!result) {
      sendJson(res, 404, { ok: false, error: 'Intake draft not found' });
      return;
    }
    sendJson(res, 200, { ok: true, draft: result });
    return;
  }
// END_CLAIRE_REREAD_AND_ATTACHMENT_VIEW_ROUTES_V1

// CLAIRE_CREATE_DEAL_DOCUMENTS_ROUTES_V1
  const claireCreateDealMatch =
    url.pathname.match(/^\/api\/dealdesk\/intake-drafts\/([^/]+)\/create-deal$/) ||
    url.pathname.match(/^\/api\/intake-drafts\/([^/]+)\/create-deal$/);

  if (req.method === 'POST' && claireCreateDealMatch) {
    const body = await readJsonBody(req);
    const result = await claireCreateDealFromDraft(
      claireCreateDealMatch[1],
      cleanText(body.created_by || body.reviewed_by || 'operator')
    );
    sendJson(res, 200, { ok: true, ...result });
    return;
  }

  const claireDealDocumentsMatch =
    url.pathname.match(/^\/api\/dealdesk\/deals\/([^/]+)\/documents$/) ||
    url.pathname.match(/^\/api\/deals\/([^/]+)\/documents$/);

  if (req.method === 'GET' && claireDealDocumentsMatch) {
    const result = await claireListDealDocuments(claireDealDocumentsMatch[1]);
    if (!result.deal) {
      sendJson(res, 404, { ok: false, error: 'Deal not found' });
      return;
    }
    sendJson(res, 200, { ok: true, deal: result.deal, documents: result.documents });
    return;
  }

  const claireDocumentViewMatch =
    url.pathname.match(/^\/api\/dealdesk\/deal-documents\/([^/]+)\/view$/) ||
    url.pathname.match(/^\/api\/deal-documents\/([^/]+)\/view$/);

  if (req.method === 'GET' && claireDocumentViewMatch) {
    const fs = require('fs');
    const path = require('path');

    const doc = await claireGetDocumentForView(claireDocumentViewMatch[1]);
    if (!doc || !doc.file_path || !fs.existsSync(doc.file_path)) {
      sendJson(res, 404, { ok: false, error: 'Document not found' });
      return;
    }

    const mime = 'application/pdf';
    const name = doc.document_title || 'document';

    res.writeHead(200, {
      'Content-Type': mime,
      'Content-Disposition': 'inline; filename="' + String(name).replace(/"/g, '') + '"',
      'Cache-Control': 'private, max-age=60'
    });

    fs.createReadStream(doc.file_path).pipe(res);
    return;
  }
  // END_CLAIRE_CREATE_DEAL_DOCUMENTS_ROUTES_V1


  // CLAIRE_EMAIL_TO_INTAKE_API_ROUTES_V1
  const claireEmailUidImportMatch =
    url.pathname.match(/^\/api\/email-intake\/messages\/([^/]+)\/import$/) ||
    url.pathname.match(/^\/api\/dealdesk\/email-intake\/messages\/([^/]+)\/import$/);

  if (req.method === 'POST' && claireEmailUidImportMatch) {
    const uid = claireEmailUidImportMatch[1];
    try {
      const result = await clairePickerImportEmailUid(uid);
      sendJson(res, 200, { ok: true, ...result });
    } catch (err) {
      sendJson(res, 500, { ok: false, error: err.message });
    }
    return;
  }

  if (req.method === 'GET' && (url.pathname === '/api/dealdesk/email-intake/messages' || url.pathname === '/api/email-intake/messages')) {
    const limit = Number(url.searchParams.get('limit') || 25);
    const result = await clairePickerListEmails(limit);
    sendJson(res, 200, { ok: true, ...result });
    return;
  }

  if (req.method === 'POST' && (url.pathname === '/api/dealdesk/email-intake/import' || url.pathname === '/api/email-intake/import')) {
    const remote = String(req.socket && req.socket.remoteAddress || '');
    const localOnly = remote === '127.0.0.1' || remote === '::1' || remote.endsWith('127.0.0.1');
    if (!localOnly) { sendJson(res, 403, { ok: false, error: 'Email intake import is local-only' }); return; }
    const body = await readJsonBody(req);
    const draft = await claireCreateIntakeDraftFromPayload(body);
    sendJson(res, 200, { ok: true, draft });
    return;
  }
  if (req.method === 'GET' && (url.pathname === '/api/dealdesk/intake-drafts' || url.pathname === '/api/intake-drafts')) {
    const drafts = await listClaireIntakeDrafts();
    sendJson(res, 200, { ok: true, drafts });
    return;
  }
  const claireDraftReadMatch = url.pathname.match(/^\/api\/dealdesk\/intake-drafts\/([^/]+)$/) || url.pathname.match(/^\/api\/intake-drafts\/([^/]+)$/);
  if (req.method === 'GET' && claireDraftReadMatch) {
    const draft = await getClaireIntakeDraft(claireDraftReadMatch[1]);
    if (!draft) { sendJson(res, 404, { ok: false, error: 'Intake draft not found' }); return; }
    sendJson(res, 200, { ok: true, draft });
    return;
  }
  const claireDraftStatusMatch = url.pathname.match(/^\/api\/dealdesk\/intake-drafts\/([^/]+)\/status$/) || url.pathname.match(/^\/api\/intake-drafts\/([^/]+)\/status$/);
  if (req.method === 'POST' && claireDraftStatusMatch) {
    const body = await readJsonBody(req);
    const draft = await updateClaireIntakeDraftStatus(claireDraftStatusMatch[1], cleanText(body.draft_status || body.status), cleanText(body.reviewed_by || body.updated_by || 'operator'));
    if (!draft) { sendJson(res, 404, { ok: false, error: 'Intake draft not found' }); return; }
    sendJson(res, 200, { ok: true, draft });
    return;
  }
  const claireDraftRejectMatch = url.pathname.match(/^\/api\/dealdesk\/intake-drafts\/([^/]+)\/reject$/) || url.pathname.match(/^\/api\/intake-drafts\/([^/]+)\/reject$/);
  if (req.method === 'POST' && claireDraftRejectMatch) {
    const body = await readJsonBody(req);
    const draft = await updateClaireIntakeDraftStatus(claireDraftRejectMatch[1], 'Rejected', cleanText(body.reviewed_by || body.updated_by || 'operator'));
    if (!draft) { sendJson(res, 404, { ok: false, error: 'Intake draft not found' }); return; }
    sendJson(res, 200, { ok: true, draft });
    return;
  }
  if (req.method === 'POST' && (url.pathname === '/api/dealdesk/intake-drafts' || url.pathname === '/api/intake-drafts')) {
    const body = await readJsonBody(req);
    const draft = await claireCreateIntakeDraftFromPayload(body);
    sendJson(res, 200, { ok: true, draft });
    return;
  }
  // END_CLAIRE_EMAIL_TO_INTAKE_API_ROUTES_V1

  // CLEARANCE_CONTROLS_API_ROUTE_V1
  const clearanceControlsListMatch =
    url.pathname.match(/^\/api\/dealdesk\/deals\/([^/]+)\/clearance-controls$/) ||
    url.pathname.match(/^\/api\/deals\/([^/]+)\/clearance-controls$/);

  if (req.method === 'GET' && clearanceControlsListMatch) {
    const data = await getDealClearanceControls(clearanceControlsListMatch[1]);
    sendJson(res, 200, {
      ok: true,
      ...data
    });
    return;
  }



  const clearanceDraftEmailShortMatch =
    url.pathname.match(/^\/api\/dealdesk\/deals\/([^/]+)\/clearance-draft-email$/) ||
    url.pathname.match(/^\/api\/deals\/([^/]+)\/clearance-draft-email$/);

  if (req.method === 'POST' && clearanceDraftEmailShortMatch) {
    const body = await readJsonBody(req);
    const taskPublicId = cleanText(body.task_public_id || body.task_id || body.clearance_task_id);
    if (!taskPublicId) {
      sendJson(res, 400, { ok: false, error: 'Missing clearance task id' });
      return;
    }

    const draft = await createClearanceDraftEmail(clearanceDraftEmailShortMatch[1], taskPublicId, body);
    if (!draft) {
      sendJson(res, 404, { ok: false, error: 'Deal or clearance item not found' });
      return;
    }

    sendJson(res, 200, { ok: true, draft });
    return;
  }

  const clearanceDraftEmailMatch =
    url.pathname.match(/^\/api\/dealdesk\/deals\/([^/]+)\/clearance-controls\/([^/]+)\/draft-email$/) ||
    url.pathname.match(/^\/api\/deals\/([^/]+)\/clearance-controls\/([^/]+)\/draft-email$/);

  if (req.method === 'POST' && clearanceDraftEmailMatch) {
    const body = await readJsonBody(req);
    const draft = await createClearanceDraftEmail(clearanceDraftEmailMatch[1], clearanceDraftEmailMatch[2], body);
    if (!draft) {
      sendJson(res, 404, {
        ok: false,
        error: 'Deal or clearance item not found'
      });
      return;
    }

    sendJson(res, 200, {
      ok: true,
      draft
    });
    return;
  }

  const clearanceControlsUpdateMatch =
    url.pathname.match(/^\/api\/dealdesk\/deals\/([^/]+)\/clearance-controls\/([^/]+)$/) ||
    url.pathname.match(/^\/api\/deals\/([^/]+)\/clearance-controls\/([^/]+)$/);

  if (req.method === 'POST' && clearanceControlsUpdateMatch) {
    const body = await readJsonBody(req);
    const data = await updateDealClearanceControl(clearanceControlsUpdateMatch[1], clearanceControlsUpdateMatch[2], body);
    sendJson(res, 200, {
      ok: true,
      ...data
    });
    return;
  }

// SMART_MANAGER_CHAT_ROUTE_V3_AFTER_URL_INIT

  // MANAGER_CHAT_QUESTIONS_REVIEW_ROUTE
  if (req.method === 'GET' && (
    url.pathname === '/api/dealdesk/manager-chat-questions' ||
    url.pathname === '/api/manager-chat-questions'
  )) {
    const [rows] = await pool.query(
      `SELECT
         public_id,
         question,
         answer_preview,
         answer_mode,
         matched_rule,
         error_message,
         duration_ms,
         created_by,
         feedback_status,
         feedback_notes,
         created_at
       FROM dd_manager_chat_questions
       ORDER BY created_at DESC
       LIMIT 200`
    );

    sendJson(res, 200, {
      ok: true,
      questions: rows
    });
    return;
  }

  if (req.method === 'POST' && (
    url.pathname === '/api/dealdesk/manager-chat-smart' ||
    url.pathname === '/api/manager-chat-smart'
  )) {
    const body = await readJsonBody(req);
    const startedAt = Date.now();

    try {
      const reply = (typeof answerSmartManagerChat === 'function')
        ? await answerSmartManagerChat(body)
        : await answerManagerChat(body);

      await logManagerChatQuestion({
        question: body.question,
        answer: reply.answer,
        answer_mode: reply.mode,
        matched_rule: classifyManagerChatQuestion(body.question),
        snapshot_time: reply.snapshot_time,
        duration_ms: Date.now() - startedAt,
        created_by: body.created_by
      });

      sendJson(res, 200, {
        ok: true,
        reply
      });
      return;
    } catch (err) {
      await logManagerChatQuestion({
        question: body.question,
        answer: null,
        answer_mode: 'failed',
        matched_rule: classifyManagerChatQuestion(body.question),
        snapshot_time: null,
        error_message: err.message,
        duration_ms: Date.now() - startedAt,
        created_by: body.created_by
      });

      throw err;
    }
  }

if (req.method === 'GET' && url.pathname === '/api/dealdesk/health') {
    const [[dbRow]] = await pool.query('SELECT 1 AS ok');
    sendJson(res, 200, {
      ok: true,
      app: 'Accepted Offer to Close',
      service: 'dealdesk-backend',
      database: dbRow.ok === 1 ? 'connected' : 'unknown',
      status: 'private backend ready'
    });
    return;
  }


  const managerChatMatch = url.pathname.match(/^\/api\/dealdesk\/manager-chat$/);
  if (req.method === 'POST' && managerChatMatch) {
    const body = await readJsonBody(req);
    const reply = await answerManagerChat(body);

    sendJson(res, 200, {
      ok: true,
      reply
    });
    return;
  }

  if (url.pathname.startsWith('/api/dev-agent/')) {
    const token = req.headers['x-dev-agent-token'];
    const expected = process.env.DEALDESK_DEV_AGENT_TOKEN;
    const remote = String(req.socket && req.socket.remoteAddress || '');
    const isLocal = remote === '127.0.0.1' || remote === '::1' || remote.endsWith('127.0.0.1');

    if (!isLocal && (!token || token !== expected)) {
      sendJson(res, 401, { ok: false, error: 'Unauthorized: Invalid Dev Agent Token' });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/dev-agent/chat') {
      const body = await readJsonBody(req);
      const prompt = cleanText(body.prompt);
      const history = Array.isArray(body.history) ? body.history : [];

      if (!prompt) {
        sendJson(res, 400, { ok: false, error: 'Prompt is required' });
        return;
      }

      try {
        const result = await callDevAgentOpenAi(prompt, history);
        sendJson(res, 200, {
          ok: true,
          answer: result.answer,
          audit_id: result.audit_id
        });
      } catch (err) {
        sendJson(res, 500, { ok: false, error: err.message });
      }
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/dev-agent/audit') {
      try {
        const [rows] = await pool.query(
          `SELECT id, public_id, user_prompt, tool_name, tool_args_json, tool_result_preview, allowed, blocked_reason, created_by, created_at 
           FROM dd_dev_agent_audit 
           ORDER BY created_at DESC 
           LIMIT 50`
        );
        sendJson(res, 200, { ok: true, audit: rows });
      } catch (err) {
        sendJson(res, 500, { ok: false, error: err.message });
      }
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/dev-agent/pending') {
      const list = Array.from(pendingActions.values())
        .filter(a => a.status === 'pending')
        .map(a => ({
          id: a.id,
          type: a.type,
          details: a.details,
          user_prompt: a.user_prompt,
          created_at: a.created_at
        }));
      sendJson(res, 200, { ok: true, pending: list });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/dev-agent/approve') {
      const body = await readJsonBody(req);
      const { action_id } = body;
      if (!action_id || !pendingActions.has(action_id)) {
        sendJson(res, 404, { ok: false, error: 'Action not found or already processed' });
        return;
      }
      const action = pendingActions.get(action_id);
      action.status = 'approved';
      pendingActions.delete(action_id);
      action.resolve(true);
      sendJson(res, 200, { ok: true });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/dev-agent/reject') {
      const body = await readJsonBody(req);
      const { action_id, reason } = body;
      if (!action_id || !pendingActions.has(action_id)) {
        sendJson(res, 404, { ok: false, error: 'Action not found or already processed' });
        return;
      }
      const action = pendingActions.get(action_id);
      action.status = 'rejected';
      pendingActions.delete(action_id);
      action.reject(new Error(reason || 'Rejected by developer.'));
      sendJson(res, 200, { ok: true });
      return;
    }
  }

  if (req.method === 'GET' && url.pathname === '/api/dealdesk/dashboard') {
    const dashboard = await getDashboard();
    sendJson(res, 200, {
      ok: true,
      dashboard
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/dealdesk/deals') {
    const [rows] = await pool.query(
      `SELECT
         d.public_id,
         d.accepted_offer_date,
         d.mls_number,
         d.property_address,
         d.transaction_status,
         d.next_action,
         d.created_at,
         d.updated_at,
         (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'seller' LIMIT 1) AS seller_name,
         (SELECT p.display_name FROM dd_deal_parties p WHERE p.deal_id = d.id AND p.role_key = 'purchaser' LIMIT 1) AS purchaser_name,
        (SELECT COUNT(*) FROM dd_transaction_tasks t
         WHERE t.deal_id = d.id
           AND LOWER(COALESCE(t.control_state,'open')) NOT IN ('complete','completed','not_applicable','not applicable','na','n/a')
       ) AS waiting_on_count,
        (SELECT COUNT(*) FROM dd_transaction_tasks t
         WHERE t.deal_id = d.id
           AND LOWER(COALESCE(t.control_state,'')) IN ('needs_followup','needs follow-up','needs_follow_up','blocked')
       ) AS blocked_count,
        (SELECT MIN(t.due_date) FROM dd_transaction_tasks t WHERE t.deal_id = d.id AND t.status IN ('Waiting','In Progress','Blocked') AND t.due_date IS NOT NULL) AS next_due_date,
        (SELECT t.task_name FROM dd_transaction_tasks t WHERE t.deal_id = d.id AND t.status IN ('Waiting','In Progress','Blocked') ORDER BY t.due_date IS NULL, t.due_date, t.created_at DESC LIMIT 1) AS next_waiting_on,
        (SELECT COUNT(*) FROM dd_transaction_tasks t
         WHERE t.deal_id = d.id
           AND LOWER(COALESCE(t.control_state,'open')) NOT IN ('complete','completed','not_applicable','not applicable','na','n/a')
       ) AS waiting_on_count,
        (SELECT COUNT(*) FROM dd_transaction_tasks t
         WHERE t.deal_id = d.id
           AND LOWER(COALESCE(t.control_state,'')) IN ('needs_followup','needs follow-up','needs_follow_up','blocked')
       ) AS blocked_count,
        (SELECT MIN(t.due_date) FROM dd_transaction_tasks t WHERE t.deal_id = d.id AND t.status IN ('Waiting','In Progress','Blocked') AND t.due_date IS NOT NULL) AS next_due_date,
        (SELECT t.task_name FROM dd_transaction_tasks t WHERE t.deal_id = d.id AND t.status IN ('Waiting','In Progress','Blocked') ORDER BY t.due_date IS NULL, t.due_date, t.created_at DESC LIMIT 1) AS next_waiting_on
       FROM dd_deals d
       WHERE d.removed_at IS NULL
       ORDER BY d.created_at DESC
       LIMIT 50`
    );

    sendJson(res, 200, {
      ok: true,
      deals: rows
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/dealdesk/deals') {
    const body = await readJsonBody(req);
    const deal = await createDeal(body);

    let transactionPlan = null;

    if (deal && deal.public_id && typeof buildTransactionPlan === 'function') {
      try {
        transactionPlan = await buildTransactionPlan(deal.public_id, {
          created_by: cleanText(body.created_by) || 'system'
        });
      } catch (err) {
        transactionPlan = {
          error: err.message
        };
      }
    }

    sendJson(res, 201, {
      ok: true,
      deal,
      transaction_plan: transactionPlan,
      auto_plan_created: Boolean(transactionPlan && !transactionPlan.error)
    });
    return;
  }


  if (req.method === 'GET' && url.pathname === '/api/dealdesk/directory') {
    const contacts = await listDirectoryContacts(url);
    sendJson(res, 200, {
      ok: true,
      contacts
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/dealdesk/directory') {
    const body = await readJsonBody(req);
    const contact = await createDirectoryContact(body);
    sendJson(res, 201, {
      ok: true,
      contact
    });
    return;
  }







  const communicationMatch = url.pathname.match(/^\/api\/dealdesk\/deals\/([0-9a-fA-F-]{36})\/communications$/);
  if (req.method === 'POST' && communicationMatch) {
    const body = await readJsonBody(req);
    const entry = await createCommunicationLog(communicationMatch[1], body);
    if (!entry) {
      sendJson(res, 404, {
        ok: false,
        error: 'Deal not found'
      });
      return;
    }

    sendJson(res, 201, {
      ok: true,
      communication: entry
    });
    return;
  }

  const buildPlanMatch = url.pathname.match(/^\/api\/dealdesk\/deals\/([0-9a-fA-F-]{36})\/build-plan$/);
  if (req.method === 'POST' && buildPlanMatch) {
    const body = await readJsonBody(req);
    const plan = await buildTransactionPlan(buildPlanMatch[1], body);
    if (!plan) {
      sendJson(res, 404, {
        ok: false,
        error: 'Deal not found'
      });
      return;
    }

    sendJson(res, 201, {
      ok: true,
      plan
    });
    return;
  }

  const statusUpdateMatch = url.pathname.match(/^\/api\/dealdesk\/deals\/([0-9a-fA-F-]{36})\/status$/);
  if (req.method === 'POST' && statusUpdateMatch) {
    const body = await readJsonBody(req);
    const deal = await updateDealStatus(statusUpdateMatch[1], body);
    if (!deal) {
      sendJson(res, 404, {
        ok: false,
        error: 'Deal not found'
      });
      return;
    }

    sendJson(res, 200, {
      ok: true,
      deal
    });
    return;
  }

  const startEmailMatch = url.pathname.match(/^\/api\/dealdesk\/deals\/([0-9a-fA-F-]{36})\/start-emails$/);
  if (req.method === 'POST' && startEmailMatch) {
    const body = await readJsonBody(req);
    const emails = await createStartEmails(startEmailMatch[1], body);
    if (!emails) {
      sendJson(res, 404, {
        ok: false,
        error: 'Deal not found'
      });
      return;
    }

    sendJson(res, 201, {
      ok: true,
      emails
    });
    return;
  }

  const sendEmailMatch = url.pathname.match(/^\/api\/dealdesk\/emails\/([0-9a-fA-F-]{36})\/send$/);
  if (req.method === 'POST' && sendEmailMatch) {
    const body = await readJsonBody(req);
    const sent = await sendEmailMessage(sendEmailMatch[1], body);
    if (!sent) {
      sendJson(res, 404, {
        ok: false,
        error: 'Email not found'
      });
      return;
    }

    sendJson(res, 200, {
      ok: true,
      sent
    });
    return;
  }


  const trackerUpdateMatch = url.pathname.match(/^\/api\/dealdesk\/deals\/([0-9a-fA-F-]{36})\/tracker\/([0-9a-fA-F-]{36})\/update$/);
  if (req.method === 'POST' && trackerUpdateMatch) {
    const body = await readJsonBody(req);
    const task = await updateTransactionTask(trackerUpdateMatch[1], trackerUpdateMatch[2], body);
    if (!task) {
      sendJson(res, 404, {
        ok: false,
        error: 'Tracker item not found'
      });
      return;
    }

    sendJson(res, 200, {
      ok: true,
      task
    });
    return;
  }

  const trackerMatch = url.pathname.match(/^\/api\/dealdesk\/deals\/([0-9a-fA-F-]{36})\/tracker$/);
  if (req.method === 'POST' && trackerMatch) {
    const body = await readJsonBody(req);
    const task = await createTransactionTask(trackerMatch[1], body);
    if (!task) {
      sendJson(res, 404, {
        ok: false,
        error: 'Deal not found'
      });
      return;
    }

    sendJson(res, 201, {
      ok: true,
      task
    });
    return;
  }

  const aiReviewMatch = url.pathname.match(/^\/api\/dealdesk\/deals\/([0-9a-fA-F-]{36})\/ai-review$/);
  if (req.method === 'POST' && aiReviewMatch) {
    const body = await readJsonBody(req);
    const review = await createAiReview(aiReviewMatch[1], body);
    if (!review) {
      sendJson(res, 404, {
        ok: false,
        error: 'Deal not found'
      });
      return;
    }

    sendJson(res, 201, {
      ok: true,
      generated_item: review
    });
    return;
  }

  const dealMatch = url.pathname.match(/^\/api\/dealdesk\/deals\/([0-9a-fA-F-]{36})$/);

  if (req.method === 'DELETE' && dealMatch) {
    const body = await readJsonBody(req);
    const removed = await removeDeal(dealMatch[1], body);
    if (!removed) {
      sendJson(res, 404, {
        ok: false,
        error: 'Deal not found'
      });
      return;
    }

    sendJson(res, 200, {
      ok: true,
      removed
    });
    return;
  }

  if (req.method === 'GET' && dealMatch) {
    const deal = await getDeal(dealMatch[1]);
    if (!deal) {
      sendJson(res, 404, {
        ok: false,
        error: 'Deal not found'
      });
      return;
    }

    sendJson(res, 200, {
      ok: true,
      record: deal
    });
    return;
  }

  sendJson(res, 404, {
    ok: false,
    error: 'Not found'
  });
}

const server = http.createServer((req, res) => {
  handleRequest(req, res).catch((err) => {
    sendJson(res, err.statusCode || 500, {
      ok: false,
      error: err.message
    });
  });
});

server.listen(PORT, HOST, () => {
  console.log(`dealdesk-backend listening on http://${HOST}:${PORT}`);
});
