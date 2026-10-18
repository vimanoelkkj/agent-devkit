import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { Transaction, git, status, meta, sha } from '../scripts/migration-guards.mjs';
import { makeSeeds } from './migration-fixture.mjs';

const base = fs.mkdtempSync('/tmp/devkit-guard-tests-');
makeSeeds(base);
const cases = path.join(base, 'cases'); fs.mkdirSync(cases, { recursive: true });
const evidence = [];
const seeds = [path.join(base, 'seed-devkit'), path.join(base, 'seed-consumer')];
function fixture(name) {
  const dir = fs.mkdtempSync(path.join(cases, `${name}-`));
  const roots = ['devkit', 'consumer'].map((n, i) => {
    const p = path.join(dir, n); fs.cpSync(seeds[i], p, { recursive: true }); return p;
  });
  const journal = path.join(dir, 'journal.json');
  const t = new Transaction(roots, journal);
  const guards = [path.join(roots[0], '.agent-devkit-checkout-scratch.sync'), path.join(roots[1], '.agent-devkit-sync')];
  return { dir, roots, journal, t, guards };
}
function acquire(f) { f.t.preflight(); for (const p of f.guards) f.t.acquire(p); }
function clean(f) { for (const root of f.roots) assert.deepEqual(status(root), []); }
function edit(f) {
  const file = path.join(f.roots[0], 'README.md'), before = fs.readFileSync(file);
  const next = Buffer.concat([before, Buffer.from('\nScratch gate fixture.\n')]);
  fs.writeFileSync(file, next);
  const record = { file, before: before.toString('base64'), owned: meta(file) };
  fs.writeFileSync(path.join(f.dir, 'edit.json'), JSON.stringify(record));
  return { [f.roots[0]]: { 'README.md': sha(next) } };
}
function rollback(f, t = f.t) {
  const record = JSON.parse(fs.readFileSync(path.join(f.dir, 'edit.json')));
  // Validate before touching any rollback target; unknown files are never rollback targets.
  assert.deepEqual(meta(record.file), record.owned, 'third-party edit: rollback conflict');
  t.reacquireReleased();
  for (const g of t.j.guards) t.validate(g);
  assert.deepEqual(meta(record.file), record.owned, 'third-party edit after rollback fencing');
  fs.writeFileSync(record.file, Buffer.from(record.before, 'base64'));
  t.save('scratch-edit-rolled-back'); t.release();
}
function scenario(name, fn) {
  test(name, () => {
    const f = fixture(name);
    try { fn(f); evidence.push({ name, passed: true, dir: f.dir }); }
    catch (error) { evidence.push({ name, passed: false, dir: f.dir, error: String(error.stack) }); throw error; }
    finally {
      f.t.dispose();
      fs.writeFileSync(path.join(base, 'evidence.json'), JSON.stringify(evidence, null, 2));
    }
  });
}

