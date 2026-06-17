#!/usr/bin/env bash
# Deal Desk Interactive Server Installer & Deployer
# This script can be run on a fresh server to setup the environment.

set -e

echo "==============================================="
echo "   Deal Desk Interactive Server Installer      "
echo "==============================================="

# Helper function to load environment variables from an existing .env file
load_env_file() {
    local env_file="$1"
    if [ -f "$env_file" ]; then
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            # Strip carriage returns and leading/trailing whitespace
            key=$(echo "$key" | tr -d '\r' | xargs)
            value=$(echo "$value" | tr -d '\r' | xargs | sed -e 's/^["'\'']//' -e 's/["'\'']$//')
            if [[ ! -z "$key" && ! "$key" =~ ^# ]]; then
                case "$key" in
                    DB_HOST) DB_HOST="$value" ;;
                    DB_USER) DB_USER="$value" ;;
                    DB_PASSWORD) DB_PASSWORD="$value" ;;
                    DB_NAME) DB_NAME="$value" ;;
                    DEALDESK_PORT) SERVER_PORT="$value" ;;
                    DEALDESK_HOST) DEALDESK_HOST="$value" ;;
                    BACKEND_PATH) TARGET_BACKEND="$value" ;;
                    FRONTEND_PATH) TARGET_FRONTEND="$value" ;;
                    PM2_NAME) PM2_NAME="$value" ;;
                    SYS_USER) SYS_USER="$value" ;;
                    SYS_GROUP) SYS_GROUP="$value" ;;
                esac
            fi
        done < "$env_file"
        return 0
    fi
    return 1
}

# Detect existing installation
EXISTING_ENV=""
if [ -f "backend/.env" ]; then
    EXISTING_ENV="backend/.env"
elif [ -f "/home/servicedepartmen/dealdesk-backend-2/backend/.env" ]; then
    EXISTING_ENV="/home/servicedepartmen/dealdesk-backend-2/backend/.env"
fi

IS_UPDATE=false

if [ ! -z "$EXISTING_ENV" ]; then
    echo "------------------------------------------------"
    echo "Found existing Deal Desk configuration in:"
    echo "  $EXISTING_ENV"
    echo "------------------------------------------------"
    read -p "Would you like to run an UPDATE/DEPLOYMENT using this configuration? [Y/n]: " opt
    opt=${opt:-Y}
    if [[ "$opt" =~ ^[Yy]$ ]]; then
        IS_UPDATE=true
        load_env_file "$EXISTING_ENV"
        TARGET_BACKEND=${TARGET_BACKEND:-/home/servicedepartmen/dealdesk-backend-2}
        TARGET_FRONTEND=${TARGET_FRONTEND:-/home/servicedepartmen/public_html/dealdesk-2}
        PM2_NAME=${PM2_NAME:-$(basename "$TARGET_BACKEND")}
        SERVER_PORT=${SERVER_PORT:-3017}
        
        # Load user/group defaults in update mode if not in env
        DEFAULT_USER=$(logname 2>/dev/null || echo $SUDO_USER || whoami)
        DEFAULT_GROUP=$(id -gn "$DEFAULT_USER" 2>/dev/null || echo "$DEFAULT_USER")
        SYS_USER=${SYS_USER:-$DEFAULT_USER}
        SYS_GROUP=${SYS_GROUP:-$DEFAULT_GROUP}

        echo "Loaded existing configuration:"
        echo "  Backend Path:  $TARGET_BACKEND"
        echo "  Frontend Path: $TARGET_FRONTEND"
        echo "  Database Name: $DB_NAME"
        echo "  Server Port:   $SERVER_PORT"
        echo "  PM2 Name:      $PM2_NAME"
        echo "  System Owner:  $SYS_USER:$SYS_GROUP"
        echo ""
    fi
fi

