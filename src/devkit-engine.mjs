import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { isDeepStrictEqual } from 'node:util';

const sections = ['hooks', 'instructions', 'rules', 'agents', 'configs', 'overlays'];
const fileSections = ['hooks', 'instructions'];
const targetsAllowed = ['.agents/skills', '.claude/skills'];
const own = (o, k) => Object.hasOwn(o, k);
const hash = data => createHash('sha256').update(data).digest('hex');
const json = value => Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
function fail(message) { throw new Error(message); }
function name(value) {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(value)) fail(`Unsafe name: ${value}`);
  return value;
}
function relative(value) {
  if (typeof value !== 'string' || !value || value.includes('\0') || value.includes(':')) {
    fail(`Unsafe path: ${value}`);
  }
  if (value.startsWith('\\\\') || value.startsWith('//')) {
    fail(`Unsafe path: ${value}`);
  }
  const normalized = value.replace(/\\/g, '/');
  if (path.posix.isAbsolute(normalized) || normalized.split('/').some(p => !p || p === '.' || p === '..')) {
    fail(`Unsafe path: ${value}`);
  }
  return normalized;
}
function stat(file) {
  try { return fs.lstatSync(file); } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
}
// Inspect every ancestor, including dangling symlinks. Never follow links or special files.
function safe(file, kind = 'file') {
  const absolute = path.resolve(file);
  const parsed = path.parse(absolute);
  let current = parsed.root;
  const parts = absolute.slice(parsed.root.length).split(path.sep).filter(Boolean);
  for (let i = 0; i < parts.length; i++) {
    current = path.join(current, parts[i]);
    const s = stat(current);
    if (!s) continue;
    if (s.isSymbolicLink()) fail(`Symlink rejected: ${current}`);
    if (i < parts.length - 1 || kind === 'directory') {
      if (!s.isDirectory()) fail(`Not a directory: ${current}`);
    } else if (!s.isFile() || s.nlink !== 1) fail(`Unsafe file (special file or hardlink): ${current}`);
  }
  return absolute;
}
function inside(root, rel, kind) {
  const cleanRel = relative(rel);
  const resolvedRoot = path.resolve(root);
  const target = safe(path.join(resolvedRoot, cleanRel), kind);
  const rootWithSep = resolvedRoot.endsWith(path.sep) ? resolvedRoot : resolvedRoot + path.sep;
  if (!target.startsWith(rootWithSep) && target !== resolvedRoot) {
    fail(`Path traversal detected: target escapes root ${root}`);
  }
  return target;
}
function read(file) {
  safe(file);
  if (!stat(file)) return null;
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const s = fs.fstatSync(fd);
    if (!s.isFile() || s.nlink !== 1) fail(`Unsafe file: ${file}`);
    return fs.readFileSync(fd);
  } finally { fs.closeSync(fd); }
}
function readJson(file) {
  const bytes = read(file);
  if (bytes === null) return null;
  const value = JSON.parse(bytes.toString('utf8').replace(/^\uFEFF/, ''));
  if (!object(value)) fail(`Expected JSON object: ${file}`);
  return value;
}
function array(o, key) {
  const value = o[key] ?? [];
  if (!Array.isArray(value) || !value.every(v => typeof v === 'string')) fail(`Expected string array: ${key}`);
  return value;
}
function supported(o) {
  for (const key of [...sections.filter(k => !fileSections.includes(k)), 'thirdPartySkills', 'thirdParty']) {
    if (own(o, key) && (!Array.isArray(o[key]) || o[key].length)) fail(`Unsupported resource: ${key}`);
  }
  if (o.components !== undefined) {
    if (!object(o.components)) fail('Invalid components');
    for (const key of Object.keys(o.components)) {
      if (!['core', 'profile', 'skills', 'hooks'].includes(key)) fail(`Unsupported component: ${key}`);
      array(o.components, key);
    }
  }
}
function resourceName(section, value) {
  relative(value);
  if (section === 'instructions' ? !['AGENTS.md', 'CLAUDE.md'].includes(value) :
    !/^[a-zA-Z0-9][a-zA-Z0-9_-]*\.mjs$/.test(value)) fail(`Unsupported ${section} name: ${value}`);
  return value;
}
export function profileShow(devkitRoot, profileName) {
  const file = inside(devkitRoot, `profiles/${name(profileName)}/profile.json`);
  const profile = readJson(file);
  if (!profile || profile.name !== profileName) fail(`Profile not found or name mismatch: ${profileName}`);
  return profile;
}
function originRepository(projectDir) {
  // Git config is read-only; no checkout, network, hooks, aliases or project code.
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('GIT_')));
  env.GIT_CONFIG_NOSYSTEM = '1';
  env.GIT_CONFIG_GLOBAL = '/dev/null';
  const origin = execFileSync('git', ['-C', projectDir, '-c', 'core.hooksPath=/dev/null',
    'config', '--local', '--no-includes', '--get', 'remote.origin.url'], { encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const match = /^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([\w.-]+\/[\w.-]+?)(?:\.git)?\/?$/.exec(origin);
  if (!match) fail('Origin must be an exact GitHub HTTPS or SSH repository URL');
  return match[1].toLowerCase();
}
export function samePath(a, b, platform = process.platform) {
  if (a === b) return true;
  if (platform === 'win32') {
    let ra = a;
    let rb = b;
    try { ra = fs.realpathSync(a); } catch {}
    try { rb = fs.realpathSync(b); } catch {}
    return path.win32.resolve(ra).toLowerCase() === path.win32.resolve(rb).toLowerCase();
  }
  return false;
}

export function getMachineIdentity({ platform = process.platform, winRegReader = null, linuxReader = null } = {}) {
  if (platform === 'win32') {
    let output = '';
    try {
      if (winRegReader) {
        output = winRegReader();
      } else {
        const regExe = process.env.SystemRoot ? path.join(process.env.SystemRoot, 'System32', 'reg.exe') : 'reg';
        output = execFileSync(regExe, ['query', 'HKLM\\SOFTWARE\\Microsoft\\Cryptography', '/v', 'MachineGuid'], {
          encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']
        });
      }
    } catch {
      fail('Failed to query Windows MachineGuid for checkout state');
    }
    const match = typeof output === 'string' && output.match(/MachineGuid\s+REG_SZ\s+([a-f0-9-]+)/i);
    if (!match || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(match[1])) {
      fail('A valid Windows MachineGuid is required for checkout state');
    }
    return hash(match[1].toLowerCase());
  }
  const bytes = linuxReader ? linuxReader() : read('/etc/machine-id');
  const machine = bytes?.toString('utf8').trim();
  if (!machine || !/^[a-f0-9]{32}$/i.test(machine)) fail('A valid Linux machine-id is required for checkout state');
  return hash(machine);
}

// Checkout state is opt-in. Binding metadata travels with the 1.0.0 lock so
// copying a foreign lock into a namespace fails closed instead of adopting it.
export function checkoutIdentity(projectDir, options = {}) {
  const dotGit = path.join(projectDir, '.git');
  safe(dotGit, stat(dotGit)?.isDirectory() ? 'directory' : 'file');
  if (!stat(dotGit)) fail('Checkout state requires a Git checkout root');
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('GIT_')));
  env.GIT_CONFIG_NOSYSTEM = '1';
  env.GIT_CONFIG_GLOBAL = (options.platform ?? process.platform) === 'win32' ? 'NUL' : '/dev/null';
  const values = execFileSync('git', ['-C', projectDir, '-c', 'core.hooksPath=/dev/null',
    'rev-parse', '--path-format=absolute', '--show-toplevel', '--git-dir', '--git-common-dir'],
    { encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe'] }).trimEnd().split(/\r?\n/);
  if (values.length !== 3) fail('Invalid Git checkout identity');
  const [top, gitDir, commonDir] = values.map(value => fs.realpathSync(safe(value.trim(), 'directory')));
  const canonicalProject = fs.realpathSync(safe(projectDir, 'directory'));
  if (!samePath(top, canonicalProject, options.platform)) fail('Project directory must be the Git checkout root');
  for (const dir of new Set([gitDir, commonDir])) {
    for (const file of ['config', 'config.worktree', 'commondir', 'gitdir']) safe(path.join(dir, file));
  }
  const machine = getMachineIdentity(options);
  const stamp = dir => {
    const s = fs.statSync(dir, { bigint: true });
    return { device: String(s.dev), inode: String(s.ino) };
  };
  const identity = { version: 1, machine, projectDir: top, gitDir, commonDir,
    project: stamp(top), git: stamp(gitDir), origin: originRepository(projectDir) };
  return { identity, id: hash(json(identity)) };
}
function walk(root, prefix = '') {
  safe(root, 'directory');
  if (!stat(root)) return [];
  return fs.readdirSync(root).sort().flatMap(entry => {
    const rel = prefix ? `${prefix}/${entry}` : entry;
    relative(rel);
    const file = path.join(root, entry);
    const s = stat(file);
    if (s?.isDirectory()) return walk(file, rel);
    safe(file);
    return [rel];
  });
}

export function plan({ devkitRoot, projectDir, profile: selectedProfile, manifestFile, stateScope }) {
  devkitRoot = safe(devkitRoot, 'directory');
  projectDir = safe(projectDir, 'directory');
  if (!stat(projectDir)?.isDirectory()) fail('Project directory does not exist');
  if (stateScope !== undefined && stateScope !== 'checkout') fail('Unsupported state scope');
  if (stateScope && (!selectedProfile || manifestFile)) fail('Checkout state requires --profile and forbids --manifest-file');
  const checkout = stateScope ? checkoutIdentity(projectDir) : null;
  if (checkout && (stat(inside(projectDir, 'agent-devkit.json')) || stat(inside(projectDir, 'agent-devkit.lock')))) {
    fail('Checkout state forbids consumer manifest and lock; migrate them explicitly first');
  }
  const manifestPath = inside(projectDir, 'agent-devkit.json');
  const localManifest = readJson(manifestPath);
  // Explicit manifest > explicit profile > project manifest, matching the engine.
  const manifest = manifestFile ? readJson(safe(manifestFile)) :
    selectedProfile ? profileShow(devkitRoot, selectedProfile) : localManifest;
  if (!manifest) fail('Manifest not found; pass --profile or --manifest-file');
  const profileName = name(selectedProfile ?? manifest.profile ?? manifest.name);
  if (manifest.profile && manifest.profile !== profileName) fail('Manifest/profile mismatch');
  const profile = profileShow(devkitRoot, profileName);
  if (profile.discovery?.githubRepository) {
    if (originRepository(projectDir) !== profile.discovery.githubRepository.toLowerCase()) fail('Project origin does not match exclusive profile repository');
    for (const marker of profile.discovery.markers ?? []) {
      if (!stat(inside(projectDir, marker))) fail(`Missing project marker: ${marker}`);
    }
  }
  if (checkout && !profile.discovery?.githubRepository) fail('Checkout state requires an exclusive profile Git origin');
  supported(manifest);
  const requested = [...new Set([...array(manifest, 'skills'),
    ...['core', 'profile', 'skills'].flatMap(k => array(manifest.components ?? {}, k))])];
  requested.forEach(name);
  const resources = {
    hooks: [...new Set([...array(manifest, 'hooks'), ...array(manifest.components ?? {}, 'hooks')])],
    instructions: [...new Set(array(manifest, 'instructions'))],
  };
  for (const section of fileSections) resources[section].forEach(value => resourceName(section, value));
  if (!requested.length && !resources.hooks.length && !resources.instructions.length) fail('No local resources requested');
  let targets, hookTargets;
  if (Array.isArray(manifest.targets)) {
    const legacyTargets = array(manifest, 'targets');
    targets = legacyTargets.filter(t => !t.includes('hook'));
    hookTargets = legacyTargets.filter(t => t.includes('hook'));
  }
  else {
    if (manifest.targets !== undefined && !object(manifest.targets)) fail('Invalid targets');
    for (const key of Object.keys(manifest.targets ?? {})) if (!['skills', 'hooks'].includes(key)) fail(`Unsupported target: ${key}`);
    targets = array(manifest.targets ?? {}, 'skills');
    hookTargets = array(manifest.targets ?? {}, 'hooks');
  }
  if (!targets.length) targets = targetsAllowed;
  targets = [...new Set(targets.map(t => typeof t === 'string' ? t.replace(/\\/g, '/') : t))];
  for (const target of targets) {
    relative(target);
    if (!targetsAllowed.includes(target)) fail(`Unsupported Skills target: ${target}`);
    if (requested.length) inside(projectDir, target, 'directory');
  }
  if (!hookTargets.length) hookTargets = ['.claude/hooks'];
  hookTargets = [...new Set(hookTargets.map(t => typeof t === 'string' ? t.replace(/\\/g, '/') : t))];
  for (const target of hookTargets) {
    relative(target);
    if (target !== '.claude/hooks') fail(`Unsupported Hooks target: ${target}`);
    if (resources.hooks.length) inside(projectDir, target, 'directory');
  }
  // External state is the existing contract, bounded to this DevKit's state/<profile>.
  const binding = checkout ? { ...checkout.identity, profile: profileName } : null;
  const lockPath = checkout ? inside(devkitRoot, `state/${profileName}/checkouts/${checkout.id}/agent-devkit.lock`) :
    localManifest ? inside(projectDir, 'agent-devkit.lock') :
    inside(devkitRoot, `state/${profileName}/agent-devkit.lock`);
  const oldLockBytes = read(lockPath);
  const lock = readJson(lockPath);
  if (lock && (checkout ? !isDeepStrictEqual(lock.checkoutState, binding) : own(lock, 'checkoutState'))) {
    fail('Checkout state binding mismatch (foreign, missing or incompatible ownership)');
  }
  if (lock) {
    if (lock.lockfileVersion !== '1.0.0' || lock.profile !== `${profileName}@1.0.0` || !object(lock.skills)) fail('Incompatible lockfile');
    for (const key of sections) {
      if (own(lock, key) && !object(lock[key])) fail(`Incompatible lockfile section: ${key}`);
      if (!fileSections.includes(key) && Object.keys(lock[key] ?? {}).length) fail(`Unsupported locked resource: ${key}`);
    }
    for (const [skill, entry] of Object.entries(lock.skills)) {
      name(skill);
      if (!object(entry) || !object(entry.files) || !['core', `profile:${profileName}`].includes(entry.source)) fail('Unsupported locked provenance');
      for (const [rel, value] of Object.entries(entry.files)) {
        relative(rel);
        if (!object(value) || !/^[a-f0-9]{64}$/.test(value.sha256)) fail('Invalid locked SHA-256');
      }
    }
    for (const section of fileSections) {
      for (const [item, entry] of Object.entries(lock[section] ?? {})) {
        resourceName(section, item);
        if (!object(entry) || !['core', `profile:${profileName}`].includes(entry.source)) fail('Unsupported locked provenance');
        if (!/^[a-f0-9]{64}$/.test(entry.sha256)) fail('Invalid locked SHA-256');
      }
    }
  }
  const skills = Object.create(null);
  const state = [];
  const expected = new Set();
  for (const skill of requested) {
    const profileDir = inside(devkitRoot, `profiles/${profileName}/skills/${skill}`, 'directory');
    const source = stat(profileDir) ? `profile:${profileName}` : 'core';
    const sourceDir = source === 'core' ? inside(devkitRoot, `core/skills/${skill}`, 'directory') : profileDir;
    if (!stat(sourceDir)) fail(`Unsupported or unresolved local Skill: ${skill} (third-party downloads are unsupported)`);
    if (!read(inside(sourceDir, 'SKILL.md'))) fail(`Missing SKILL.md: ${skill}`);
    const files = Object.create(null);
    for (const rel of walk(sourceDir)) {
      const bytes = read(inside(sourceDir, rel));
      const sha256 = hash(bytes);
      files[rel] = { sha256 };
      const lockHash = lock?.skills[skill]?.files[rel]?.sha256;
      for (const target of targets) {
        const targetRel = `${target}/${skill}/${rel}`;
        const targetPath = inside(projectDir, targetRel);
        const before = read(targetPath);
        const targetHash = before === null ? null : hash(before);
        const status = before === null ? 'missing' : !lockHash ? (targetHash === sha256 ? 'synced' : 'modified') :
          targetHash === lockHash ? (sha256 === lockHash ? 'synced' : 'update_available') :
            (sha256 === lockHash ? 'modified' : 'conflict');
        expected.add(targetRel);
        state.push({ type: 'skill', skill, file: rel, target: targetRel, targetPath, source, sha256, status, bytes, before });
      }
    }
    skills[skill] = { source, version: '1.0.0', files };
  }
  const resourceLocks = { hooks: Object.create(null), instructions: Object.create(null) };
  for (const section of fileSections) {
    for (const item of resources[section]) {
      // Same source precedence as PowerShell: selected profile first, then core.
      // Never search another profile, import hooks, or evaluate their contents.
      const profilePath = inside(devkitRoot, `profiles/${profileName}/${section}/${item}`);
      const source = stat(profilePath) ? `profile:${profileName}` : 'core';
      const sourcePath = source === 'core' ? inside(devkitRoot, `core/${section}/${item}`) : profilePath;
      const bytes = read(sourcePath);
      if (bytes === null) fail(`Unsupported or unresolved local ${section}: ${item}`);
      const sha256 = hash(bytes);
      const entry = lock?.[section]?.[item];
      resourceLocks[section][item] = { ...entry, source, sha256 };
      const destinations = section === 'hooks' ? hookTargets.map(t => `${t}/${item}`) : [item];
      for (const target of destinations) {
        const targetPath = inside(projectDir, target);
        const before = read(targetPath);
        const targetHash = before === null ? null : hash(before);
        // Instructions/hooks are never adopted from unmanaged consumer files,
        // even when byte-identical. Existing instructions are never merged.
        const status = before === null ? 'missing' : !entry ? 'untracked' :
          targetHash === entry.sha256 ? (sha256 === entry.sha256 ? 'synced' : 'update_available') :
            (sha256 === entry.sha256 ? 'modified' : 'conflict');
        expected.add(target);
        state.push({ type: section === 'hooks' ? 'hook' : 'instruction', file: item, target, targetPath, source, sha256, status, bytes, before });
      }
    }
    for (const item of Object.keys(lock?.[section] ?? {})) {
      if (!own(resourceLocks[section], item)) fail(`Stale locked resource requires explicit reconciliation: ${section}/${item}`);
    }
  }
  // Never silently drop old lock entries or remove obsolete managed files.
  for (const [skill, entry] of Object.entries(lock?.skills ?? {})) {
    for (const rel of Object.keys(entry.files)) {
      if (!skills[skill]?.files[rel]) fail(`Stale locked file requires explicit reconciliation: ${skill}/${rel}`);
    }
  }
  for (const target of [...(requested.length ? targets : []), ...(resources.hooks.length ? hookTargets : [])]) {
    for (const rel of walk(inside(projectDir, target, 'directory'))) {
      const full = `${target}/${rel}`;
      if (!expected.has(full)) state.push({ target: full, status: 'untracked' });
    }
  }
  const newLock = { ...lock, lockfileVersion: '1.0.0', generatedAt: lock?.generatedAt ?? new Date().toISOString(),
    ...(binding ? { checkoutState: binding } : {}), profile: `${profileName}@1.0.0`, skills, ...Object.fromEntries(sections.map(k => [k, {}])), ...resourceLocks };
  // Retain compatible metadata/provenance; fail above for unsupported resource types.
  if (lock) {
    for (const [skill, entry] of Object.entries(skills)) newLock.skills[skill] = { ...lock.skills[skill], ...entry };
  }
  let lockBytes = json(newLock);
  const normalizedLock = lock && { ...lock, ...Object.fromEntries(sections.map(k => [k, lock[k] ?? {}])) };
  if (lock && isDeepStrictEqual(JSON.parse(JSON.stringify(newLock)), normalizedLock)) lockBytes = oldLockBytes;
  else if (lock) { newLock.generatedAt = new Date().toISOString(); lockBytes = json(newLock); }
  return { projectDir, devkitRoot, lockPath, oldLockBytes, lockBytes, state, checkout };
}

function equal(a, b) { return a === null ? b === null : b !== null && a.equals(b); }

// All content is buffered before mutation. The lock is committed last. No Skills are executed.
// beforeWrite is an internal fault-injection seam for tests, never a CLI option or manifest hook.
export function sync(options, { beforeWrite = () => {} } = {}) {
  const p = plan(options);
  const blocked = p.state.filter(s => ['modified', 'conflict', 'untracked'].includes(s.status));
  if (blocked.length) return { ...p, blocked: true, written: 0 };
  if (options.dryRun) return { ...p, blocked: false, written: 0 };
  const writes = p.state.filter(s => ['missing', 'update_available'].includes(s.status));
  const changes = writes.map(s => ({ file: s.targetPath, bytes: s.bytes, before: s.before }));
  if (!equal(p.oldLockBytes, p.lockBytes)) changes.push({ file: p.lockPath, bytes: p.lockBytes, before: p.oldLockBytes });
  if (!changes.length) return { ...p, blocked: false, written: 0 };
  const guard = p.checkout ? inside(p.devkitRoot, `.agent-devkit-checkout-${p.checkout.id}.sync`) :
    inside(p.projectDir, '.agent-devkit-sync');
  if (p.checkout && stat(inside(p.projectDir, '.agent-devkit-sync'))) fail('Legacy sync guard exists for this checkout');
  let guardFd;
  const createdDirs = [];
  const committed = [];
  function mkdir(dir) {
    safe(dir, 'directory');
    if (stat(dir)) return;
    mkdir(path.dirname(dir));
    fs.mkdirSync(dir);
    createdDirs.push(dir);
  }
  function replace(file, bytes, mode) {
    safe(file);
    const temp = path.join(path.dirname(file), `.agent-devkit-${randomUUID()}.tmp`);
    let created = false;
    try {
      const fd = fs.openSync(temp, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, mode);
      created = true;
      try { fs.writeFileSync(fd, bytes); fs.fchmodSync(fd, mode); } finally { fs.closeSync(fd); }
      fs.renameSync(temp, file);
      created = false;
    } finally { if (created) fs.unlinkSync(temp); }
  }
  try {
    guardFd = fs.openSync(guard, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
    if (p.checkout && !isDeepStrictEqual(checkoutIdentity(p.projectDir), p.checkout)) fail('Checkout identity changed during sync');
    // Refuse a stale plan if any evaluated target or the lock changed.
    for (const s of p.state) if (!equal(read(s.targetPath), s.before)) fail(`Target changed during sync: ${s.target}`);
    if (!equal(read(p.lockPath), p.oldLockBytes)) fail('Lock changed during sync');
    for (const [index, change] of changes.entries()) {
      mkdir(path.dirname(change.file));
      beforeWrite(index, change.file);
      if (p.checkout && !isDeepStrictEqual(checkoutIdentity(p.projectDir), p.checkout)) fail('Checkout identity changed during sync');
      if (!equal(read(change.file), change.before)) fail(`Target changed during sync: ${change.file}`);
      const mode = stat(change.file)?.mode & 0o777;
      replace(change.file, change.bytes, change.before === null ? 0o644 : mode);
      committed.push({ ...change, mode });
    }
  } catch (error) {
    const errors = [];
    for (const change of committed.reverse()) {
      try {
        if (!equal(read(change.file), change.bytes)) fail(`Rollback refused concurrent modification: ${change.file}`);
        if (change.before === null) fs.unlinkSync(change.file);
        else replace(change.file, change.before, change.mode);
      } catch (rollbackError) { errors.push(rollbackError); }
    }
    for (const dir of createdDirs.reverse()) { try { fs.rmdirSync(dir); } catch (e) { errors.push(e); } }
    if (errors.length) throw new AggregateError([error, ...errors], `Sync failed; rollback incomplete: ${errors.map(e => e.message).join('; ')}`);
    throw error;
  } finally {
    if (guardFd !== undefined) { fs.closeSync(guardFd); fs.unlinkSync(guard); }
  }
  return { ...p, blocked: false, written: writes.length };
}

export function verify(options) {
  const p = plan(options);
  return { ...p, verified: p.oldLockBytes !== null && p.state.every(s => s.status === 'synced') && equal(p.oldLockBytes, p.lockBytes) };
}
