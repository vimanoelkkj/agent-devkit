// Migration guard lifecycle. Independent of the Node engine and CLI.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const sha = b => createHash('sha256').update(b).digest('hex');
export function safe(p) {
  let part = path.parse(p).root;
  for (const name of p.slice(part.length).split('/').filter(Boolean)) {
    part = path.join(part, name);
    const s = fs.lstatSync(part);
    assert(!s.isSymbolicLink(), `symlink: ${part}`);
  }
}
export function meta(p) {
  safe(p);
  const s = fs.lstatSync(p, { bigint: true });
  assert(s.isFile() && s.nlink === 1n, `not a private regular file: ${p}`);
  return { dev: String(s.dev), ino: String(s.ino), mode: String(s.mode),
    size: String(s.size), mtime: String(s.mtimeNs), ctime: String(s.ctimeNs),
    nlink: String(s.nlink), hash: sha(fs.readFileSync(p)) };
}
export function git(root, ...args) {
  return execFileSync('git', ['-c', 'core.hooksPath=/dev/null', '-c', 'diff.autoRefreshIndex=false', ...args], {
    cwd: root, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' }, encoding: 'utf8'
  });
}
const guardName = n => n === '.agent-devkit-sync' || /^\.agent-devkit.*\.sync$/.test(n);
export const status = root => git(root, 'status', '--porcelain=v1', '-z', '--untracked-files=all')
  .split('\0').filter(Boolean);

