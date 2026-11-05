import { readFile } from 'node:fs/promises';

export const workflowNames = ['main-agent', 'research-review', 'multi-agent-debate', 'code-development'];
export async function workflowPlan(name) {
  if (!workflowNames.includes(name)) throw Error('Unknown workflow template');
  return JSON.parse(await readFile(new URL(`./${name}/plan.json`, import.meta.url), 'utf8'));
}
