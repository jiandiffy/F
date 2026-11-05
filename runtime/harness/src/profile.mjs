import { readFile } from 'node:fs/promises';
import path from 'node:path';

export async function loadProfile(root, id = process.env.F_PROFILE ?? (process.env.F_APP_PID ? 'gui' : 'cli')) {
  if (!['base', 'gui', 'cli'].includes(id)) throw Error('Unknown F profile');
  const profile = JSON.parse(await readFile(path.join(root, 'profiles', id, 'profile.json'), 'utf8'));
  if (profile.id !== id || !Array.isArray(profile.disabled) || profile.disabled.some(value => typeof value !== 'string') || (id !== 'base' && profile.extends !== 'base')) throw Error('Invalid F profile');
  const base = id === 'base' ? { disabled: [] } : await loadProfile(root, 'base');
  return { id, disabled: [...new Set([...base.disabled, ...profile.disabled])] };
}
