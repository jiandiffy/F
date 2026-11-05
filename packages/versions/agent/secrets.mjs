import { readFile } from 'node:fs/promises';

export const privatePath = file => /(^|\/)(?:\.git|\.f|node_modules|\.build|__pycache__|\.env(?:\.[^/]*)?|auth\.json|credentials[^/]*|.*api[-_]key.*|id_(?:rsa|ed25519)|signing-keychain-password)(\/|$)|(?:^|\/)pi\/(?:codebuddy|runtime|cache|agent\/sessions)(\/|$)|^dsh\/deepseek-api\.md$|\.app(?:\/|$)/i.test(file);
export function assertNoSecret(data, file) {
  const text = data.toString('utf8');
  if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{30,}|\bsk-[A-Za-z0-9_-]{24,}|\bAIza[A-Za-z0-9_-]{30,}|\bAKIA[A-Z0-9]{16}\b/.test(text)) throw new Error('Publication refused: credential material in ' + file);
  if (text.includes('\0')) return;
  for (const match of text.matchAll(/(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)["']?\s*[:=]\s*["']([^"'\n]{16,})["']/gi)) {
    const value = match[1];
    if (/fixture|example|placeholder|test[_-]|your[_-]|\$\{|process\.env|<|\s/i.test(value)) continue;
    const frequencies = new Map(); for (const c of value) frequencies.set(c, (frequencies.get(c) ?? 0) + 1);
    const entropy = [...frequencies.values()].reduce((sum, n) => sum - n / value.length * Math.log2(n / value.length), 0);
    if (entropy > 3.5) throw new Error('Publication refused: literal credential in ' + file);
  }
}
export async function scanSource(file, name = file) { const data = await readFile(file); assertNoSecret(data, name); }
