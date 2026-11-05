import { readFile } from 'node:fs/promises';
import path from 'node:path';

// Pi owns protocol negotiation, process shutdown, cancellation and tool exposure.
export default async function mcp(api) {
  const root = path.resolve(import.meta.dirname, '../../../..');
  const file = process.env.F_MCP_CONFIG ?? path.join(root, 'mcp/configs/servers.json');
  const config = JSON.parse(await readFile(file, 'utf8'));
  if (!config.mcpServers || typeof config.mcpServers !== 'object' || Array.isArray(config.mcpServers)) throw Error('MCP configuration needs mcpServers');
  for (const [name, entry] of Object.entries(config.mcpServers) as [string, any][]) {
    if (entry.enabled !== true) continue;
    if (!/^[a-z][a-z0-9_-]{0,47}$/.test(name)) throw Error('Invalid MCP server name');
    const { enabled, ...server } = entry;
    api.registerMcpServer(name, server);
  }
}