if [ "$IS_UPDATE" = false ]; then
    # 1. Gather Information Interactively
    read -p "GitHub Repository URL [https://github.com/user/repo.git]: " GIT_REPO
    read -p "Target Backend Path [/home/servicedepartmen/dealdesk-backend-2]: " TARGET_BACKEND
    TARGET_BACKEND=${TARGET_BACKEND:-/home/servicedepartmen/dealdesk-backend-2}

    read -p "Target Frontend Path [/home/servicedepartmen/public_html/dealdesk-2]: " TARGET_FRONTEND
    TARGET_FRONTEND=${TARGET_FRONTEND:-/home/servicedepartmen/public_html/dealdesk-2}

    read -p "PM2 Process Name [dealdesk-backend-2]: " PM2_NAME
    PM2_NAME=${PM2_NAME:-dealdesk-backend-2}

    read -p "Server Port [3017]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-3017}

    read -p "Database Host [localhost]: " DB_HOST
    DB_HOST=${DB_HOST:-localhost}

    read -p "Database Name: " DB_NAME
    read -p "Database User: " DB_USER
    read -s -p "Database Password: " DB_PASSWORD
    echo ""

    # Gather System User & Group
    DEFAULT_USER=$(logname 2>/dev/null || echo $SUDO_USER || whoami)
    DEFAULT_GROUP=$(id -gn "$DEFAULT_USER" 2>/dev/null || echo "$DEFAULT_USER")

    read -p "System Owner User [$DEFAULT_USER]: " SYS_USER
    SYS_USER=${SYS_USER:-$DEFAULT_USER}

    read -p "System Owner Group [$DEFAULT_GROUP]: " SYS_GROUP
    SYS_GROUP=${SYS_GROUP:-$DEFAULT_GROUP}
    echo ""
fi

# 2. Setup Directory and Clone Code
if [ ! -d "$TARGET_BACKEND" ]; then
    echo "Creating directory and cloning repository..."
    mkdir -p "$(dirname "$TARGET_BACKEND")"
    git clone "$GIT_REPO" "$TARGET_BACKEND"
    cd "$TARGET_BACKEND"
else
    echo "Directory exists. Pulling latest code..."
    cd "$TARGET_BACKEND"
    git config --global --add safe.directory "$TARGET_BACKEND" 2>/dev/null || true
    git pull
fi

# 3. Create/Update .env file
if [ "$IS_UPDATE" = true ] && [ -f "backend/.env" ]; then
    echo "Preserving existing backend/.env configuration..."
else
    echo "Configuring .env file..."
    cat <<EOF > backend/.env
DEALDESK_HOST=127.0.0.1
DEALDESK_PORT=$SERVER_PORT
DB_HOST=$DB_HOST
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
BACKEND_PATH=$TARGET_BACKEND
FRONTEND_PATH=$TARGET_FRONTEND
SYS_USER=$SYS_USER
SYS_GROUP=$SYS_GROUP
EOF
fi

# 4. Install Dependencies
echo "Installing backend dependencies..."
cd backend
npm install --silent

# 5. Database Verification (Simple check)
echo "Checking database connection..."
# We try to run a simple node script to verify the connection
cat <<EOF > test_conn.js
const mysql = require('mysql2/promise');
require('dotenv').config();
async function test() {
  try {
    const conn = await mysql.createConnection({
      host: process.env.DB_HOST,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      database: process.env.DB_NAME
    });
    console.log("Database connection successful!");
    await conn.end();
  } catch (err) {
    console.error("Database connection failed: " + err.message);
    process.exit(1);
  }
}
test();
EOF

if node test_conn.js; then
    echo "Database connection successful."
    rm test_conn.js
    
    # 6. Run Migrations
    echo "Running database migrations..."
    node scripts/run-migration.js
else
    echo "CRITICAL: Database connection failed. Please check your credentials and ensure the database '$DB_NAME' exists."
    rm test_conn.js
    exit 1
fi

# 7. Setup Frontend (Only deploy the Developer Console and Apache configuration)
echo "Setting up frontend at $TARGET_FRONTEND..."
mkdir -p "$TARGET_FRONTEND"
cp "../frontend/dev-console.html" "$TARGET_FRONTEND/"
cp "../frontend/dev-console.html" "$TARGET_FRONTEND/index.html"
cp "../frontend/dealdesk-ui-lock.css" "$TARGET_FRONTEND/"
cp "../frontend/.htaccess" "$TARGET_FRONTEND/"

# 8. Start/Restart Process
echo "Launching via PM2..."
if pm2 describe "$PM2_NAME" > /dev/null 2>&1; then
    pm2 restart "$PM2_NAME" --update-env
else
    pm2 start server.js --name "$PM2_NAME"
fi

# 9. Set Ownership
if [ "$EUID" -eq 0 ]; then
    echo "Setting ownership of files to $SYS_USER:$SYS_GROUP..."
    chown -R "$SYS_USER":"$SYS_GROUP" "$TARGET_BACKEND"
    chown -R "$SYS_USER":"$SYS_GROUP" "$TARGET_FRONTEND"
else
    echo "WARNING: Running as non-root. Skipping 'chown' operation."
    echo "If you encounter permission errors, run the installer with sudo."
fi

echo "==============================================="
echo "   Installation Complete!                      "
echo "   Backend: $TARGET_BACKEND                    "
echo "   Frontend: $TARGET_FRONTEND                  "
echo "   PM2 Process: $PM2_NAME                      "
echo "==============================================="
