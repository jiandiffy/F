import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { StringDecoder } from 'node:string_decoder';

/** One owned Pi process. Wait for agent_settled, not merely agent_end. */
export class ChildRPC {
  pending = new Map(); nextID = 0; output = []; stopped = false;
  constructor(cli, args, { cwd, env, onEvent = () => {} }) {
    this.detached = Number(env.F_AGENT_DEPTH ?? 0) <= 1;
    this.process = spawn(cli, ['--mode', 'rpc', ...args], { cwd, env, detached: this.detached, stdio: ['pipe', 'pipe', 'pipe'] });
    this.exit = new Promise(resolve => this.process.once('close', (code, signal) => {
      this.closed = true;
      const error = new Error(`Child process ended (${signal ?? code})`);
      for (const { reject } of this.pending.values()) reject(error);
      this.pending.clear();
      this.settle?.({ output: this.output, stopReason: this.protocolError ? 'error' : this.stopped ? 'aborted' : 'error', diagnostic: this.protocolError ? 'Invalid child RPC frame' : error.message });
      resolve();
    }));
    this.process.on('error', error => {
      for (const { reject } of this.pending.values()) reject(error);
      this.pending.clear();
      this.settle?.({ output: [], stopReason: 'error', diagnostic: 'Child process could not start' });
    });
    this.process.stdin.on('error', error => {
      for (const { reject } of this.pending.values()) reject(error);
      this.pending.clear();
    });
    this.process.stderr.on('data', () => {}); // Drain diagnostics; never expose provider credentials in tool results.
    const decoder = new StringDecoder('utf8'); let buffer = '';
    this.process.stdout.on('data', data => {
      buffer += decoder.write(data);
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        let event;
        try { event = JSON.parse(line); }
        catch (error) { this.protocolError = error; void this.dispose(); continue; }
        if (event.type === 'response') {
          const waiting = this.pending.get(event.id); this.pending.delete(event.id);
          if (waiting) event.success ? waiting.resolve(event.data) : waiting.reject(new Error(event.error));
        }
        if (event.type === 'message_end' && event.message?.role === 'assistant') {
          const message = event.message;
          const content = message.content?.filter(c => c.type === 'text' && c.text) ?? [];
          if (content.length) this.output = content;
          this.stopReason = message.stopReason;
          if (message.stopReason === 'error') this.failed = true;
        }
        onEvent(event);
        if (event.type === 'agent_settled') {
          const stopReason = event.aborted ? 'aborted' : this.failed || this.stopReason === 'error' ? 'error' :
            this.stopReason === 'length' ? 'max-tokens' : 'completed';
          this.settle?.({ output: this.output, stopReason }); this.settle = undefined;
        }
      }
    });
  }
  async request(type, fields = {}) {
    if (this.closed || this.stopped) throw new Error('Child process is closed');
    const id = String(++this.nextID);
    const response = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    const writable = this.process.stdin.write(JSON.stringify({ id, type, ...fields }) + '\n');
    if (!writable) await once(this.process.stdin, 'drain');
    return response;
  }
  async prompt(message) {
    this.output = []; this.failed = false; this.stopReason = undefined;
    const result = new Promise(resolve => { this.settle = resolve; });
    const accepted = await this.request('prompt', { message });
    if (accepted?.disposition === 'handled') throw new Error('Child prompt was handled without starting a run');
    return result;
  }
  async dispose() {
    if (this.disposal) return this.disposal;
    this.stopped = true;
    this.disposal = (async () => {
      this.process.stdin.end();
      // Only this detached, owned process group is signalled; the parent F/Agent stays alive.
      const terminate = setTimeout(() => { if (!this.closed) this.process.kill('SIGTERM'); }, 300);
      const kill = setTimeout(() => {
        if (!this.closed && this.process.pid) {
          try { if (this.detached) process.kill(-this.process.pid, 'SIGKILL'); else this.process.kill('SIGKILL'); }
          catch (error) { if (error.code !== 'ESRCH') throw error; }
        }
      }, 3000);
      try { await this.exit; } finally { clearTimeout(terminate); clearTimeout(kill); }
    })();
    return this.disposal;
  }
}
