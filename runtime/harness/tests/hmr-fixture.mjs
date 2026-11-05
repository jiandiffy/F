import { createHash } from 'node:crypto';
export const digest = text => createHash('sha256').update(text).digest('hex');
export function counterSource(version, extra = '') {
  return `let count = 0;
export default {
  apiVersion: 1, id: 'counter',
  snapshot() { return {count}; },
  apply(api, state) {
    count = state?.count ?? 0;
    api.provide('value', {version: ${JSON.stringify(version)}});
    api.prompts.register('rules', () => ${JSON.stringify(version)});
    api.on('agent_settled', () => {});
    api.effect(() => () => {});
    api.tools.register({name:'hmr_counter_echo',label:'Echo',description:'Local counter test',
      parameters:{type:'object',properties:{message:{type:'string'}},required:['message'],additionalProperties:false},
      async execute(_id, args) {
        if (globalThis.__fHmrHold) await globalThis.__fHmrHold;
        return {content:[{type:'text',text:${JSON.stringify(version)} + ':' + args.message}],details:{count:++count}};
      }});
    ${extra.includes('apply-failure') ? "throw new Error('candidate apply failed');" : ''}
  },
  async test(t) {
    const before = count;
    try {
    const result = await t.invoke('hmr_counter_echo', {message:'acceptance'});
    t.assert(result.content[0].text === ${JSON.stringify(version + ':acceptance')}, 'new revision must actually run');
    ${extra.includes('test-failure') ? "throw new Error('candidate test failed');" : ''}
    ${extra.includes('empty-tests') ? 'return [];' : "return [{name:'echo-version',passed:true}];"}
    } finally { count = before; }
  }
};`;
}
