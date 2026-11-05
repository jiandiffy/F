/** The single F Agent composition entry. Each conversation owns its Cordis tree. */
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import remote, { remoteTools } from '../modules/fy-remote.ts';
import whiteboard from '../modules/fy-whiteboard.ts';
import providers from '../modules/sources.ts';
import mcp from '../modules/fy-mcp.ts';

export default async function (pi: ExtensionAPI) {
  const root = path.resolve(import.meta.dirname, '../../../..');
  const entry = path.join(process.env.F_HARNESS_DIR ?? path.join(root, 'runtime/harness'), 'src/index.mjs');
  const { startHarness } = await import(pathToFileURL(entry).href);
  let remoteFileSystem;
  if (process.env.F_REMOTE_PROJECT) {
    const remoteProject = JSON.parse(process.env.F_REMOTE_PROJECT);
    const { remoteSkillFileSystem } = await import(pathToFileURL(path.join(path.dirname(path.dirname(entry)), 'src/adapters/remote-skills.mjs')).href);
    remoteFileSystem = remoteSkillFileSystem(remoteProject, remoteTools(remoteProject).run);
  }
  await startHarness(pi, { root, remoteFileSystem, adapters: [['f-model-providers', providers], ['f-mcp', mcp], ['f-remote-tools', remote], ['f-whiteboard-tools', whiteboard]] });
}
