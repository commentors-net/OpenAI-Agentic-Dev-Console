'use strict';

const path = require('path');
const tools = require('../dev-agent-tools');

describe('Dev Agent Tools Unit Tests', () => {
    describe('Redaction Layer', () => {
        it('should redact sensitive environment variables', () => {
            const raw1 = 'OPENAI_API_KEY="sk-abcd1234efgh"';
            const raw2 = 'DB_PASSWORD = "supersecretpassword"';
            const raw3 = 'DEALDESK_DEV_AGENT_TOKEN=token123';
            const raw4 = 'password: "my_pass"';
            const raw5 = 'Authorization: bearer secret-token-xyz';

            expect(tools.redact(raw1)).toContain('[REDACTED]');
            expect(tools.redact(raw2)).toContain('[REDACTED]');
            expect(tools.redact(raw3)).toContain('[REDACTED]');
            expect(tools.redact(raw4)).toContain('[REDACTED]');
            expect(tools.redact(raw5)).toContain('[REDACTED]');

            expect(tools.redact(raw1)).not.toContain('sk-abcd1234efgh');
            expect(tools.redact(raw2)).not.toContain('supersecretpassword');
            expect(tools.redact(raw3)).not.toContain('token123');
        });

        it('should leave non-sensitive text untouched', () => {
            const safeText = 'The database port is 3306 and server port is 3017';
            expect(tools.redact(safeText)).toBe(safeText);
        });
    });

    describe('Path Sandboxing Safety', () => {
        it('should throw an error for paths outside the workspace', async () => {
            const outsidePath = path.resolve(__dirname, '../../../../some-other-folder');
            
            await expect(
                tools.read_file({ file_path: outsidePath })
            ).rejects.toThrow(/outside authorized workspaces/i);
        });

        it('should throw an error for accessing Git files', async () => {
            const gitPath = path.join(__dirname, '../.git/config');
            
            await expect(
                tools.read_file({ file_path: gitPath })
            ).rejects.toThrow(/cannot access Git files/i);
        });
    });

    describe('Command Whitelisting & Validation', () => {
        it('should block non-whitelisted base commands', async () => {
            await expect(
                tools.run_command({ command: 'cat /etc/passwd' })
            ).rejects.toThrow(/not whitelisted/i);
        });

        it('should block dangerous shell characters', async () => {
            await expect(
                tools.run_command({ command: 'pm2 status; rm -rf .' })
            ).rejects.toThrow(/dangerous shell characters/i);
        });

        it('should allow valid pm2 subcommands', async () => {
            const promise = tools.run_command({ command: 'pm2 list' });
            await expect(promise).resolves.not.toThrow();
        });

        it('should block invalid script extensions for pm2 start', async () => {
            await expect(
                tools.run_command({ command: 'pm2 start script.sh' })
            ).rejects.toThrow(/only JS files or ecosystem config files/i);
        });
    });

    describe('Path Deletion Layer & Safety', () => {
        it('should block deleting the Deal Desk backend root', async () => {
            const rootPath = path.resolve(__dirname, '..');
            await expect(
                tools.delete_path({ path_to_delete: rootPath })
            ).rejects.toThrow(/cannot delete the primary application backend directory/i);
        });

        it('should block deleting root hosting directories', async () => {
            const devappsRoot = path.resolve(__dirname, '../../../devapps');
            await expect(
                tools.delete_path({ path_to_delete: devappsRoot })
            ).rejects.toThrow(/cannot delete the root application hosting directories/i);
        });

        it('should successfully delete a safe target file in sandbox', async () => {
            const fs = require('fs');
            const testFilePath = path.join(__dirname, '../storage/delete-test-temp.txt');
            fs.writeFileSync(testFilePath, 'hello delete test', 'utf8');

            const result = await tools.delete_path({ path_to_delete: testFilePath });
            expect(result).toContain('Success: Deleted path');
            expect(fs.existsSync(testFilePath)).toBe(false);
        });
    });
});
