import { DatabaseSync } from 'node:sqlite';

export class Checkpoints {
  constructor(file) { this.file = file; }
  connection(run) {
    const db = new DatabaseSync(this.file);
    try {
      db.exec('PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS checkpoints (id TEXT PRIMARY KEY, value TEXT NOT NULL)');
      return run(db);
    } finally { db.close(); }
  }
  save(id, value) {
    if (typeof id !== 'string' || !id || id.length > 128) throw Error('Invalid checkpoint id');
    const json = JSON.stringify(value);
    if (json === undefined || Buffer.byteLength(json) > 1024 * 1024) throw Error('Checkpoint must be JSON <= 1 MB');
    return this.connection(db => db.prepare('INSERT INTO checkpoints VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET value=excluded.value').run(id, json));
  }
  load(id) { return this.connection(db => { const row = db.prepare('SELECT value FROM checkpoints WHERE id=?').get(id); return row ? JSON.parse(row.value) : null; }); }
}
