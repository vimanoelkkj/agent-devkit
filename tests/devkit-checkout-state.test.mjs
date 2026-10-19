import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync, spawnSync } from 'node:child_process';
import { plan, sync, verify } from '../src/devkit-engine.mjs';

const put = (file, bytes) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); };
const git = (dir, ...args) => execFileSync('git', ['-C', dir, '-c', 'core.hooksPath=/dev/null', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const origin = 'https://github.com/example/product.git';
function tree(root) {
  const out = {};
  function walk(dir) {
    for (const n of fs.readdirSync(dir).sort()) {
      const file = path.join(dir, n), s = fs.lstatSync(file, { bigint: true });
      out[path.relative(root, file)] = [String(s.mode), String(s.ino), String(s.mtimeNs),
        s.isFile() ? fs.readFileSync(file).toString('base64') : s.isSymbolicLink() ? fs.readlinkSync(file) : null];
      if (s.isDirectory()) walk(file);
    }
  }
  walk(root); return out;
}
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'devkit-checkouts-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const devkitRoot = path.join(root, 'devkit');
  const profile = { name: 'alpha', version: '1.0.0', skills: ['sample'], targets: { skills: ['.agents/skills', '.claude/skills'] },
    discovery: { githubRepository: 'example/product' } };
  const profileFile = path.join(devkitRoot, 'profiles/alpha/profile.json');
  put(profileFile, JSON.stringify(profile));
  const source = path.join(devkitRoot, 'core/skills/sample/SKILL.md'); put(source, '# v1\n');
  function checkout(n) {
    const projectDir = path.join(root, n); fs.mkdirSync(projectDir, { recursive: true });
    git(projectDir, 'init', '--quiet'); git(projectDir, 'config', '--local', 'remote.origin.url', origin);
    return { devkitRoot, projectDir, profile: 'alpha', stateScope: 'checkout' };
  }
  const a = checkout('a'), b = checkout('b');
  return { root, devkitRoot, profile, profileFile, source, a, b, checkout };
}
const target = '.agents/skills/sample/SKILL.md';
function editLock(options, edit) {
  const file = plan(options).lockPath, lock = JSON.parse(fs.readFileSync(file));
  edit(lock); fs.writeFileSync(file, JSON.stringify(lock));
}

test('two checkouts have independent baselines, hashes and updates', t => {
  const f = fixture(t), a = sync(f.a), b = sync(f.b);
  assert.notEqual(a.lockPath, b.lockPath);
  assert.match(a.lockPath.replace(/\\/g, '/'), /state\/alpha\/checkouts\/[a-f0-9]{64}\/agent-devkit.lock$/);
  const beforeB = tree(f.b.projectDir), lockB = fs.readFileSync(b.lockPath);
  put(f.source, '# v2\n');
  assert.equal(sync(f.a).written, 2);
  assert.deepEqual(fs.readFileSync(b.lockPath), lockB);
  assert.deepEqual(tree(f.b.projectDir), beforeB);
  assert.deepEqual(plan(f.b).state.map(s => s.status), ['update_available', 'update_available']);
  assert.equal(sync(f.b).written, 2);
  for (const options of [f.a, f.b]) {
    assert.equal(verify(options).verified, true);
    const p = plan(options), lock = JSON.parse(fs.readFileSync(p.lockPath));
    for (const s of p.state) assert.equal(s.sha256, lock.skills.sample.files['SKILL.md'].sha256);
    assert.equal(lock.lockfileVersion, '1.0.0');
  }
});

test('two actual Git worktrees have distinct identities and guards', t => {
  const f = fixture(t);
  git(f.a.projectDir, '-c', 'user.name=test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgSign=false', 'commit', '--allow-empty', '-m', 'fixture');
  const worktree = path.join(f.root, 'worktree');
  git(f.a.projectDir, 'worktree', 'add', '--quiet', '-b', 'second', worktree);
  const other = { ...f.a, projectDir: worktree };
  const a = sync(f.a), b = sync(other);
  assert.equal(a.checkout.identity.commonDir, b.checkout.identity.commonDir);
  assert.notEqual(a.checkout.identity.gitDir, b.checkout.identity.gitDir);
  assert.notEqual(a.checkout.id, b.checkout.id);
  assert.equal(verify(other).verified, true);
});

test('fresh dry-run and verify are read-only, including missing state directories', t => {
  const f = fixture(t), before = tree(f.root);
  assert.equal(sync({ ...f.a, dryRun: true }).written, 0);
  assert.equal(verify(f.a).verified, false);
  assert.deepEqual(tree(f.root), before);
});

test('idempotence preserves bytes, inodes, permissions and mtimes', t => {
  const f = fixture(t); sync(f.a);
  const before = tree(f.root);
  assert.equal(sync(f.a).written, 0); assert.equal(sync({ ...f.a, dryRun: true }).written, 0);
  assert.equal(verify(f.a).verified, true); assert.deepEqual(tree(f.root), before);
});

test('matching preexisting Skills are adopted without rewriting either copy', t => {
  const f = fixture(t);
  for (const dir of ['.agents', '.claude']) put(path.join(f.a.projectDir, dir, 'skills/sample/SKILL.md'), fs.readFileSync(f.source));
  const before = tree(f.a.projectDir);
  assert.equal(sync(f.a).written, 0);
  assert.equal(verify(f.a).verified, true);
  assert.deepEqual(tree(f.a.projectDir), before);
});

for (const [label, mutate] of [
  ['foreign checkout lock / forced namespace collision', (l, f) => { l.checkoutState = JSON.parse(sync(f.b).lockBytes).checkoutState; }],
  ['different machine', l => { l.checkoutState.machine = '0'.repeat(64); }],
  ['wrong canonical root', l => { l.checkoutState.projectDir += '-other'; }],
  ['wrong Git directory', l => { l.checkoutState.gitDir += '-other'; }],
  ['wrong inode', l => { l.checkoutState.project.inode = '0'; }],
  ['wrong origin binding', l => { l.checkoutState.origin = 'other/repository'; }],
  ['wrong profile binding', l => { l.checkoutState.profile = 'beta'; }],
  ['missing binding', l => { delete l.checkoutState; }],
  ['extra binding property', l => { l.checkoutState.extra = true; }],
  ['wrong lock version', l => { l.lockfileVersion = '2.0.0'; }],
  ['wrong lock profile', l => { l.profile = 'beta@1.0.0'; }],
]) test(`reject ${label} without writes`, t => {
  const f = fixture(t); sync(f.a); editLock(f.a, l => mutate(l, f));
  const before = tree(f.root);
  assert.throws(() => sync(f.a), /binding mismatch|Incompatible lockfile/);
  assert.throws(() => verify(f.a), /binding mismatch|Incompatible lockfile/);
  assert.deepEqual(tree(f.root), before);
});

for (const local of ['agent-devkit.json', 'agent-devkit.lock']) test(`refuse ambiguous consumer ${local}`, t => {
  const f = fixture(t); put(path.join(f.a.projectDir, local), '{}'); const before = tree(f.root);
  assert.throws(() => plan(f.a), /forbids consumer/); assert.deepEqual(tree(f.root), before);
});
for (const [label, change, error] of [
  ['missing profile', o => { delete o.profile; }, /requires --profile/],
  ['explicit manifest', o => { o.manifestFile = '/nonexistent'; }, /forbids --manifest-file/],
  ['unsafe scope', o => { o.stateScope = '../escape'; }, /Unsupported state scope/],
  ['profile traversal', o => { o.profile = '../escape'; }, /Unsafe name/],
]) test(`reject ${label}`, t => {
  const f = fixture(t), o = { ...f.a }; change(o); const before = tree(f.root);
  assert.throws(() => sync(o), error); assert.deepEqual(tree(f.root), before);
});

test('origin divergence is refused before writing', t => {
  const f = fixture(t); sync(f.a);
  git(f.a.projectDir, 'config', '--local', 'remote.origin.url', 'https://github.com/example/foreign.git');
  const before = tree(f.root); assert.throws(() => sync(f.a), /origin does not match/); assert.deepEqual(tree(f.root), before);
});
test('a profile without exclusive origin cannot opt in', t => {
  const f = fixture(t); delete f.profile.discovery; put(f.profileFile, JSON.stringify(f.profile));
  assert.throws(() => sync(f.a), /exclusive profile Git origin/);
});
test('profile namespaces stay isolated even for the same permitted repository', t => {
  const f = fixture(t); sync(f.a);
  put(path.join(f.devkitRoot, 'profiles/beta/profile.json'), JSON.stringify({ ...f.profile, name: 'beta' }));
  const beta = { ...f.a, profile: 'beta' };
  const a = plan(f.a), b = sync(beta);
  assert.notEqual(a.lockPath, b.lockPath); assert.equal(verify(f.a).verified, true); assert.equal(verify(beta).verified, true);
});

for (const kind of ['checkout', 'state', 'lock', 'git', 'hardlink']) test(`reject dangerous ${kind} link`, t => {
  const f = fixture(t);
  if (kind === 'checkout') { fs.symlinkSync(f.a.projectDir, path.join(f.root, 'alias')); f.a.projectDir = path.join(f.root, 'alias'); }
  if (kind === 'state') fs.symlinkSync(f.b.projectDir, path.join(f.devkitRoot, 'state'));
  if (kind === 'git') { const d = path.join(f.a.projectDir, '.git'); fs.renameSync(d, d + '-saved'); fs.symlinkSync(d + '-saved', d); }
  if (kind === 'lock' || kind === 'hardlink') {
    const p = sync(f.a), dest = path.join(f.root, 'saved-lock'); fs.renameSync(p.lockPath, dest);
    if (kind === 'lock') fs.symlinkSync(dest, p.lockPath);
    else { fs.linkSync(dest, p.lockPath); }
  }
  const before = tree(f.root); assert.throws(() => sync(f.a), /Symlink|hardlink/); assert.deepEqual(tree(f.root), before);
});

test('same checkout concurrent sync is refused and owns only its own guard', t => {
  const f = fixture(t); let checked = false;
  const result = sync(f.a, { beforeWrite() {
    if (checked) return; checked = true;
    assert.throws(() => sync(f.a), /EEXIST/);
    // Another checkout can sync independently while A holds its guard.
    assert.equal(sync(f.b).written, 2);
  } });
  assert.equal(result.written, 2); assert.equal(verify(f.a).verified, true);
  assert.equal(fs.readdirSync(f.devkitRoot).some(n => n.endsWith('.sync')), false);
});
test('legacy guard prevents checkout-mode sync', t => {
  const f = fixture(t); put(path.join(f.a.projectDir, '.agent-devkit-sync'), 'owned elsewhere');
  const before = tree(f.root); assert.throws(() => sync(f.a), /Legacy sync guard/); assert.deepEqual(tree(f.root), before);
});
for (const index of [0, 1, 2]) test(`write failure ${index} rolls back target files and scoped state`, t => {
  const f = fixture(t);
  assert.throws(() => sync(f.a, { beforeWrite(i) { if (i === index) throw new Error('injected failure'); } }), /injected failure/);
  assert.equal(fs.existsSync(path.join(f.a.projectDir, '.agents')), false);
  assert.equal(fs.existsSync(path.join(f.a.projectDir, '.claude')), false);
  assert.equal(fs.existsSync(path.join(f.devkitRoot, 'state')), false);
  assert.equal(fs.readdirSync(f.devkitRoot).some(n => n.endsWith('.sync')), false);
});
test('failed update preserves each checkout baseline and existing bytes', t => {
  const f = fixture(t), a = sync(f.a), b = sync(f.b), old = fs.readFileSync(a.lockPath), oldB = fs.readFileSync(b.lockPath), other = tree(f.b.projectDir);
  put(f.source, '# v2\n');
  assert.throws(() => sync(f.a, { beforeWrite(i) { if (i === 2) throw new Error('lock write failed'); } }), /lock write failed/);
  assert.deepEqual(fs.readFileSync(a.lockPath), old); assert.deepEqual(fs.readFileSync(b.lockPath), oldB);
  assert.deepEqual(tree(f.b.projectDir), other);
  assert.equal(fs.readFileSync(path.join(f.a.projectDir, target), 'utf8'), '# v1\n');
  assert.deepEqual(plan(f.a).state.map(s => s.status), ['update_available', 'update_available']);
});
test('Git identity changed after planning aborts without writing targets', t => {
  const f = fixture(t);
  assert.throws(() => sync(f.a, { beforeWrite() { git(f.a.projectDir, 'config', '--local', 'remote.origin.url', 'https://github.com/example/other.git'); } }), /identity changed/);
  assert.equal(fs.existsSync(path.join(f.a.projectDir, '.agents')), false);
});
test('legacy flat state remains the default and cannot consume bound scoped locks', t => {
  const f = fixture(t), legacy = { ...f.a }; delete legacy.stateScope;
  const p = sync(legacy); assert.equal(p.lockPath, path.join(f.devkitRoot, 'state/alpha/agent-devkit.lock'));
  assert.equal(Object.hasOwn(JSON.parse(p.lockBytes), 'checkoutState'), false);
  const scoped = sync(f.a); fs.writeFileSync(p.lockPath, scoped.lockBytes);
  assert.throws(() => verify(legacy), /binding mismatch/);
});
test('CLI accepts the explicit scope and rejects incompatible combinations', t => {
  const f = fixture(t), root = path.resolve(import.meta.dirname, '..');
  fs.cpSync(path.join(root, 'src'), path.join(f.devkitRoot, 'src'), { recursive: true });
  fs.cpSync(path.join(root, 'bin'), path.join(f.devkitRoot, 'bin'), { recursive: true });
  const cli = path.join(f.devkitRoot, 'bin/agent-devkit.mjs');
  const args = ['--profile', 'alpha', '--project-dir', f.a.projectDir, '--state-scope', 'checkout'];
  const before = tree(f.root);
  const result = spawnSync(process.execPath, [cli, 'sync', ...args, '--dry-run'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr); assert.equal(JSON.parse(result.stdout).written, 0);
  assert.deepEqual(tree(f.root), before);
  assert.equal(spawnSync(process.execPath, [cli, 'verify', ...args, '--manifest-file', 'x']).status, 1);
});

test('identical directory basenames do not share state', t => {
  const f = fixture(t), a = f.checkout('parent-a/shared'), b = f.checkout('parent-b/shared');
  assert.notEqual(sync(a).lockPath, sync(b).lockPath);
});
test('equivalent HTTPS and SSH origins preserve the canonical identity', t => {
  const f = fixture(t), before = sync(f.a);
  git(f.a.projectDir, 'config', '--local', 'remote.origin.url', 'git@github.com:example/product.git');
  assert.equal(plan(f.a).lockPath, before.lockPath); assert.equal(verify(f.a).verified, true);
});
test('a copied foreign lock in the expected namespace fails closed', t => {
  const f = fixture(t), a = sync(f.a), b = sync(f.b);
  fs.copyFileSync(b.lockPath, a.lockPath);
  const before = tree(f.root);
  assert.throws(() => sync({ ...f.a, dryRun: true }), /binding mismatch/);
  assert.deepEqual(tree(f.root), before);
});
test('scoped state neither reads nor mutates the legacy flat lock', t => {
  const f = fixture(t), flat = path.join(f.devkitRoot, 'state/alpha/agent-devkit.lock');
  put(flat, 'intentionally invalid legacy lock'); const old = tree(f.devkitRoot)['state/alpha/agent-devkit.lock'];
  sync(f.a); assert.equal(verify(f.a).verified, true);
  assert.deepEqual(tree(f.devkitRoot)['state/alpha/agent-devkit.lock'], old);
});
test('an actual failed lock rename rolls back both target writes', t => {
  const f = fixture(t), lock = plan(f.a).lockPath, rename = fs.renameSync;
  fs.renameSync = function (from, to) { if (to === lock) throw new Error('injected rename failure'); return rename(from, to); };
  try { assert.throws(() => sync(f.a), /injected rename failure/); } finally { fs.renameSync = rename; }
  assert.equal(fs.existsSync(path.join(f.a.projectDir, '.agents')), false);
  assert.equal(fs.existsSync(path.join(f.a.projectDir, '.claude')), false);
  assert.equal(fs.existsSync(path.join(f.devkitRoot, 'state')), false);
  assert.equal(fs.readdirSync(f.devkitRoot).some(n => n.endsWith('.sync')), false);
});
test('PowerShell default selection stays legacy and never selects scoped state', t => {
  const f = fixture(t), scoped = sync(f.a);
  const module = path.resolve(import.meta.dirname, '../src/DevKit.Engine.psm1');
  const quote = text => "'" + text.replaceAll("'", "''") + "'";
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command',
    `Import-Module ${quote(module)} -Force -DisableNameChecking; Get-DevKitLockPath -ProjectDir ${quote(f.a.projectDir)} -ProfileName alpha -DevKitRoot ${quote(f.devkitRoot)}`], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), path.join(f.devkitRoot, 'state/alpha/agent-devkit.lock'));
  assert.equal(fs.existsSync(result.stdout.trim()), false);
  assert.equal(verify(f.a).verified, true);
  assert.equal(fs.readFileSync(scoped.lockPath).equals(scoped.lockBytes), true);
});

test('modified Skills block the entire scoped operation before state creation', t => {
  const f = fixture(t); put(path.join(f.a.projectDir, target), 'user edits');
  const before = tree(f.root), result = sync(f.a);
  assert.equal(result.blocked, true); assert.equal(result.written, 0); assert.deepEqual(tree(f.root), before);
});
test('each destination is independently checked for SHA-256 drift', t => {
  const f = fixture(t); sync(f.a);
  put(path.join(f.a.projectDir, '.claude/skills/sample/SKILL.md'), 'tampered');
  const p = verify(f.a); assert.equal(p.verified, false);
  assert.deepEqual(p.state.map(s => s.status), ['synced', 'modified']);
  assert.equal(sync(f.a).blocked, true);
});
test('different profiles targeting one checkout share the concurrency guard', t => {
  const f = fixture(t);
  put(path.join(f.devkitRoot, 'profiles/beta/profile.json'), JSON.stringify({ ...f.profile, name: 'beta' }));
  let checked = false;
  sync(f.a, { beforeWrite() {
    if (checked) return; checked = true;
    assert.throws(() => sync({ ...f.a, profile: 'beta' }), /EEXIST/);
  } });
  assert.equal(checked, true);
});
