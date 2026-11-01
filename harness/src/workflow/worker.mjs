import { WorkflowExecution } from '../../dist/upstream.mjs';
const pending = new Map(); let next = 0;
function call(method, fields) {
  const id = ++next;
  return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); process.send({ type: 'call', id, method, ...fields }); });
}
process.on('message', async message => {
  if (message.type === 'response') {
    const handler = pending.get(message.id); pending.delete(message.id);
    if (handler) message.error ? handler.reject(new Error(message.error)) : handler.resolve(message.value);
    return;
  }
  if (message.type !== 'start') return;
  const observer = Object.fromEntries(['phase','log','agentStart','agentEnd'].map(name => [name, value => process.send({ type: 'event', name, value })]));
  const children = { async startAgent(request) {
    const id = await call('startAgent', { request });
    const result = call('result', { childId: id });
    return { id, result, dispose: () => call('dispose', { childId: id }) };
  }};
  const execution = new WorkflowExecution(message.meta, message.script, message.args, message.limits, observer, children);
  process.send({ type: 'result', value: await execution.drive() });
});
