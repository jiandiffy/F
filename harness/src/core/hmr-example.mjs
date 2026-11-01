// 将本文件复制到项目 .f/plugins/hello/v1.mjs，审阅并计算 SHA256 后显式 /hmr load。
let state;
export default {
  apiVersion: 1,
  id: 'hello',
  snapshot() { return state; },
  apply(api, previous) {
    state = previous ?? { count: 0 };
    api.tools.register({
      name: 'hmr_hello_greet', label: 'HMR Hello', description: 'Return a local greeting without calling an LLM.',
      parameters: { type: 'object', properties: { name: { type: 'string' } }, required: ['name'], additionalProperties: false },
      async execute(_id, args) {
        state.count++;
        return { content: [{ type: 'text', text: 'Hello ' + args.name }], details: { count: state.count } };
      },
    });
  },
  async test(t) {
    const before = state.count;
    try {
      const result = await t.invoke('hmr_hello_greet', { name: 'F' });
      t.assert(result.content[0].text === 'Hello F', 'Greeting must contain the requested name');
      return [{ name: 'greeting', passed: true }];
    } finally { state.count = before; }
  },
};