export class Transaction {
  constructor(roots, journal, existing, { id = randomUUID(), scope = 'scratch' } = {}) {
    this.roots = roots.map(p => fs.realpathSync(p));
    if (scope === 'scratch') assert(this.roots.every(p => p.startsWith('/tmp/')) && journal.startsWith('/tmp/'), 'scratch only');
    else {
      assert.equal(scope, 'execute');
      assert.deepEqual(this.roots, ['/home/zzzzz/dev/agent-devkit', '/home/zzzzz/dev/chopp-delivery']);
      assert(journal.startsWith(this.roots[0] + '/state/chopp-delivery/migration-backups/'));
    }
    safe(path.dirname(journal));
    for (const root of this.roots) if (journal.startsWith(root + '/'))
      git(root, 'check-ignore', '--', journal); // Central state journal must already be ignored.
    this.file = journal;
    this.j = existing ?? { id, scope, roots: this.roots, guards: [], steps: [], status: 'active' };
    assert.equal(this.j.scope, scope);
    assert.deepEqual(this.j.roots, this.roots);
    this.fds = new Map();
    if (!existing) {
      const fd = fs.openSync(journal, 'wx', 0o600);
      fs.closeSync(fd);
      this.save('begin');
    }
  }
  static recover(journal, { scope = 'scratch' } = {}) {
    const m = meta(journal);
    assert.equal(Number(m.mode) & 0o777, 0o600);
    const j = JSON.parse(fs.readFileSync(journal));
    return new Transaction(j.roots, journal, j, { scope });
  }
  save(action, details = {}) {
    this.j.steps.push({ action, ...details });
    const tmp = `${this.file}.${randomUUID()}.tmp`;
    const fd = fs.openSync(tmp, 'wx', 0o600);
    try { fs.writeFileSync(fd, JSON.stringify(this.j, null, 2)); fs.fsyncSync(fd); }
    finally { fs.closeSync(fd); }
    fs.renameSync(tmp, this.file);
    const dir = fs.openSync(path.dirname(this.file), 'r');
    try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
  }
  location(p) {
    assert(this.roots.includes(path.dirname(p)) && guardName(path.basename(p)), `guard outside exact roots: ${p}`);
    safe(path.dirname(p));
  }
  preflight() {
    for (const root of this.roots) {
      assert(!fs.readdirSync(root).some(guardName), 'preexisting guard');
      assert.deepEqual(status(root), [], 'dirty preflight');
    }
    assert(!this.j.gitBaseline, 'preflight cannot be reset');
    this.j.gitBaseline = this.gitSnapshot();
    this.save('preflight-passed');
  }
  gitSnapshot() {
    return this.roots.map(root => ({ root, head: git(root, 'rev-parse', 'HEAD'),
      branch: git(root, 'symbolic-ref', 'HEAD'),
      files: Object.fromEntries(['HEAD', 'index', 'config', 'info/exclude'].map(name => {
        const file = path.join(root, '.git', name);
        return [name, fs.existsSync(file) ? meta(file) : null];
      })) }));
  }
  acquire(p, { reacquire = false } = {}) {
    this.location(p);
    const old = this.j.guards.find(g => g.file === p);
    assert(!old || (reacquire && old.state === 'released'), 'duplicate guard');
    this.save('acquire-intent', { file: p });
    const fd = fs.openSync(p, fs.constants.O_CREAT | fs.constants.O_EXCL |
      fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
    this.fds.set(p, fd);
    // A crash before the complete held record is persisted is an ambiguous acquisition:
    // recovery fails closed and does not infer ownership from a filename or token alone.
    const bytes = `${this.j.id}\n`;
    fs.writeFileSync(fd, bytes); fs.fsyncSync(fd);
    const record = { file: p, owner: this.j.id, bytes, meta: meta(p), state: 'held' };
    const stat = fs.fstatSync(fd, { bigint: true });
    assert.equal(String(stat.ino), record.meta.ino); assert.equal(String(stat.dev), record.meta.dev);
    assert.equal(fs.readFileSync(p, 'utf8'), bytes);
    if (old) this.j.guards[this.j.guards.indexOf(old)] = record;
    else this.j.guards.push(record);
    this.save('guard-acquired', { file: p });
    return record;
  }
  reacquireReleased() {
    for (const g of this.j.guards) if (g.state === 'releasing' && !fs.existsSync(g.file)) {
      this.close(g.file); g.state = 'released'; this.save('release-reconciled', { file: g.file });
    }
    assert.deepEqual(this.gitSnapshot(), this.j.gitBaseline, 'Git metadata/HEAD changed');
    // After release, rollback is a new critical section. Never steal a new writer's guard.
    for (const root of this.roots) for (const n of fs.readdirSync(root).filter(guardName)) {
      const g = this.j.guards.find(g => g.file === path.join(root, n));
      assert(g && g.state !== 'released', 'rollback guard conflict'); this.validate(g);
    }
    for (const g of [...this.j.guards]) if (g.state === 'released')
      this.acquire(g.file, { reacquire: true });
  }
  validate(g) {
    this.location(g.file);
    assert.equal(g.owner, this.j.id, 'foreign execution');
    assert.equal(g.bytes, `${this.j.id}\n`, 'foreign token');
    assert.deepEqual(meta(g.file), g.meta, `guard identity/content changed: ${g.file}`);
    assert.equal(fs.readFileSync(g.file, 'utf8'), g.bytes, 'guard content changed');
    const fd = this.fds.get(g.file);
    if (fd !== undefined) {
      const s = fs.fstatSync(fd, { bigint: true });
      assert.equal(String(s.ino), g.meta.ino); assert.equal(String(s.dev), g.meta.dev);
    }
  }
  gate({ final = false, expected = {} } = {}) {
    assert(this.j.gitBaseline, 'missing preflight baseline');
    assert.deepEqual(this.gitSnapshot(), this.j.gitBaseline, 'Git metadata/HEAD changed');
    const allowed = new Set();
    for (const g of this.j.guards) {
      if (g.state === 'released') {
        assert(!fs.existsSync(g.file), 'released guard recreated');
      } else {
        assert(!final, 'guard still held at final gate');
        assert.equal(g.state, 'held', 'incomplete release');
        this.validate(g); allowed.add(g.file);
      }
    }
    for (const root of this.roots) {
      for (const n of fs.readdirSync(root).filter(guardName))
        assert(allowed.has(path.join(root, n)), `unknown guard: ${n}`);
      // NUL records preserve whitespace, newlines and quoted/non-ASCII names.
      // Rename/copy/staged records are never accepted by the expected-edit contract.
      const remaining = status(root).filter(entry =>
        !(entry.startsWith('?? ') && allowed.has(path.join(root, entry.slice(3)))));
      const edits = expected[root] ?? {};
      assert.deepEqual(remaining.toSorted(), Object.keys(edits).map(n => ` M ${n}`).toSorted(), 'unexpected Git change');
      for (const [name, hash] of Object.entries(edits)) {
        assert(!path.isAbsolute(name) && !name.split('/').includes('..'));
        assert.equal(meta(path.join(root, name)).hash, hash, 'expected edit content changed');
      }
    }
    this.save(final ? 'final-git-gate-passed' : 'guarded-git-gate-passed');
  }
  release({ unlink = fs.unlinkSync, afterUnlink = () => {} } = {}) {
    for (const g of this.j.guards.toReversed()) {
      if (g.state === 'released') {
        assert(!fs.existsSync(g.file), 'released guard recreated');
        continue;
      }
      // Persisted release intent + absent path is recoverable; held + absent is not.
      if (g.state === 'releasing' && !fs.existsSync(g.file)) {
        this.close(g.file); g.state = 'released'; this.save('release-reconciled', { file: g.file }); continue;
      }
      this.validate(g);
      g.state = 'releasing'; this.save('release-intent', { file: g.file });
      // Revalidate after journal IO, immediately before unlink. Cooperative writers required.
      this.validate(g); unlink(g.file);
      const dir = fs.openSync(path.dirname(g.file), 'r');
      try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
      afterUnlink(g);
      this.close(g.file); g.state = 'released'; this.save('guard-released', { file: g.file });
    }
  }
  close(p) { const fd = this.fds.get(p); if (fd !== undefined) { fs.closeSync(fd); this.fds.delete(p); } }
  dispose() { for (const p of [...this.fds.keys()]) this.close(p); }
}
