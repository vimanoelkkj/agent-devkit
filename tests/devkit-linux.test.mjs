import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { plan, profileShow, sync, verify } from '../src/devkit-engine.mjs';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cli = path.join(repository, 'bin/agent-devkit.mjs');
function put(file, data) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, data); }
function fixture(t, { manifest = true, chopp = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'devkit-linux-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const devkitRoot = path.join(root, 'devkit');
  const projectDir = path.join(root, 'project');
  fs.mkdirSync(projectDir);
  const profile = chopp ? 'chopp-delivery' : 'fixture';
  const profileData = chopp ? profileShow(repository, profile) : { name: profile, version: '1.0.0', skills: ['minimal-diff'], targets: { skills: ['.agents/skills'] } };
  put(path.join(devkitRoot, 'profiles', profile, 'profile.json'), JSON.stringify(profileData));
  for (const skill of profileData.skills) fs.cpSync(path.join(repository, 'core/skills', skill), path.join(devkitRoot, 'core/skills', skill), { recursive: true });
  const data = { ...profileData, profile };
  if (manifest) put(path.join(projectDir, 'agent-devkit.json'), JSON.stringify(data));
  const options = { devkitRoot, projectDir, profile };
  const target = path.join(projectDir, '.agents/skills/minimal-diff/SKILL.md');
  const source = path.join(devkitRoot, 'core/skills/minimal-diff/SKILL.md');
  const lock = manifest ? path.join(projectDir, 'agent-devkit.lock') : path.join(devkitRoot, 'state', profile, 'agent-devkit.lock');
  function manifestUpdate(update) {
    Object.assign(data, update);
    put(path.join(projectDir, 'agent-devkit.json'), JSON.stringify(data));
    delete options.profile;
  }
  function origin(url) {
    execFileSync('git', ['init', '--quiet', projectDir]);
    execFileSync('git', ['-C', projectDir, 'config', '--local', 'remote.origin.url', url]);
    put(path.join(projectDir, 'package.json'), '{}');
  }
  return { root, ...options, options, data, target, source, lock, manifestUpdate, origin };
}
function snapshot(root) {
  const result = {};
  function walk(dir) {
    for (const entry of fs.readdirSync(dir)) {
      const file = path.join(dir, entry);
      const s = fs.lstatSync(file);
      result[path.relative(root, file)] = s.isSymbolicLink() ? `link:${fs.readlinkSync(file)}` :
        s.isDirectory() ? 'dir' : `${s.mode}:${fs.readFileSync(file).toString('base64')}`;
      if (s.isDirectory()) walk(file);
    }
  }
  walk(root);
  return result;
}

test('installs local Skills; lock contract, provenance and exact SHA-256; verifies', t => {
  const f = fixture(t);
  assert.equal(verify(f.options).verified, false);
  assert.equal(sync(f.options).written, 1);
  assert.deepEqual(fs.readFileSync(f.target), fs.readFileSync(f.source));
  const lock = JSON.parse(fs.readFileSync(f.lock));
  assert.equal(lock.lockfileVersion, '1.0.0');
  assert.equal(lock.profile, 'fixture@1.0.0');
  assert.equal(lock.skills['minimal-diff'].source, 'core');
  assert.equal(lock.skills['minimal-diff'].files['SKILL.md'].sha256, createHash('sha256').update(fs.readFileSync(f.source)).digest('hex'));
  assert.equal(verify(f.options).verified, true);
  fs.appendFileSync(f.target, 'local change');
  assert.equal(verify(f.options).state[0].status, 'modified');
});
test('dry-run and verify write nothing, including external state and directories', t => {
  const f = fixture(t, { manifest: false });
  const before = snapshot(f.root);
  assert.equal(sync({ ...f.options, dryRun: true }).written, 0);
  assert.equal(verify(f.options).verified, false);
  assert.deepEqual(snapshot(f.root), before);
  sync(f.options);
  assert.ok(fs.existsSync(f.lock));
  assert.equal(fs.existsSync(path.join(f.projectDir, 'agent-devkit.lock')), false);
});
test('idempotence preserves bytes, lock timestamp and file mtimes', t => {
  const f = fixture(t);
  sync(f.options);
  const before = snapshot(f.root);
  const mtime = fs.statSync(f.lock).mtimeMs;
  assert.equal(sync(f.options).written, 0);
  assert.equal(verify(f.options).verified, true);
  assert.deepEqual(snapshot(f.root), before);
  assert.equal(fs.statSync(f.lock).mtimeMs, mtime);
});
test('accepts existing PowerShell lock layout, UTF-8 BOM and field ordering without rewriting', t => {
  const f = fixture(t);
  sync(f.options);
  const lock = JSON.parse(fs.readFileSync(f.lock));
  const entry = lock.skills['minimal-diff'];
  lock.skills['minimal-diff'] = { files: entry.files, version: entry.version, source: entry.source };
  put(f.lock, `\uFEFF${JSON.stringify(lock, null, 4)}`);
  const before = snapshot(f.root);
  assert.equal(verify(f.options).verified, true);
  assert.equal(sync(f.options).written, 0);
  assert.deepEqual(snapshot(f.root), before);
});
test('unlocked modifications block the whole transaction before installing other files', t => {
  const f = fixture(t);
  put(f.target, 'keep local');
  put(path.join(path.dirname(f.source), 'extra.md'), 'new upstream');
  const before = snapshot(f.root);
  assert.equal(sync(f.options).blocked, true);
  assert.deepEqual(snapshot(f.root), before);
});
test('clean upstream updates succeed; local modifications and conflicts stay intact', t => {
  const f = fixture(t);
  sync(f.options);
  fs.appendFileSync(f.source, 'upstream');
  assert.equal(verify(f.options).state[0].status, 'update_available');
  sync(f.options);
  assert.equal(verify(f.options).verified, true);
  fs.appendFileSync(f.target, 'local');
  assert.equal(sync(f.options).blocked, true);
  fs.appendFileSync(f.source, 'next upstream');
  assert.equal(verify(f.options).state[0].status, 'conflict');
  const before = snapshot(f.root);
  assert.equal(sync(f.options).blocked, true);
  assert.deepEqual(snapshot(f.root), before);
});
test('untracked files are reported and preserved; stale locks require reconciliation', t => {
  const f = fixture(t);
  sync(f.options);
  put(path.join(path.dirname(f.target), 'custom.md'), 'keep');
  const before = snapshot(f.root);
  assert.equal(verify(f.options).verified, false);
  assert.equal(sync(f.options).blocked, true);
  assert.deepEqual(snapshot(f.root), before);
  fs.unlinkSync(f.source);
  assert.throws(() => sync(f.options), /Missing SKILL.md/);
});
test('retired source files do not disappear from the lock', t => {
  const f = fixture(t);
  const extra = path.join(path.dirname(f.source), 'extra.md');
  put(extra, 'old source');
  sync(f.options);
  fs.unlinkSync(extra);
  assert.throws(() => sync(f.options), /reconciliation/);
});
test('profile-local Skills take precedence and retain provenance', t => {
  const f = fixture(t);
  put(path.join(f.devkitRoot, 'profiles/fixture/skills/minimal-diff/SKILL.md'), 'profile Skill');
  sync(f.options);
  assert.equal(fs.readFileSync(f.target, 'utf8'), 'profile Skill');
  assert.equal(JSON.parse(fs.readFileSync(f.lock)).skills['minimal-diff'].source, 'profile:fixture');
});
test('legacy components and array targets retain manifest format and materialize two copies', t => {
  const f = fixture(t);
  f.manifestUpdate({ skills: [], components: { core: ['minimal-diff'] }, targets: ['.agents/skills', '.claude/skills'] });
  const manifest = fs.readFileSync(path.join(f.projectDir, 'agent-devkit.json'));
  assert.equal(sync(f.options).written, 2);
  assert.equal(verify(f.options).verified, true);
  assert.deepEqual(fs.readFileSync(path.join(f.projectDir, 'agent-devkit.json')), manifest);
  assert.equal(fs.existsSync(path.join(f.projectDir, '.claude/settings.json')), false);
});
for (const value of ['../outside', '/tmp/outside', 'C:\\outside', '.agents/../outside', '.agents//skills', '.agents/skills/../../.git', '.git', 'src', '.agents/skills\0']) {
  test(`rejects unsafe or unsupported target ${JSON.stringify(value)}`, t => {
    const f = fixture(t);
    f.manifestUpdate({ targets: { skills: [value] } });
    const before = snapshot(f.root);
    assert.throws(() => sync(f.options), /Unsafe|Unsupported/);
    assert.deepEqual(snapshot(f.root), before);
  });
}
test('rejects traversal in Skill names, profile names and locked paths', t => {
  const f = fixture(t);
  assert.throws(() => profileShow(f.devkitRoot, '../rp-doces'), /Unsafe/);
  f.manifestUpdate({ skills: ['../minimal-diff'] });
  assert.throws(() => sync(f.options), /Unsafe/);
  f.manifestUpdate({ skills: ['minimal-diff'] });
  sync(f.options);
  const lock = JSON.parse(fs.readFileSync(f.lock));
  lock.skills['minimal-diff'].files['../../outside'] = { sha256: 'a'.repeat(64) };
  put(f.lock, JSON.stringify(lock));
  assert.throws(() => verify(f.options), /Unsafe/);
});
for (const kind of ['target-parent', 'target-file', 'source-file', 'source-directory', 'manifest', 'lock', 'state', 'project']) {
  test(`rejects symlink: ${kind}, including dangling links`, t => {
    const f = fixture(t, { manifest: kind !== 'state' });
    const outside = path.join(f.root, 'outside');
    fs.mkdirSync(outside);
    if (kind === 'target-parent') fs.symlinkSync(outside, path.join(f.projectDir, '.agents'));
    if (kind === 'target-file') { fs.mkdirSync(path.dirname(f.target), { recursive: true }); fs.symlinkSync(path.join(outside, 'absent'), f.target); }
    if (kind === 'source-file') { fs.unlinkSync(f.source); fs.symlinkSync(path.join(outside, 'absent'), f.source); }
    if (kind === 'source-directory') { fs.rmSync(path.dirname(f.source), { recursive: true }); fs.symlinkSync(outside, path.dirname(f.source)); }
    if (kind === 'manifest') { fs.unlinkSync(path.join(f.projectDir, 'agent-devkit.json')); fs.symlinkSync(path.join(outside, 'absent'), path.join(f.projectDir, 'agent-devkit.json')); }
    if (kind === 'lock') fs.symlinkSync(path.join(outside, 'absent'), f.lock);
    if (kind === 'state') fs.symlinkSync(outside, path.join(f.devkitRoot, 'state'));
    if (kind === 'project') { const link = path.join(f.root, 'project-link'); fs.symlinkSync(f.projectDir, link); f.options.projectDir = link; }
    const before = snapshot(f.root);
    assert.throws(() => sync(f.options), /Symlink/);
    assert.deepEqual(snapshot(f.root), before);
  });
}
test('rejects hardlinks and FIFOs without reading or blocking', t => {
  const f = fixture(t);
  put(f.target, 'local');
  fs.linkSync(f.target, path.join(f.root, 'hardlink'));
  assert.throws(() => sync(f.options), /hardlink/);
  if (process.platform !== 'win32') {
    fs.unlinkSync(f.target);
    execFileSync('mkfifo', [f.target]);
    assert.throws(() => sync(f.options), /special file/);
  }
});
for (const resource of ['thirdPartySkills', 'thirdParty', 'hooks', 'instructions', 'rules', 'agents', 'configs', 'overlays']) {
  test(`fails explicitly for unsupported ${resource}`, t => {
    const f = fixture(t);
    f.manifestUpdate({ [resource]: ['unsupported'] });
    const before = snapshot(f.root);
    assert.throws(() => sync(f.options), /Unsupported/);
    assert.deepEqual(snapshot(f.root), before);
  });
}
test('unknown Skills and corrupt hashes/versions fail, preserving lock and files', t => {
  const f = fixture(t);
  f.manifestUpdate({ skills: ['frontend-design'] });
  assert.throws(() => sync(f.options), /third-party downloads are unsupported/);
  f.manifestUpdate({ skills: ['minimal-diff'] });
  sync(f.options);
  const lock = JSON.parse(fs.readFileSync(f.lock));
  lock.skills['minimal-diff'].files['SKILL.md'].sha256 = 'invalid';
  put(f.lock, JSON.stringify(lock));
  assert.throws(() => verify(f.options), /SHA-256/);
  lock.lockfileVersion = '2.0.0';
  put(f.lock, JSON.stringify(lock));
  assert.throws(() => sync(f.options), /Incompatible/);
});
for (const stage of ['first-write', 'middle-write', 'lock-write', 'external-state']) {
  test(`rollback restores exact files and removes created directories: ${stage}`, t => {
    const f = fixture(t, { manifest: stage !== 'external-state' });
    put(path.join(path.dirname(f.source), 'extra.md'), 'extra');
    if (stage !== 'external-state') {
      sync(f.options);
      fs.chmodSync(f.target, 0o640);
      fs.appendFileSync(f.source, 'upstream');
      fs.appendFileSync(path.join(path.dirname(f.source), 'extra.md'), 'upstream');
    }
    const before = snapshot(f.root);
    const failAt = stage === 'first-write' ? 0 : stage === 'middle-write' ? 1 : 2;
    assert.throws(() => sync(f.options, { beforeWrite(index) { if (index === failAt) throw new Error('injected I/O failure'); } }), /injected/);
    assert.deepEqual(snapshot(f.root), before);
  });
}
test('rename I/O failure after a committed write rolls back files, lock and temporary files', t => {
  const f = fixture(t);
  put(path.join(path.dirname(f.source), 'extra.md'), 'extra');
  sync(f.options);
  fs.appendFileSync(f.source, 'upstream');
  fs.appendFileSync(path.join(path.dirname(f.source), 'extra.md'), 'upstream');
  const before = snapshot(f.root);
  const rename = fs.renameSync;
  let count = 0;
  t.mock.method(fs, 'renameSync', (...args) => {
    if (++count === 2) throw Object.assign(new Error('injected rename EIO'), { code: 'EIO' });
    return rename(...args);
  });
  assert.throws(() => sync(f.options), /rename EIO/);
  assert.deepEqual(snapshot(f.root), before);
});
test('partial temporary-file write failure leaves no files or directories behind', t => {
  const f = fixture(t);
  const before = snapshot(f.root);
  const write = fs.writeFileSync;
  t.mock.method(fs, 'writeFileSync', (fd, ...args) => {
    if (typeof fd === 'number') { write(fd, 'partial'); throw new Error('injected write failure'); }
    return write(fd, ...args);
  });
  assert.throws(() => sync(f.options), /write failure/);
  assert.deepEqual(snapshot(f.root), before);
});
test('concurrent guard blocks sync; never removes another process guard', t => {
  const f = fixture(t);
  put(path.join(f.projectDir, '.agent-devkit-sync'), 'other process');
  const before = snapshot(f.root);
  assert.throws(() => sync(f.options), /EEXIST/);
  assert.deepEqual(snapshot(f.root), before);
});
test('rechecks planned bytes before writing and preserves concurrent edits', t => {
  const f = fixture(t);
  sync(f.options);
  fs.appendFileSync(f.source, 'upstream');
  const lockBefore = fs.readFileSync(f.lock);
  assert.throws(() => sync(f.options, { beforeWrite(index, file) {
    if (index === 0) fs.appendFileSync(file, 'concurrent local edit');
  } }), /changed during sync/);
  assert.ok(fs.readFileSync(f.target, 'utf8').endsWith('concurrent local edit'));
  assert.deepEqual(fs.readFileSync(f.lock), lockBefore);
});
test('rollback reports incomplete recovery and protects edits made after a committed write', t => {
  const f = fixture(t);
  sync(f.options);
  fs.appendFileSync(f.source, 'upstream');
  const lockBefore = fs.readFileSync(f.lock);
  assert.throws(() => sync(f.options, { beforeWrite(index) {
    if (index === 1) { fs.appendFileSync(f.target, 'concurrent edit'); throw new Error('injected failure'); }
  } }), /rollback incomplete.*concurrent modification/);
  assert.ok(fs.readFileSync(f.target, 'utf8').endsWith('concurrent edit'));
  assert.deepEqual(fs.readFileSync(f.lock), lockBefore);
});
test('Skills and scripts are copied as static bytes without execution', t => {
  const f = fixture(t);
  const sentinel = path.join(f.root, 'executed');
  put(path.join(path.dirname(f.source), 'script.mjs'), `require('fs').writeFileSync(${JSON.stringify(sentinel)}, 'bad')`);
  put(path.join(path.dirname(f.source), 'script.sh'), `touch '${sentinel}'`);
  sync(f.options);
  assert.equal(fs.existsSync(sentinel), false);
  assert.equal(verify(f.options).verified, true);
});
test('Chopp profile is exclusive, has exactly four core Skills and installs no Claude hooks', t => {
  const f = fixture(t, { chopp: true, manifest: false });
  const p = profileShow(repository, 'chopp-delivery');
  assert.deepEqual(p.skills, ['efficient-coding-workflow', 'minimal-diff', 'targeted-repo-search', 'targeted-validation']);
  assert.deepEqual(p.hooks, []);
  f.origin('https://github.com/vimanoelkkj/rp-doces-admin.git');
  const before = snapshot(f.root);
  assert.throws(() => sync(f.options), /exclusive/);
  assert.deepEqual(snapshot(f.root), before);
  f.origin('git@github.com:vimanoelkkj/chopp-delivery.git');
  assert.equal(sync(f.options).written, 8);
  assert.equal(verify(f.options).verified, true);
  assert.equal(fs.existsSync(path.join(f.projectDir, '.claude/hooks')), false);
  assert.deepEqual(p.instructions, []);
});
for (const origin of ['https://github.com/vimanoelkkj/chopp-delivery.git', 'ssh://git@github.com/vimanoelkkj/chopp-delivery.git', 'https://github.com/vimanoelkkj/chopp-delivery']) {
  test(`accepts exact GitHub origin ${origin}`, t => {
    const f = fixture(t, { chopp: true });
    f.origin(origin);
    assert.equal(plan(f.options).state.length, 8);
  });
}
test('CLI profile show, read-only dry-run, verify exit codes and unsupported options', t => {
  const f = fixture(t, { chopp: true });
  f.origin('https://github.com/vimanoelkkj/chopp-delivery.git');
  const run = args => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8' });
  assert.equal(run(['profile', 'show', 'chopp-delivery']).status, 0);
  const base = ['--profile', 'chopp-delivery', '--project-dir', f.projectDir];
  const before = snapshot(f.root);
  assert.equal(run(['sync', ...base, '--dry-run']).status, 0);
  assert.equal(run(['verify', ...base]).status, 1);
  assert.deepEqual(snapshot(f.root), before);
  // A local manifest keeps this fixture's real sync lock in its temporary project.
  assert.equal(run(['sync', ...base]).status, 0);
  assert.equal(run(['verify', ...base]).status, 0);
  fs.appendFileSync(f.target, 'local');
  assert.equal(run(['sync', ...base]).status, 2);
  assert.equal(run(['sync', ...base, '--force']).status, 1);
  assert.equal(run(['sync', ...base, '--auto-discover']).status, 1);
});
