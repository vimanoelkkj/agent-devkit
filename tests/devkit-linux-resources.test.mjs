import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { plan, sync, verify } from '../src/devkit-engine.mjs';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
function put(file, data) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, data); }
function snapshot(root) {
  const result = {};
  function walk(dir) {
    for (const entry of fs.readdirSync(dir).sort()) {
      const file = path.join(dir, entry), s = fs.lstatSync(file);
      result[path.relative(root, file)] = s.isSymbolicLink() ? `link:${fs.readlinkSync(file)}` :
        s.isDirectory() ? `dir:${s.mode}` : `${s.mode}:${fs.readFileSync(file).toString('base64')}`;
      if (s.isDirectory()) walk(file);
    }
  }
  walk(root);
  return result;
}
function fixture(t, { external = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'devkit-resources-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const devkitRoot = path.join(root, 'devkit'), projectDir = path.join(root, 'project');
  fs.mkdirSync(projectDir);
  const manifest = { profile: 'alpha', skills: ['sample'], hooks: ['guard.mjs'], instructions: ['AGENTS.md', 'CLAUDE.md'],
    targets: { skills: ['.agents/skills', '.claude/skills'], hooks: ['.claude/hooks'] } };
  put(path.join(devkitRoot, 'core/skills/sample/SKILL.md'), '# shared Skill\n');
  // Hooks contain a side effect that must NEVER execute during distribution or verification.
  const sentinel = path.join(root, 'HOOK-EXECUTED');
  put(path.join(devkitRoot, 'core/hooks/guard.mjs'), `import fs from 'node:fs'; fs.writeFileSync(${JSON.stringify(sentinel)}, 'executed');\n`);
  put(path.join(devkitRoot, 'core/instructions/AGENTS.md'), '# generic instructions\n');
  put(path.join(devkitRoot, 'profiles/alpha/instructions/CLAUDE.md'), '# alpha instructions\n');
  put(path.join(devkitRoot, 'profiles/alpha/profile.json'), JSON.stringify({ ...manifest, name: 'alpha', version: '1.0.0' }));
  const options = { devkitRoot, projectDir, profile: 'alpha' };
  const manifestPath = path.join(projectDir, 'agent-devkit.json');
  if (!external) put(manifestPath, JSON.stringify(manifest));
  const lock = external ? path.join(devkitRoot, 'state/alpha/agent-devkit.lock') : path.join(projectDir, 'agent-devkit.lock');
  function update(change) {
    Object.assign(manifest, change);
    if (external) {
      put(path.join(devkitRoot, 'profiles/alpha/profile.json'), JSON.stringify({ ...manifest, name: 'alpha', version: '1.0.0' }));
    } else { put(manifestPath, JSON.stringify(manifest)); delete options.profile; }
  }
  return { root, devkitRoot, projectDir, manifest, manifestPath, options, lock, sentinel, update };
}
const installed = [
  '.agents/skills/sample/SKILL.md', '.claude/skills/sample/SKILL.md',
  '.claude/hooks/guard.mjs', 'AGENTS.md', 'CLAUDE.md',
];
function locked(f) { return JSON.parse(fs.readFileSync(f.lock)); }

test('two physical Skill copies, static hooks and instructions share the existing lock schema', t => {
  const f = fixture(t);
  const result = sync(f.options);
  assert.equal(result.written, 5);
  for (const rel of installed) assert.ok(fs.statSync(path.join(f.projectDir, rel)).isFile());
  const lock = locked(f);
  for (const target of installed.slice(0, 2)) {
    const bytes = fs.readFileSync(path.join(f.projectDir, target));
    assert.equal(digest(bytes), lock.skills.sample.files['SKILL.md'].sha256);
    assert.equal(digest(bytes), digest(fs.readFileSync(path.join(f.devkitRoot, 'core/skills/sample/SKILL.md'))));
    assert.equal(fs.statSync(path.join(f.projectDir, target)).nlink, 1);
  }
  assert.notEqual(fs.statSync(path.join(f.projectDir, installed[0])).ino, fs.statSync(path.join(f.projectDir, installed[1])).ino);
  assert.deepEqual(lock.hooks['guard.mjs'], { source: 'core', sha256: digest(fs.readFileSync(path.join(f.projectDir, '.claude/hooks/guard.mjs'))) });
  assert.equal(lock.instructions['AGENTS.md'].source, 'core');
  assert.equal(lock.instructions['CLAUDE.md'].source, 'profile:alpha');
  for (const item of ['AGENTS.md', 'CLAUDE.md']) assert.equal(lock.instructions[item].sha256, digest(fs.readFileSync(path.join(f.projectDir, item))));
  assert.equal(lock.lockfileVersion, '1.0.0');
  assert.equal(verify(f.options).verified, true);
  assert.equal(fs.existsSync(f.sentinel), false);
  assert.equal(fs.existsSync(path.join(f.projectDir, '.claude/settings.json')), false);
});

test('a local change in only one Skill destination blocks all writes', t => {
  const f = fixture(t);
  sync(f.options);
  fs.appendFileSync(path.join(f.projectDir, installed[1]), 'consumer change');
  fs.appendFileSync(path.join(f.devkitRoot, 'core/hooks/guard.mjs'), '// update');
  const before = snapshot(f.root);
  const result = sync(f.options);
  assert.equal(result.blocked, true);
  assert.equal(result.state.find(s => s.target === installed[0]).status, 'synced');
  assert.equal(result.state.find(s => s.target === installed[1]).status, 'modified');
  assert.deepEqual(snapshot(f.root), before);
});

for (const file of ['AGENTS.md', 'CLAUDE.md', '.claude/hooks/guard.mjs']) {
  for (const identical of [false, true]) {
    test(`unmanaged ${file}, identical=${identical}, is never adopted or overwritten`, t => {
      const f = fixture(t);
      const source = file === 'AGENTS.md' ? 'core/instructions/AGENTS.md' : file === 'CLAUDE.md' ?
        'profiles/alpha/instructions/CLAUDE.md' : 'core/hooks/guard.mjs';
      put(path.join(f.projectDir, file), identical ? fs.readFileSync(path.join(f.devkitRoot, source)) : 'private local instructions');
      const before = snapshot(f.root);
      const result = sync(f.options);
      assert.equal(result.blocked, true);
      assert.equal(result.state.find(s => s.target === file).status, 'untracked');
      assert.deepEqual(snapshot(f.root), before);
    });
  }
}

for (const file of ['AGENTS.md', 'CLAUDE.md', '.claude/hooks/guard.mjs']) {
  test(`managed modification/conflict is protected for ${file}`, t => {
    const f = fixture(t);
    sync(f.options);
    fs.appendFileSync(path.join(f.projectDir, file), '\nlocal edit');
    assert.equal(verify(f.options).state.find(s => s.target === file).status, 'modified');
    const source = file === 'AGENTS.md' ? 'core/instructions/AGENTS.md' : file === 'CLAUDE.md' ?
      'profiles/alpha/instructions/CLAUDE.md' : 'core/hooks/guard.mjs';
    fs.appendFileSync(path.join(f.devkitRoot, source), '\nupstream edit');
    const before = snapshot(f.root);
    const result = sync(f.options);
    assert.equal(result.blocked, true);
    assert.equal(result.state.find(s => s.target === file).status, 'conflict');
    assert.deepEqual(snapshot(f.root), before);
  });
}

test('managed upstream updates change all resource maps, then remain byte-idempotent', t => {
  const f = fixture(t);
  sync(f.options);
  for (const rel of ['core/instructions/AGENTS.md', 'profiles/alpha/instructions/CLAUDE.md', 'core/hooks/guard.mjs']) fs.appendFileSync(path.join(f.devkitRoot, rel), '\nupstream');
  assert.equal(sync(f.options).written, 3);
  assert.equal(verify(f.options).verified, true);
  const before = snapshot(f.root), mtime = fs.statSync(f.lock).mtimeMs;
  assert.equal(sync(f.options).written, 0);
  assert.deepEqual(snapshot(f.root), before);
  assert.equal(fs.statSync(f.lock).mtimeMs, mtime);
});

test('adding hooks/instructions to an existing Skills-only lock actually updates the lock', t => {
  const f = fixture(t);
  f.update({ hooks: [], instructions: [] });
  sync(f.options);
  f.update({ hooks: ['guard.mjs'], instructions: ['AGENTS.md'] });
  const before = fs.readFileSync(f.lock);
  assert.equal(sync(f.options).written, 2);
  assert.notDeepEqual(fs.readFileSync(f.lock), before);
  assert.ok(locked(f).hooks['guard.mjs']);
  assert.ok(locked(f).instructions['AGENTS.md']);
  assert.equal(verify(f.options).verified, true);
});

for (const external of [false, true]) {
  test(`dry-run/verify leave every byte, mode and directory unchanged; external state=${external}`, t => {
    const f = fixture(t, { external });
    const before = snapshot(f.root);
    assert.equal(sync({ ...f.options, dryRun: true }).written, 0);
    assert.equal(verify(f.options).verified, false);
    assert.deepEqual(snapshot(f.root), before);
    sync(f.options);
    const synced = snapshot(f.root);
    assert.equal(verify(f.options).verified, true);
    assert.equal(sync({ ...f.options, dryRun: true }).written, 0);
    assert.deepEqual(snapshot(f.root), synced);
  });
}

for (const section of ['hooks', 'instructions']) {
  test(`missing ${section} aborts before any Skill is installed`, t => {
    const f = fixture(t);
    fs.unlinkSync(path.join(f.devkitRoot, section === 'hooks' ? 'core/hooks/guard.mjs' : 'core/instructions/AGENTS.md'));
    const before = snapshot(f.root);
    assert.throws(() => sync(f.options), /unresolved/);
    assert.deepEqual(snapshot(f.root), before);
  });
  test(`stale locked ${section} cannot be silently removed`, t => {
    const f = fixture(t);
    sync(f.options);
    f.update({ [section]: [] });
    const before = snapshot(f.root);
    assert.throws(() => sync(f.options), /reconciliation/);
    assert.deepEqual(snapshot(f.root), before);
  });
}

for (const [key, value] of [
  ['hooks', ['../guard.mjs']], ['hooks', ['/tmp/guard.mjs']], ['hooks', ['C:\\guard.mjs']],
  ['hooks', ['folder/guard.mjs']], ['hooks', ['guard.mjs\0']], ['hooks', [{ source: 'rp-doces', name: 'guard.mjs' }]],
  ['instructions', ['../AGENTS.md']], ['instructions', ['.claude/settings.json']], ['instructions', ['/tmp/AGENTS.md']],
  ['instructions', ['docs/AGENTS.md']], ['instructions', [{ source: 'core', target: 'AGENTS.md' }]],
  ['targets', { skills: ['.agents/skills'], hooks: ['../hooks'] }],
  ['targets', { hooks: ['/tmp/hooks'] }], ['targets', { hooks: ['.agents/hooks'] }],
  ['targets', { hooks: ['.claude/settings.json'] }], ['targets', { instructions: ['AGENTS.md'] }],
]) {
  test(`rejects unsupported or malicious ${key}=${JSON.stringify(value)}`, t => {
    const f = fixture(t);
    f.update({ [key]: value });
    const before = snapshot(f.root);
    assert.throws(() => sync(f.options), /Unsafe|Unsupported|Expected/);
    assert.deepEqual(snapshot(f.root), before);
  });
}

for (const kind of ['hook-source', 'instruction-source', 'hook-target', 'instruction-target', 'hook-parent']) {
  for (const link of ['symlink', 'hardlink']) {
    if (kind === 'hook-parent' && link === 'hardlink') continue;
    test(`rejects ${link} at ${kind} without touching its referent`, t => {
      const f = fixture(t);
      const outside = path.join(f.root, 'outside');
      put(outside, 'do not touch');
      const rel = {
        'hook-source': path.join(f.devkitRoot, 'core/hooks/guard.mjs'),
        'instruction-source': path.join(f.devkitRoot, 'core/instructions/AGENTS.md'),
        'hook-target': path.join(f.projectDir, '.claude/hooks/guard.mjs'),
        'instruction-target': path.join(f.projectDir, 'AGENTS.md'),
        'hook-parent': path.join(f.projectDir, '.claude'),
      }[kind];
      fs.mkdirSync(path.dirname(rel), { recursive: true });
      if (fs.existsSync(rel)) fs.unlinkSync(rel);
      if (link === 'hardlink') fs.linkSync(outside, rel);
      else fs.symlinkSync(kind === 'hook-parent' ? f.root : outside, rel);
      const before = snapshot(f.root);
      assert.throws(() => sync(f.options), /Symlink|hardlink/);
      assert.deepEqual(snapshot(f.root), before);
    });
  }
}

test('a dangling instruction link is rejected', t => {
  const f = fixture(t);
  fs.symlinkSync(path.join(f.root, 'absent'), path.join(f.projectDir, 'CLAUDE.md'));
  assert.throws(() => sync(f.options), /Symlink/);
});

for (const stage of ['second-skill', 'hook', 'instruction', 'lock']) {
  test(`mixed-resource transaction rolls back after partial writes before ${stage}`, t => {
    const f = fixture(t, { external: stage === 'lock' });
    const before = snapshot(f.root), at = { 'second-skill': 1, hook: 2, instruction: 3, lock: 5 }[stage];
    assert.throws(() => sync(f.options, { beforeWrite(index) { if (index === at) throw new Error('injected mixed-resource failure'); } }), /injected/);
    assert.deepEqual(snapshot(f.root), before);
  });
}

test('mixed managed updates roll back bytes, modes and original lock on a rename error', t => {
  const f = fixture(t);
  sync(f.options);
  fs.chmodSync(path.join(f.projectDir, 'AGENTS.md'), 0o640);
  for (const rel of ['core/skills/sample/SKILL.md', 'core/hooks/guard.mjs', 'core/instructions/AGENTS.md', 'profiles/alpha/instructions/CLAUDE.md']) fs.appendFileSync(path.join(f.devkitRoot, rel), '\nupdate');
  const before = snapshot(f.root), rename = fs.renameSync;
  let n = 0;
  t.mock.method(fs, 'renameSync', (...args) => { if (++n === 5) throw new Error('injected rename error'); return rename(...args); });
  assert.throws(() => sync(f.options), /injected rename error/);
  assert.deepEqual(snapshot(f.root), before);
});

for (const corruption of ['version', 'profile', 'hooks-map', 'instructions-map', 'hash', 'provenance', 'path']) {
  test(`incompatible resource lock (${corruption}) is refused read-only`, t => {
    const f = fixture(t);
    sync(f.options);
    const lock = locked(f);
    if (corruption === 'version') lock.lockfileVersion = '2.0.0';
    if (corruption === 'profile') lock.profile = 'beta@1.0.0';
    if (corruption === 'hooks-map') lock.hooks = [];
    if (corruption === 'instructions-map') lock.instructions = null;
    if (corruption === 'hash') lock.hooks['guard.mjs'].sha256 = 'invalid';
    if (corruption === 'provenance') lock.instructions['AGENTS.md'].source = 'profile:beta';
    if (corruption === 'path') lock.instructions['../CLAUDE.md'] = lock.instructions['CLAUDE.md'];
    put(f.lock, JSON.stringify(lock));
    const before = snapshot(f.root);
    assert.throws(() => sync(f.options), /Incompatible|SHA-256|provenance|Unsafe/);
    assert.deepEqual(snapshot(f.root), before);
  });
}

test('selected profile overrides core but never resolves another profile resource', t => {
  const f = fixture(t);
  put(path.join(f.devkitRoot, 'profiles/alpha/hooks/guard.mjs'), '// alpha only');
  put(path.join(f.devkitRoot, 'profiles/beta/hooks/private.mjs'), '// beta only');
  f.update({ hooks: ['private.mjs'] });
  assert.throws(() => sync(f.options), /unresolved/);
  f.update({ hooks: ['guard.mjs'] });
  sync(f.options);
  assert.equal(fs.readFileSync(path.join(f.projectDir, '.claude/hooks/guard.mjs'), 'utf8'), '// alpha only');
  assert.equal(locked(f).hooks['guard.mjs'].source, 'profile:alpha');
});

test('external locks remain separate per profile and cross-profile reuse is rejected', t => {
  const f = fixture(t, { external: true });
  sync(f.options);
  const original = fs.readFileSync(f.lock);
  const secondProject = path.join(f.root, 'second-project');
  fs.mkdirSync(secondProject);
  put(path.join(f.devkitRoot, 'profiles/beta/profile.json'), JSON.stringify({ name: 'beta', version: '1.0.0', hooks: ['guard.mjs'], instructions: ['AGENTS.md'] }));
  put(path.join(f.devkitRoot, 'profiles/beta/hooks/guard.mjs'), '// beta');
  const beta = { devkitRoot: f.devkitRoot, projectDir: secondProject, profile: 'beta' };
  sync(beta);
  const betaLock = path.join(f.devkitRoot, 'state/beta/agent-devkit.lock');
  assert.equal(JSON.parse(fs.readFileSync(betaLock)).profile, 'beta@1.0.0');
  assert.deepEqual(fs.readFileSync(f.lock), original);
  assert.equal(verify(f.options).verified, true);
  assert.equal(verify(beta).verified, true);
  put(betaLock, original);
  assert.throws(() => sync(beta), /Incompatible/);
});

test('switching profiles on the same consumer cannot adopt previously managed instructions/Hooks', t => {
  const f = fixture(t, { external: true });
  sync(f.options);
  put(path.join(f.devkitRoot, 'profiles/beta/profile.json'), JSON.stringify({ name: 'beta', version: '1.0.0', hooks: ['guard.mjs'], instructions: ['AGENTS.md'] }));
  const before = snapshot(f.root);
  const beta = sync({ ...f.options, profile: 'beta' });
  assert.equal(beta.blocked, true);
  assert.deepEqual(snapshot(f.root), before);
});

test('unselected resource directories do not affect an instructions-only plan', t => {
  const f = fixture(t);
  f.update({ skills: [], hooks: [], instructions: ['AGENTS.md'] });
  fs.symlinkSync(path.join(f.root, 'absent'), path.join(f.projectDir, '.claude'));
  fs.symlinkSync(path.join(f.root, 'absent'), path.join(f.projectDir, '.agents'));
  assert.equal(sync(f.options).written, 1);
  assert.equal(verify(f.options).verified, true);
});

test('adding an unrequested .claude symlink cannot affect an explicit .agents-only Skills plan', t => {
  const f = fixture(t);
  f.update({ hooks: [], instructions: [], targets: { skills: ['.agents/skills'] } });
  fs.symlinkSync(path.join(f.root, 'absent'), path.join(f.projectDir, '.claude'));
  assert.equal(sync(f.options).written, 1);
  assert.equal(verify(f.options).verified, true);
});

test('legacy components.hooks and target arrays agree with PowerShell classification', t => {
  const f = fixture(t);
  f.update({ hooks: [], components: { hooks: ['guard.mjs'] }, targets: ['.agents/skills', '.claude/skills', '.claude/hooks'] });
  assert.equal(sync(f.options).written, 5);
  assert.equal(verify(f.options).verified, true);
});

test('Hooks-only and instructions-only plans do not require a Skill', t => {
  for (const category of ['hooks', 'instructions']) {
    const f = fixture(t);
    f.update({ skills: [], hooks: [], instructions: [], [category]: category === 'hooks' ? ['guard.mjs'] : ['AGENTS.md'] });
    assert.equal(sync(f.options).written, 1);
    assert.equal(verify(f.options).verified, true);
  }
});

test('preexisting settings, Git excludes and unrelated instructions remain byte-identical', t => {
  const f = fixture(t);
  const protectedFiles = { '.claude/settings.json': '{"hooks":{"Stop":[]}}', '.gitignore': 'mine\n', '.git/info/exclude': 'mine\n' };
  for (const [rel, bytes] of Object.entries(protectedFiles)) put(path.join(f.projectDir, rel), bytes);
  sync(f.options);
  verify(f.options);
  for (const [rel, bytes] of Object.entries(protectedFiles)) assert.equal(fs.readFileSync(path.join(f.projectDir, rel), 'utf8'), bytes);
  assert.equal(fs.existsSync(f.sentinel), false);
});

test('legacy Skills-only lock remains byte-compatible with the unchanged Chopp composition', t => {
  const f = fixture(t, { external: true });
  const profile = JSON.parse(fs.readFileSync(path.join(repository, 'profiles/chopp-delivery/profile.json')));
  // Reproduce the previous schema without depending on ignored local state or the real consumer.
  const previousLock = Buffer.from(JSON.stringify({ lockfileVersion: '1.0.0', generatedAt: '2026-10-17T20:06:23.575Z',
    profile: 'chopp-delivery@1.0.0', skills: Object.fromEntries(profile.skills.map(skill => [skill, {
      source: 'core', version: '1.0.0', files: { 'SKILL.md': { sha256: digest(fs.readFileSync(path.join(repository, 'core/skills', skill, 'SKILL.md'))) } },
    }])), hooks: {}, instructions: {}, rules: {}, agents: {}, configs: {}, overlays: {} }, null, 2));
  delete profile.discovery; // This disposable fixture intentionally has no Git origin.
  profile.targets.skills = ['.agents/skills']; // Freeze the legacy composition exercised here.
  put(path.join(f.devkitRoot, 'profiles/chopp-delivery/profile.json'), JSON.stringify(profile));
  for (const skill of profile.skills) {
    fs.cpSync(path.join(repository, 'core/skills', skill), path.join(f.devkitRoot, 'core/skills', skill), { recursive: true });
    fs.cpSync(path.join(repository, 'core/skills', skill), path.join(f.projectDir, '.agents/skills', skill), { recursive: true });
  }
  const lock = path.join(f.devkitRoot, 'state/chopp-delivery/agent-devkit.lock');
  put(lock, previousLock);
  const options = { ...f.options, profile: 'chopp-delivery' };
  const before = snapshot(f.root);
  assert.equal(verify(options).verified, true);
  assert.equal(sync(options).written, 0);
  assert.deepEqual(snapshot(f.root), before);
});

for (const producer of ['Node', 'PowerShell']) {
  test(`actual ${producer} lock is accepted by the other engine for Skills/hooks/instructions`, t => {
    const f = fixture(t);
    const check = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()'], { encoding: 'utf8' });
    if (check.error?.code === 'ENOENT') { t.skip('PowerShell not installed; cross-engine test requires pwsh'); return; }
    assert.equal(check.status, 0, check.error?.message ?? check.stderr);
    const script = path.join(f.root, 'compat.ps1');
    put(script, `param([string]$Module,[string]$DevKit,[string]$Project,[string]$Mode)\n$ErrorActionPreference='Stop'\nImport-Module $Module -Force -DisableNameChecking\nif ($Mode -eq 'sync') { $null=Invoke-DevKitSync -ProjectDir $Project -DevKitRoot $DevKit -NoGitExclude }\n$r=Invoke-DevKitVerify -ProjectDir $Project -DevKitRoot $DevKit\nif (-not $r.Verified) { throw ($r.Discrepancies | ConvertTo-Json -Depth 10) }\n`);
    if (producer === 'Node') sync(f.options);
    const before = producer === 'Node' ? fs.readFileSync(f.lock) : null;
    const r = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-File', script, '-Module', path.join(repository, 'src/DevKit.Engine.psm1'),
      '-DevKit', f.devkitRoot, '-Project', f.projectDir, '-Mode', producer === 'Node' ? 'verify' : 'sync'], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.error?.message ?? r.stderr + r.stdout);
    assert.equal(verify(f.options).verified, true);
    if (before) assert.deepEqual(fs.readFileSync(f.lock), before);
    const current = fs.readFileSync(f.lock);
    assert.equal(sync(f.options).written, 0);
    assert.deepEqual(fs.readFileSync(f.lock), current);
    assert.equal(fs.existsSync(f.sentinel), false);
  });
}
