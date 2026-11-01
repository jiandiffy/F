import { Service } from '../../dist/upstream.mjs';

const builtins = new Set(['read','write','edit','bash','ls','find','grep','skill','bus','goal_flow','resource_scope','maintenance_scope']);
const matches = (pattern, name) => new RegExp('^' + pattern.split('*').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$').test(name);
function argument(names) { let value; for (let i = 0; i < process.argv.length; i++) for (const name of names) { if (process.argv[i] === name) value = process.argv[i + 1] ?? ''; else if (process.argv[i].startsWith(name + '=')) value = process.argv[i].slice(name.length + 1); } return value; }
function capability(tool) {
  if (tool.capability?.name) return tool.capability;
  const name = tool.name;
  // A managed child must always be able to report to its parent without enabling
  // optional delegation tools (which cannot spawn at the inherited depth limit).
  const parentRelay = name === 'send_message' && Number(process.env.F_AGENT_DEPTH ?? 0) > 0 && process.env.F_PARENT_AGENT_ID && process.env.F_AGENT_RELAY_DIR;
  if (builtins.has(name) || parentRelay) return { name: 'core', description: '读写项目文件、技能按需加载、总线、目标管理与父子通信' };
  if (['subagent','list_agents','send_message','interrupt_agent'].includes(name)) return { name: 'subagents', description: '启动、沟通和收回独立子代理' };
  if (name.startsWith('workflow')) return { name: 'workflow', description: '编排大型并行任务与后台工作流' };
  if (name.startsWith('whiteboard')) return { name: 'whiteboard', description: '在申请的项目画板矩形内绘制、读取和修改图解' };
  return { name: tool.plugin ?? name, description: tool.description || name };
}
export class CapabilityBus extends Service {
  constructor(ctx, { stateFor }) {
    super(ctx, 'bus'); this.stateFor = stateFor; this.events = []; this.context = undefined; this.allowed = undefined;
    this.selectedCapabilities = new Set(); this.disabledCapabilities = new Set(); this.explicitDefaults = new Set(); this.authorizations = new Map();
    ctx.tools.onChange(() => { if (this.context && this.allowed !== undefined) this.applySelection(); });
  }
  catalog() {
    const groups = new Map(), registry = this.ctx.tools;
    // Pi retains tool definitions after scope disposal. Only host-owned tools and
    // currently registered Harness tools belong to the live catalog.
    const hostTools = (this.ctx.host.pi.getAllTools?.() ?? []).filter(tool => !registry.managedNames.has(tool.name));
    const tools = new Map([...hostTools, ...registry.entries.values()].map(tool => [tool.name, tool]));
    for (const tool of tools.values()) {
      const group = capability(tool), entry = groups.get(group.name) ?? { ...group, tools: [] };
      entry.tools.push(tool.name); groups.set(group.name, entry);
    }
    return [...groups.values()];
  }
  permits(name) { return !this.explicit || ((this.allowed.has(name) || this.allowPatterns.some(pattern => matches(pattern, name))) && !this.denyPatterns.some(pattern => matches(pattern, name))); }
  authorizeTools(owner, names) {
    names = [...names];
    if (names.some(name => !this.ctx.tools.entries.has(name) || !this.permits(name))) throw new Error('Host tool allowlist excludes HMR tools; explicitly authorize them before loading');
    this.authorizations.set(owner, new Set(names)); this.applySelection();
  }
  restoreAuthorization(owner, names = []) {
    if (names.length) this.authorizations.set(owner, new Set(names)); else this.authorizations.delete(owner);
    if (this.allowed !== undefined) this.applySelection();
  }
  applySelection() {
    const catalog = this.catalog();
    const selected = new Set(catalog.flatMap(group => {
      const enabled = group.name === 'core' || (!this.disabledCapabilities.has(group.name) &&
        (this.selectedCapabilities.has(group.name) || this.explicitDefaults.has(group.name)));
      return group.tools.filter(name => (enabled || [...this.authorizations.values()].some(names => names.has(name))) && this.permits(name));
    }));
    this.ctx.host.pi.setActiveTools([...selected]);
    return catalog.map(group => ({ ...group, active: group.tools.some(name => selected.has(name)) }));
  }
  async sync(context) {
    this.context = context;
    if (this.allowed === undefined) {
      const declared = argument(['--tools','-t']);
      this.explicit = declared !== undefined;
      const patterns = (declared ?? '').split(',').map(name => name.trim()).filter(Boolean);
      this.allowPatterns = patterns.filter(name => !name.startsWith('-')).map(name => name.replace(/^\+/, ''));
      this.denyPatterns = [...(argument(['--exclude-tools','-xt']) ?? '').split(','), ...patterns.filter(name => name.startsWith('-')).map(name => name.slice(1))].map(name => name.trim()).filter(Boolean);
      this.allowed = this.explicit ? new Set(this.ctx.host.pi.getActiveTools()) : null;
      if (this.explicit) this.explicitDefaults = new Set(this.catalog().filter(group => group.tools.some(name => this.allowed.has(name) && this.permits(name))).map(group => group.name));
    }
    const state = await this.stateFor(context).read();
    this.selectedCapabilities = new Set(state.capabilities);
    this.disabledCapabilities = new Set(state.disabledCapabilities ?? []);
    return this.applySelection();
  }
  async choose(context, names, enabled) {
    if (this.allowed === undefined) await this.sync(context);
    const known = this.catalog();
    for (const name of names) {
      const entry = known.find(c => c.name === name);
      if (!entry) throw new Error(`Unknown capability: ${name}`);
      if (!enabled && name === 'core') throw new Error('Core bus tools remain active');
      if (enabled && this.explicit && entry.tools.every(t => !this.permits(t))) throw new Error(`Capability exceeds the explicit host tool selection: ${name}`);
    }
    await this.stateFor(context).mutate(state => {
      const selected = new Set(state.capabilities), disabled = new Set(state.disabledCapabilities ?? []);
      for (const name of names) {
        if (enabled) { selected.add(name); disabled.delete(name); }
        else { selected.delete(name); disabled.add(name); const tools = known.find(group => group.name === name).tools; for (const names of this.authorizations.values()) for (const tool of tools) names.delete(tool); }
      }
      state.capabilities = [...selected]; state.disabledCapabilities = [...disabled]; return state.capabilities;
    });
    this.record('capabilities', { names, enabled }); return this.sync(context);
  }
  record(type, value) {
    const event = { type, value, at: new Date().toISOString() };
    this.events.push(event); if (this.events.length > 200) this.events.shift();
    this.ctx.host.pi.appendEntry('f-bus', event); return event;
  }
  isActive(name) { return this.ctx.host.pi.getActiveTools().includes(name); }
}
