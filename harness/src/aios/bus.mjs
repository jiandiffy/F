import { Service } from '../../dist/upstream.mjs';

const builtins = new Set(['read','write','edit','bash','ls','find','grep','skill','bus','goal_flow','resource_scope','maintenance_scope']);
function capability(tool) {
  if (tool.capability?.name) return tool.capability;
  const name = tool.name;
  if (builtins.has(name)) return { name: 'core', description: '读写项目文件、技能按需加载、总线与目标管理' };
  if (['subagent','list_agents','send_message','interrupt_agent'].includes(name)) return { name: 'subagents', description: '启动、沟通和收回独立子代理' };
  if (name.startsWith('workflow')) return { name: 'workflow', description: '编排大型并行任务与后台工作流' };
  if (name.startsWith('whiteboard')) return { name: 'whiteboard', description: '在申请的项目画板矩形内绘制、读取和修改图解' };
  return { name: tool.plugin ?? name, description: tool.description || name };
}
export class CapabilityBus extends Service {
  constructor(ctx, { stateFor }) { super(ctx, 'bus'); this.stateFor = stateFor; this.events = []; this.context = undefined; this.allowed = undefined; }
  catalog() {
    const groups = new Map();
    const tools = new Map([...(this.ctx.host.pi.getAllTools?.() ?? []), ...this.ctx.tools.entries.values()].map(tool => [tool.name, tool]));
    for (const tool of tools.values()) {
      const group = capability(tool), entry = groups.get(group.name) ?? { ...group, tools: [] };
      entry.tools.push(tool.name);
      groups.set(group.name, entry);
    }
    return [...groups.values()];
  }
  async sync(context) {
    this.context = context;
    if (!this.allowed) {
      const arg = process.argv.findIndex(s => s === '--tools' || s.startsWith('--tools='));
      this.explicit = arg >= 0;
      this.allowed = this.explicit ? new Set(this.ctx.host.pi.getActiveTools()) : null;
    }
    const state = await this.stateFor(context).read();
    const active = new Set(['core', ...state.capabilities]);
    const optional = this.catalog().flatMap(c => active.has(c.name) ? c.tools : []);
    if (!this.explicit) {
      const managed = new Set(this.catalog().flatMap(c => c.tools));
      const unmanaged = this.ctx.host.pi.getActiveTools().filter(name => !managed.has(name));
      this.ctx.host.pi.setActiveTools([...new Set([...unmanaged, ...optional])]);
    }
    return this.catalog().map(c => ({ ...c, active: this.explicit ? c.tools.some(t => this.allowed.has(t)) : active.has(c.name) }));
  }
  async choose(context, names, enabled) {
    const known = this.catalog();
    for (const name of names) {
      const entry = known.find(c => c.name === name);
      if (!entry) throw new Error(`Unknown capability: ${name}`);
      if (!enabled && name === 'core') throw new Error('Core bus tools remain active');
      if (enabled && this.explicit && entry.tools.some(t => !this.allowed.has(t))) throw new Error(`Capability exceeds the explicit host tool selection: ${name}`);
    }
    await this.stateFor(context).mutate(state => {
      const selected = new Set(state.capabilities);
      for (const name of names) enabled ? selected.add(name) : selected.delete(name);
      state.capabilities = [...selected]; return state.capabilities;
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
