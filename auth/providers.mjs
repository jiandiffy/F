import { readFile } from 'node:fs/promises';

export async function providerProfiles() {
  return Promise.all(['deepseek', 'openai', 'workbuddy_cn', 'workbuddy_in'].map(async name => {
    const value = JSON.parse(await readFile(new URL(`./${name}/provider.json`, import.meta.url), 'utf8'));
    return { name, ...value };
  }));
}
