export const childModel = Object.freeze({ provider: 'cbi', model: 'deepseek-v4.1-flash', reasoningEffort: 'medium' });

export function childRoute(request = {}) {
  for (const [key, value] of Object.entries(request)) {
    if (value !== undefined && childModel[key] !== value) throw new Error('All managed subagents require cbi/deepseek-v4.1-flash/medium');
  }
  return { ...childModel };
}

export function inheritedToolArgs() {
  if (process.env.F_INHERITED_TOOL_ARGS) return JSON.parse(process.env.F_INHERITED_TOOL_ARGS);
  const args = [];
  for (let i = 0; i < process.argv.length; i++) {
    const value = process.argv[i];
    if (['--tools', '-t', '--exclude-tools', '-xt'].includes(value)) args.push(value, process.argv[++i] ?? '');
    else if (/^(?:--tools|--exclude-tools)=/.test(value)) args.push(value);
  }
  return args;
}
