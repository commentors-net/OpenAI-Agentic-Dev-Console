'use strict';

const path = require('path');
const child_process = require('child_process');
const tools = require('../dev-agent-tools');

describe('Dev Agent Tools Unit Tests', () => {
    let execSpy;

    beforeAll(() => {
        execSpy = jest.spyOn(child_process, 'exec').mockImplementation((cmd, opts, callback) => {
            const cb = typeof opts === 'function' ? opts : callback;
            cb(null, 'mock stdout', '');
        });
    });

    afterAll(() => {
        if (execSpy) {
            execSpy.mockRestore();
        }
    });
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

        it('should allow the parent/home directory itself', async () => {
            const ROOT_DIR = path.resolve(__dirname, '..');
            const parentDir = path.resolve(ROOT_DIR, '..');
            
            // Should not throw an "outside authorized workspaces" error, but might throw "file not found" or "not a directory"
            // if we actually try to read it. Let's test listing the directory or checking list_directory.
            const result = await tools.list_directory({ dir_path: parentDir });
            expect(result).toBeDefined();
            const parsed = JSON.parse(result);
            expect(Array.isArray(parsed)).toBe(true);
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

        it('should validate and allow eslint check and autofix', async () => {
            const promise = tools.run_command({ command: 'npm run lint -- --fix' });
            await expect(promise).resolves.not.toThrow();
        });

        it('should block invalid script names or flags in npm run', async () => {
            await expect(
                tools.run_command({ command: 'npm run lint --invalid-flag' })
            ).rejects.toThrow(/argument '--invalid-flag' is not allowed/i);
        });

        it('should validate and allow standard package installs', async () => {
            const promise = tools.run_command({ command: 'npm install express -D' });
            await expect(promise).resolves.not.toThrow();
        });

        it('should block local path npm installs', async () => {
            await expect(
                tools.run_command({ command: 'npm install ../dangerous-folder' })
            ).rejects.toThrow(/invalid npm package name or parameter/i);
        });

        it('should allow valid Git branch checkouts, staging, and commits', async () => {
            const checkoutPromise = tools.run_command({ command: 'git checkout -b dev-agent-branch' });
            await expect(checkoutPromise).resolves.not.toThrow();

            const addPromise = tools.run_command({ command: 'git add backend/dev-agent-tools.js' });
            await expect(addPromise).resolves.not.toThrow();

            const commitPromise = tools.run_command({ command: 'git commit -m "feat: updated tools"' });
            await expect(commitPromise).resolves.not.toThrow();
        });

        it('should block invalid checkout targets or commits without -m', async () => {
            await expect(
                tools.run_command({ command: 'git checkout -b my-branch;rm' })
            ).rejects.toThrow(/dangerous shell characters/i);

            await expect(
                tools.run_command({ command: 'git commit -a' })
            ).rejects.toThrow(/git commit must be run with the '-m' flag/i);
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

    describe('Port Checker Tool', () => {
        it('should detect a free port', async () => {
            const net = require('net');
            const tempServer = net.createServer();
            await new Promise((resolve) => tempServer.listen(0, '127.0.0.1', resolve));
            const port = tempServer.address().port;
            await new Promise((resolve) => tempServer.close(resolve));

            const resultStr = await tools.check_port({ port });
            const result = JSON.parse(resultStr);
            expect(result.port).toBe(port);
            expect(result.in_use).toBe(false);
            expect(result.status).toBe('free');
        });

        it('should detect an occupied port', async () => {
            const net = require('net');
            const server = net.createServer();
            
            await new Promise((resolve, reject) => {
                server.once('error', reject);
                server.listen(0, '127.0.0.1', () => {
                    server.removeListener('error', reject);
                    resolve();
                });
            });

            const port = server.address().port;

            try {
                const resultStr = await tools.check_port({ port });
                const result = JSON.parse(resultStr);
                expect(result.port).toBe(port);
                expect(result.in_use).toBe(true);
                expect(result.status).toBe('occupied');
            } finally {
                await new Promise((resolve) => server.close(resolve));
            }
        });

        it('should throw error for invalid ports', async () => {
            await expect(
                tools.check_port({ port: 80 })
            ).rejects.toThrow(/port number must be between 1024 and 65535/i);
        });
    });
});
