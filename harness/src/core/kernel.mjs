import { Context, Service } from '../../dist/upstream.mjs';

export class ToolRegistry extends Service {
  entries = new Map();
  constructor(ctx, pi) { super(ctx, 'tools'); this.pi = pi; }
  register(definition) {
    if (this.entries.has(definition.name)) throw new Error(`Duplicate tool: ${definition.name}`);
    return this.ctx.effect(() => {
      this.entries.set(definition.name, definition);
      this.pi.registerTool({ ...definition, execute: (...args) => {
        const current = this.entries.get(definition.name);
        if (!current) throw new Error(`Tool is unloaded: ${definition.name}`);
        const bus = this.ctx.get('bus');
        if (bus?.context && !bus.isActive(definition.name)) throw new Error(`Activate this capability with bus before calling ${definition.name}`);
        return current.execute(...args);
      }});
      return () => {
        this.entries.delete(definition.name);
        this.pi.setActiveTools(this.pi.getActiveTools().filter(name => name !== definition.name));
      };
    });
  }
}

export class PromptRegistry extends Service {
  sections = new Map();
  constructor(ctx) { super(ctx, 'systemPrompt'); }
  register(name, render) {
    return this.ctx.effect(() => {
      if (this.sections.has(name)) throw new Error(`Duplicate prompt section: ${name}`);
      this.sections.set(name, render);
      return () => this.sections.delete(name);
    });
  }
  async assemble(event, context) {
    const sections = await Promise.all([...this.sections.values()].map(render => render(event, context)));
    return [event.systemPrompt, ...sections.filter(Boolean)].join('\n\n');
  }
}

export function createKernel(pi) {
  const ctx = new Context();
  ctx.provide('host', {
    pi,
    // All Pi event subscriptions are scoped effects of the calling plugin.
    on(owner, event, listener) { return owner.effect(() => pi.on(event, listener)); },
    adapter(owner) {
      return new Proxy(pi, { get(target, key) {
        if (key === 'on') return (event, listener) => owner.host.on(owner, event, listener);
        if (key === 'registerProvider') return (provider, config) => owner.effect(() => {
          target.registerProvider(provider, config);
          const id = typeof provider === 'string' ? provider : provider.id;
          return () => target.unregisterProvider(id);
        });
        if (key === 'registerTool') return definition => owner.tools.register(definition);
        return typeof target[key] === 'function' ? target[key].bind(target) : target[key];
      }});
    },
  });
  ctx.plugin({ name: 'f-services', apply(ctx) { new ToolRegistry(ctx, pi); new PromptRegistry(ctx); }});
  return ctx;
}

export const result = (value, text = JSON.stringify(value, null, 2)) => ({
  content: [{ type: 'text', text }], details: value,
});
export const objectSchema = (properties, required = Object.keys(properties)) => ({ type: 'object', properties, required, additionalProperties: false });
export const stringSchema = { type: 'string' };
