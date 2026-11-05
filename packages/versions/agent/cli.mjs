import { VersionProject } from './project.mjs';

// Native plugin bridge. JSON arguments travel in stdin, never through a shell.
let input = '';
for await (const chunk of process.stdin) input += chunk;
try {
  const request = JSON.parse(input);
  if (!['enable','status','branch','commit','merge','complete','publish'].includes(request.action)) throw new Error('Unknown version action');
  if (request.action === 'enable' && request.authorized !== true) throw new Error('Enabling versions requires an explicit user UI activation');
  const project = new VersionProject(request.project);
  const value = await project[request.action](request);
  process.stdout.write(JSON.stringify({ ok: true, value }) + '\n');
} catch (error) {
  process.stdout.write(JSON.stringify({ ok: false, error: error.message }) + '\n'); process.exitCode = 1;
}