scenario('original-false-positive-reproduced', f => {
  acquire(f);
  assert.deepEqual(status(f.roots[1]), ['?? .agent-devkit-sync']);
  assert.throws(() => assert.equal(status(f.roots[1]).join('\n'), ''));
  fs.writeFileSync(path.join(f.dir, 'original-status.json'), JSON.stringify(f.roots.map(status)));
  f.t.release(); clean(f);
});
scenario('legitimate-guards-then-strict-final', f => {
  acquire(f); const expected = edit(f); f.t.gate({ expected });
  assert.throws(() => f.t.gate({ final: true, expected }), /still held/);
  f.t.release(); f.t.gate({ final: true, expected });
  const steps = f.t.j.steps.map(x => x.action);
  assert(steps.lastIndexOf('guard-released') < steps.indexOf('final-git-gate-passed'));
  rollback(f); f.t.gate({ final: true }); clean(f);
});
scenario('preexisting-guard-preserved', f => {
  fs.writeFileSync(f.guards[1], 'preexisting\n'); const before = meta(f.guards[1]);
  assert.throws(() => f.t.preflight(), /preexisting guard/);
  assert.throws(() => f.t.acquire(f.guards[1]), /EEXIST/);
  assert.equal(f.t.j.guards.length, 0); f.t.release();
  assert.deepEqual(meta(f.guards[1]), before);
});
scenario('other-execution-preserved', f => {
  f.t.preflight();
  const other = new Transaction(f.roots, path.join(f.dir, 'other-journal.json'));
  other.preflight(); other.acquire(f.guards[1]); const before = meta(f.guards[1]);
  assert.throws(() => f.t.gate(), /unknown guard/);
  assert.throws(() => f.t.acquire(f.guards[1]), /EEXIST/);
  f.t.release(); assert.deepEqual(meta(f.guards[1]), before);
  other.release(); other.dispose(); clean(f);
});
scenario('forged-owner-record-rejected', f => {
  acquire(f); f.t.j.guards[0].owner = 'other-run';
  assert.throws(() => f.t.gate(), /foreign execution/);
  assert.throws(() => f.t.release(), /foreign execution/);
  assert(fs.existsSync(f.guards[0]));
});
for (const filename of ['unexpected.txt', 'space and\nnewline.txt', 'é.txt', '.agent-devkit-unknown.sync']) {
  scenario(`unknown-${Buffer.from(filename).toString('hex')}`, f => {
    acquire(f); edit(f); const file = path.join(f.roots[1], filename);
    fs.writeFileSync(file, 'third-party'); const before = meta(file);
    assert.throws(() => f.t.gate(), /unexpected Git change|unknown guard/);
    if (filename.endsWith('.sync')) {
      assert.throws(() => rollback(f), /rollback guard conflict/);
      assert(f.guards.every(p => fs.existsSync(p)));
      assert.deepEqual(meta(file), before);
      return; // A foreign guard is a concurrency conflict: manual recovery, no deletion.
    }
    rollback(f); assert.deepEqual(meta(file), before);
    assert.throws(() => f.t.gate({ final: true }), /unexpected Git change|unknown guard/);
  });
}
scenario('guard-content-tampered-preserved', f => {
  acquire(f); fs.writeFileSync(f.guards[1], 'tampered'); const before = meta(f.guards[1]);
  assert.throws(() => f.t.gate(), /changed/);
  assert.throws(() => f.t.release(), /changed/);
  assert.deepEqual(meta(f.guards[1]), before);
});
scenario('same-bytes-replacement-inode-rejected', f => {
  acquire(f); const bytes = fs.readFileSync(f.guards[1]);
  // Keep old inode allocated, so reuse cannot obscure the test.
  fs.renameSync(f.guards[1], path.join(f.dir, 'displaced-guard'));
  fs.writeFileSync(f.guards[1], bytes, { mode: 0o600 }); const before = meta(f.guards[1]);
  assert.throws(() => f.t.gate(), /changed/);
  assert.throws(() => f.t.release(), /changed/); assert.deepEqual(meta(f.guards[1]), before);
});
scenario('unlink-failure-no-success-retry', f => {
  acquire(f); f.t.gate();
  assert.throws(() => f.t.release({ unlink: () => { throw new Error('EACCES injected'); } }), /EACCES/);
  assert.throws(() => f.t.gate({ final: true }), /still held/);
  assert.equal(f.t.j.guards[1].state, 'releasing');
  f.t.release(); f.t.gate({ final: true }); clean(f);
});
scenario('partial-release-recovery', f => {
  acquire(f); edit(f); let n = 0;
  assert.throws(() => f.t.release({ unlink: p => {
    if (++n === 2) throw new Error('EACCES injected'); fs.unlinkSync(p);
  } }), /EACCES/);
  f.t.dispose(); const recovery = Transaction.recover(f.journal);
  rollback(f, recovery); recovery.gate({ final: true }); recovery.dispose(); clean(f);
});
scenario('crash-between-unlink-and-journal-ack', f => {
  acquire(f);
  assert.throws(() => f.t.release({ afterUnlink: () => { throw new Error('crash'); } }), /crash/);
  f.t.dispose(); const recovery = Transaction.recover(f.journal);
  recovery.release(); recovery.gate({ final: true }); recovery.dispose(); clean(f);
});
scenario('failure-before-release-rollback', f => {
  acquire(f); const expected = edit(f); f.t.gate({ expected });
  rollback(f); f.t.gate({ final: true }); clean(f);
});
scenario('failure-after-release-rollback', f => {
  acquire(f); const expected = edit(f); f.t.gate({ expected }); f.t.release();
  const file = path.join(f.roots[1], 'late-third-party.txt'); fs.writeFileSync(file, 'keep'); const before = meta(file);
  assert.throws(() => f.t.gate({ final: true, expected }), /unexpected Git change/);
  rollback(f); assert.deepEqual(meta(file), before);
  assert.throws(() => f.t.gate({ final: true }), /unexpected Git change/);
});
scenario('released-guard-recreated-by-third-party', f => {
  acquire(f); f.t.release(); fs.writeFileSync(f.guards[1], 'new writer'); const before = meta(f.guards[1]);
  assert.throws(() => f.t.gate({ final: true }), /recreated/);
  assert.throws(() => f.t.release(), /recreated/); assert.deepEqual(meta(f.guards[1]), before);
});
scenario('rollback-conflict-preserves-tracked-third-party-edit', f => {
  acquire(f); edit(f); const file = path.join(f.roots[0], 'README.md');
  fs.appendFileSync(file, 'third-party change'); const before = meta(file);
  assert.throws(() => rollback(f), /rollback conflict/); assert.deepEqual(meta(file), before);
  assert(f.guards.every(p => fs.existsSync(p)));
});
scenario('expected-path-wrong-content-rejected', f => {
  acquire(f); const expected = edit(f); fs.appendFileSync(path.join(f.roots[0], 'README.md'), 'drift');
  assert.throws(() => f.t.gate({ expected }), /expected edit content changed/);
});
scenario('unexpected-tracked-change-rejected', f => {
  acquire(f); fs.appendFileSync(path.join(f.roots[0], 'LICENSE'), '\ndrift');
  assert.throws(() => f.t.gate(), /unexpected Git change/);
});
scenario('symlink-guard-rejected-preserves-target', f => {
  acquire(f); const target = path.join(f.dir, 'third-party'); fs.writeFileSync(target, 'keep'); const before = meta(target);
  fs.unlinkSync(f.guards[1]); fs.symlinkSync(target, f.guards[1]);
  assert.throws(() => f.t.gate(), /symlink/); assert.throws(() => f.t.release(), /symlink/);
  assert.deepEqual(meta(target), before);
});
scenario('hardlink-guard-rejected', f => {
  acquire(f); const link = path.join(f.dir, 'third-party-link'); fs.linkSync(f.guards[1], link);
  assert.throws(() => f.t.gate(), /private regular/); assert.throws(() => f.t.release(), /private regular/);
  assert.equal(fs.readFileSync(link, 'utf8'), `${f.t.j.id}\n`);
});
scenario('ignored-unknown-guard-rejected', f => {
  fs.mkdirSync(path.join(f.roots[1], '.git/info'), { recursive: true });
  fs.appendFileSync(path.join(f.roots[1], '.git/info/exclude'), '\n.agent-devkit-foreign.sync\n');
  acquire(f);
  const file = path.join(f.roots[1], '.agent-devkit-foreign.sync'); fs.writeFileSync(file, 'other');
  const before = meta(file); assert.throws(() => f.t.gate(), /unknown guard/);
  f.t.release(); assert.deepEqual(meta(file), before);
});
scenario('sigkill-before-final-gate-recovery', f => {
  // Child creates the durable ownership journal, mutates only README, then really dies.
  const childJournal = path.join(f.dir, 'child-journal.json');
  const source = `import fs from 'node:fs'; import {Transaction,meta} from ${JSON.stringify(new URL('../scripts/migration-guards.mjs', import.meta.url).href)};
    const t=new Transaction(${JSON.stringify(f.roots)},${JSON.stringify(childJournal)});
    t.preflight(); for(const p of ${JSON.stringify(f.guards)}) t.acquire(p);
    const file=${JSON.stringify(path.join(f.roots[0], 'README.md'))}, before=fs.readFileSync(file);
    fs.appendFileSync(file,'\\nchild mutation\\n');
    fs.writeFileSync(${JSON.stringify(path.join(f.dir, 'edit.json'))},JSON.stringify({file,before:before.toString('base64'),owned:meta(file)}));
    t.save('interrupted-before-final'); process.kill(process.pid,'SIGKILL');`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', source], { encoding: 'utf8' });
  assert.equal(result.signal, 'SIGKILL', result.stderr);
  const recovery = Transaction.recover(childJournal); rollback(f, recovery);
  recovery.gate({ final: true }); recovery.dispose(); clean(f);
});
scenario('ambiguous-acquisition-no-ownership-no-delete', f => {
  f.t.preflight(); f.t.save('acquire-intent', { file: f.guards[1] });
  fs.writeFileSync(f.guards[1], `${f.t.j.id}\n`, { mode: 0o600 }); const before = meta(f.guards[1]);
  const recovery = Transaction.recover(f.journal); recovery.release();
  assert.throws(() => recovery.gate(), /unknown guard/); assert.deepEqual(meta(f.guards[1]), before);
  recovery.dispose();
});
scenario('missing-held-guard-fails-closed', f => {
  acquire(f); fs.unlinkSync(f.guards[1]);
  assert.throws(() => f.t.gate(), /ENOENT/); assert.throws(() => f.t.release(), /ENOENT/);
});
scenario('git-exclude-drift-rejected', f => {
  acquire(f); fs.mkdirSync(path.join(f.roots[1], '.git/info'), { recursive: true });
  fs.writeFileSync(path.join(f.roots[1], '.git/info/exclude'), '*.txt\n');
  assert.throws(() => f.t.gate(), /Git metadata\/HEAD changed/);
});
scenario('git-index-drift-rejected', f => {
  acquire(f); const index = path.join(f.roots[1], '.git/index');
  // Metadata-only drift must also fail, without staging any file.
  fs.chmodSync(index, 0o600);
  assert.throws(() => f.t.gate(), /Git metadata\/HEAD changed/);
});
scenario('new-writer-after-release-blocks-rollback', f => {
  acquire(f); edit(f); f.t.release();
  fs.writeFileSync(f.guards[1], 'new writer'); const before = meta(f.guards[1]);
  const edited = meta(path.join(f.roots[0], 'README.md'));
  assert.throws(() => rollback(f), /rollback guard conflict/);
  assert.deepEqual(meta(f.guards[1]), before);
  assert.deepEqual(meta(path.join(f.roots[0], 'README.md')), edited);
});
scenario('guard-permissions-changed-rejected', f => {
  acquire(f); fs.chmodSync(f.guards[1], 0o644); const before = meta(f.guards[1]);
  assert.throws(() => f.t.gate(), /changed/); assert.throws(() => f.t.release(), /changed/);
  assert.deepEqual(meta(f.guards[1]), before);
});
scenario('rollback-revalidates-after-reacquiring-guards', f => {
  acquire(f); edit(f); f.t.release();
  const original = f.t.reacquireReleased.bind(f.t);
  f.t.reacquireReleased = () => {
    original(); fs.appendFileSync(path.join(f.roots[0], 'README.md'), '\nthird-party during fencing');
  };
  assert.throws(() => rollback(f), /after rollback fencing/);
  assert(fs.readFileSync(path.join(f.roots[0], 'README.md'), 'utf8').endsWith('third-party during fencing'));
});
