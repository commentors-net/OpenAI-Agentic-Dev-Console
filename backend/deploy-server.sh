#!/bin/bash
# Deal Desk Server Deployment Script
# To be run ON THE SERVER at /home/servicedepartmen/dealdesk-backend/deploy.sh

echo "--- Starting Deployment ---"

# 1. Pull latest code
echo "Pulling latest changes from Git..."
git pull origin main

# 2. Backend Setup
echo "Installing backend dependencies..."
cd /home/servicedepartmen/dealdesk-backend
npm install --silent

# 3. Frontend Sync
# Since server.js now serves the frontend, we just need to make sure 
# the frontend files are in the right place if they are not already.
# If your frontend is in a separate repo or folder, uncomment and adjust:
# cp -r ../frontend/* /home/servicedepartmen/public_html/dealdesk/

# 4. Restart Process
echo "Restarting Deal Desk Backend via PM2..."
pm2 restart dealdesk-backend

echo "--- Deployment Complete ---"
echo "Dev Agent should be live at: http://your-server-ip:3017/dev-console.html"
