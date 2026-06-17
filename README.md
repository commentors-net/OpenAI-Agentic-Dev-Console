# Deal Desk

A real estate transaction management system for handling deals from "Accepted Offer" to "Closing."

## Core Components
- **Frontend:** Standard UI for real estate operators to manage deals and clearance tasks.
- **Backend:** Node.js API handling business logic, data persistence, and AI integrations.
- **Dev Agent Bridge:** A secure, AI-powered diagnostic console for technical interrogation and debugging.

## Documentation
- [User & Developer Manual](./docs/USER_MANUAL.md) - Detailed guide on using the frontend vs. the Dev Console.

## Server Installation
To install or update the system on your Linux server, use the automated deployment script provided in the backend folder.

### Prerequisites
1. Ensure `git`, `node`, and `npm` are installed on the server.
2. Ensure `pm2` is installed globally (`npm install -g pm2`).

### Installation Steps
1. **Clone/Update Repository:**
   ```bash
   cd /home/servicedepartmen/dealdesk-backend
   git pull origin main
   ```
2. **Configure Environment:**
   Ensure `backend/.env` exists and contains your database credentials and the `DEALDESK_DEV_AGENT_TOKEN`.
3. **Run Deployment Script:**
   ```bash
   bash backend/deploy-server.sh
   ```

### Troubleshooting
If the database table for the Dev Agent is missing, run the migration manually:
```bash
node backend/scripts/run-migration.js
```

End of document