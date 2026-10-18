// Successor to the archived /tmp/devkit-2db-migrate.mjs. No import-time execution.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Transaction, sha, git } from './migration-guards.mjs';

const env = { ...process.env, GIT_OPTIONAL_LOCKS: '0' };
// A runner launched from node:test must still execute its independent validation suite.
delete env.NODE_TEST_CONTEXT;
const read = f => fs.readFileSync(f);
const exists = f => { try { fs.lstatSync(f); return true; } catch (e) { if (e.code === 'ENOENT') return false; throw e; } };
function safe(f) {
  let p = path.parse(f).root;
  for (const n of f.slice(p.length).split('/').filter(Boolean)) {
    p = path.join(p, n); if (!exists(p)) continue;
    const s = fs.lstatSync(p);
    assert(!s.isSymbolicLink() && (s.isDirectory() || (s.isFile() && s.nlink === 1)), `unsafe path: ${p}`);
  }
}
export function fileMeta(f) {
  safe(f); const s = fs.lstatSync(f, { bigint: true }); assert(s.isFile());
  return { sha256: sha(read(f)), inode: String(s.ino), device: String(s.dev), mtimeNs: String(s.mtimeNs),
    mode: Number(s.mode).toString(8), size: String(s.size), nlink: String(s.nlink) };
}
const snapshot = files => Object.fromEntries(files.map(f => [f, fileMeta(f)]));
const same = expected => assert.deepEqual(snapshot(Object.keys(expected)), expected);
const walk = dir => !exists(dir) ? [] : (safe(dir), fs.readdirSync(dir).sort().flatMap(n => {
  const f = path.join(dir, n); safe(f); return fs.lstatSync(f).isDirectory() ? walk(f) : [f];
}));
const edits = ['profiles/chopp-delivery/profile.json', 'tests/devkit-linux.test.mjs', 'tests/devkit-linux-resources.test.mjs'];
const replacements = [
  [['"targets": { "skills": [".agents/skills"] }', '"targets": { "skills": [".agents/skills", ".claude/skills"] }']],
  [['assert.equal(sync(f.options).written, 4);', 'assert.equal(sync(f.options).written, 8);'],
    ["assert.equal(fs.existsSync(path.join(f.projectDir, '.claude')), false);", "assert.equal(fs.existsSync(path.join(f.projectDir, '.claude/hooks')), false);\n  assert.deepEqual(p.instructions, []);"],
    ['assert.equal(plan(f.options).state.length, 4);', 'assert.equal(plan(f.options).state.length, 8);']],
  [['  delete profile.discovery; // This disposable fixture intentionally has no Git origin.',
    "  delete profile.discovery; // This disposable fixture intentionally has no Git origin.\n  profile.targets.skills = ['.agents/skills']; // Freeze the legacy composition exercised here."]]
];

function boundary(config) {
  assert(['scratch', 'execute'].includes(config.mode), 'explicit scratch or execute mode required');
  const roots = [config.devkitRoot, config.projectDir].map(p => {
    assert(path.isAbsolute(p)); safe(p); const real = fs.realpathSync(p);
    assert.equal(real, p, 'canonical root required');
    if (config.mode === 'scratch') assert(real.startsWith('/tmp/'), 'scratch root must be under /tmp');
    assert(fs.lstatSync(path.join(real, '.git')).isDirectory(), 'independent Git checkout required');
    return real;
  });
  assert(!roots[0].startsWith(roots[1] + '/') && !roots[1].startsWith(roots[0] + '/') && roots[0] !== roots[1]);
  if (config.mode === 'execute') assert.deepEqual(roots, ['/home/zzzzz/dev/agent-devkit', '/home/zzzzz/dev/chopp-delivery']);
  return roots;
}

class Migration {
  constructor(config, journal) {
    [this.D, this.C] = boundary(config); this.config = config;
    this.checkpoint = config.checkpoint ?? (() => {});
    if (journal) {
      this.j = journal; this.base = journal.base;
      assert.deepEqual([journal.config.devkitRoot, journal.config.projectDir], [this.D, this.C]);
      assert.equal(this.base, path.join(this.D, 'state/chopp-delivery/migration-backups', journal.id));
      safe(this.base);
      this.tx = Transaction.recover(path.join(this.base, 'guards.json'), { scope: config.mode });
      assert.equal(this.tx.j.id, journal.id);
    }
  }
  save(action, details = {}) {
    this.j.steps.push({ at: new Date().toISOString(), action, ...details });
    const file = path.join(this.base, 'journal.json'), tmp = `${file}.${randomUUID()}.tmp`;
    const fd = fs.openSync(tmp, 'wx', 0o600);
    try { fs.writeFileSync(fd, JSON.stringify(this.j, null, 2) + '\n'); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    fs.renameSync(tmp, file); this.fsyncDir(this.base);
  }
  fsyncDir(dir) { const fd = fs.openSync(dir, 'r'); try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); } }
  at(stage) { this.save(stage); this.checkpoint(stage, this); }
  rename(from, to) {
    safe(from); safe(to); assert(!exists(to), `occupied rename target: ${to}`);
    // Linux renameat2(RENAME_NOREPLACE): same reviewed no-overwrite primitive as the original runner.
    const code = 'import ctypes,os,sys; lib=ctypes.CDLL(None,use_errno=True); r=lib.renameat2(-100,os.fsencode(sys.argv[1]),-100,os.fsencode(sys.argv[2]),1); e=ctypes.get_errno();\nif r: raise OSError(e,os.strerror(e))';
    execFileSync('python3', ['-c', code, from, to], { env });
    this.fsyncDir(path.dirname(from)); this.fsyncDir(path.dirname(to));
  }
  move(from, to) {
    const record = { from, to, before: fileMeta(from), state: 'intent' };
    this.j.moves.push(record); this.save('rename-intent', record);
    this.rename(from, to); record.state = 'moved'; this.save('renamed', { from, to });
  }
  mkdir(dir) {
    if (exists(dir)) { safe(dir); return; }
    this.mkdir(path.dirname(dir));
    const record = { dir, state: 'intent' }; this.j.createdDirs.push(record); this.save('mkdir-intent', { dir });
    fs.mkdirSync(dir); const s = fs.lstatSync(dir, { bigint: true });
    Object.assign(record, { state: 'created', inode: String(s.ino), device: String(s.dev) }); this.save('directory-created', { dir });
  }
  cli(kind) {
    const args = [path.join(this.D, 'bin/agent-devkit.mjs'), kind === 'verify' ? 'verify' : 'sync',
      '--profile', 'chopp-delivery', '--project-dir', this.C, '--state-scope', 'checkout', ...(kind === 'dry-run' ? ['--dry-run'] : [])];
    const result = JSON.parse(execFileSync(process.execPath, args, { cwd: this.D, env, encoding: 'utf8' }));
    assert.equal(result.state.length, 8); assert(result.state.every(s => s.type === 'skill' && s.status === 'synced' && s.source === 'core'));
    if (kind === 'verify') assert.equal(result.verified, true);
    else { assert.equal(result.written, 0); assert.equal(result.blocked, false); }
    fs.writeFileSync(path.join(this.base, `${kind}.json`), JSON.stringify(result, null, 2)); return result;
  }
  expected() { return { [this.D]: Object.fromEntries(this.j.edits.filter(e => e.state !== 'restored').map(e => [path.relative(this.D, e.file), e.expectedHash])) }; }
  preflight(readGit = git, writerCommand = /^(node|nodejs|pwsh|powershell)$/) {
    const git = readGit;
    const trimGit = (root, ...args) => git(root, ...args).trim();
    const { D, C } = this, inventory = this.config.inventory;
    assert(inventory && Object.keys(inventory).length); same(inventory);
    for (const root of [D, C]) {
      assert.equal(trimGit(root, 'rev-parse', 'HEAD'), this.config.heads[root]);
      assert.equal(trimGit(root, 'branch', '--show-current'), this.config.branches[root]);
      assert.equal(git(root, 'status', '--porcelain=v1', '--untracked-files=all'), '');
      assert.equal(trimGit(root, 'diff', '--cached', '--name-only'), '');
      assert.equal(git(root, 'worktree', 'list', '--porcelain').split('\n').filter(l => l.startsWith('worktree ')).length, 1);
      assert(!fs.readdirSync(root).some(n => n === '.agent-devkit-sync' || /^\.agent-devkit.*\.sync$/.test(n)), 'preexisting guard');
    }
    const processes = execFileSync('ps', ['-eo', 'pid=,comm=,args='], { encoding: 'utf8' }).split('\n').filter(line => {
      const m = line.trim().match(/^(\d+)\s+(\S+)\s+(.*)$/);
      return m && Number(m[1]) !== process.pid && writerCommand.test(m[2]) &&
        [D, C].some(root => m[3].includes(root)) && /agent-devkit\.(mjs|ps1).*\bsync\b|sync-profile\.ps1|(?:^|\s)\S*\/migrate-2db\.mjs(?:\s|$)/.test(m[3]);
    });
    assert.deepEqual(processes, [], 'concurrent writer process');
    const flat = path.join(D, 'state/chopp-delivery/agent-devkit.lock');
    const archiveRoot = `${D}/state/chopp-delivery/migration-backups`;
    const archiveInventory = this.config.archiveInventory ?? {};
    assert(Object.keys(archiveInventory).every(f => f.startsWith(archiveRoot + '/')), 'archive inventory outside backup area');
    assert.deepEqual(walk(archiveRoot), Object.keys(archiveInventory).toSorted(), 'preexisting backups require exact approved inventory');
    same(archiveInventory);
    assert.deepEqual(walk(path.join(D, 'state')).filter(f => !Object.hasOwn(archiveInventory, f)), [flat]);
    const skills = Object.keys(inventory).filter(f => f.startsWith(C + '/.')); assert.equal(skills.length, 8);
    assert.deepEqual([...walk(`${C}/.agents/skills`), ...walk(`${C}/.claude/skills`)].sort(), skills.toSorted());
    assert.equal(trimGit(C, 'ls-files', '--', ...skills.map(f => path.relative(C, f)), 'agent-devkit.json', 'agent-devkit.lock'), '');
    for (const f of [...skills, `${C}/agent-devkit.json`, `${C}/agent-devkit.lock`]) git(C, 'check-ignore', '--', f);
    const legacyBytes = read(flat), legacy = JSON.parse(legacyBytes);
    assert.deepEqual(read(`${C}/agent-devkit.lock`), legacyBytes); assert.equal(legacy.profile, 'chopp-delivery@1.0.0'); assert(!Object.hasOwn(legacy, 'checkoutState'));
    const manifest = JSON.parse(read(`${C}/agent-devkit.json`)), profile = JSON.parse(read(`${D}/${edits[0]}`));
    assert.deepEqual(manifest.skills, profile.skills); assert.deepEqual(manifest.targets.skills, ['.agents/skills', '.claude/skills']);
    assert.deepEqual(profile.targets.skills, ['.agents/skills']);
    for (const n of profile.skills) {
      assert.equal(legacy.skills[n].source, 'core'); assert.equal(sha(read(`${D}/core/skills/${n}/SKILL.md`)), legacy.skills[n].files['SKILL.md'].sha256);
    }
    const tracked = root => git(root, 'ls-files', '-z').split('\0').filter(Boolean).map(n => path.join(root, n));
    const protectedBefore = snapshot([...tracked(C), ...tracked(D).filter(f => !edits.includes(path.relative(D, f))), ...skills, ...Object.keys(archiveInventory),
      ...[D, C].flatMap(root => ['index', 'info/exclude', 'config', 'HEAD'].map(n => `${root}/.git/${n}`))]);
    return { flat, legacy, legacyBytes, protectedBefore, skills, processes };
  }
  async run() {
    const { D, C } = this, initial = this.preflight();
    // Import the unchanged engine only after proving that both roots are disposable.
    const { plan } = await import(pathToFileURL(`${D}/src/devkit-engine.mjs`));
    const id = `2db-${new Date().toISOString().replaceAll(':', '-')}-${randomUUID()}`;
    this.base = `${D}/state/chopp-delivery/migration-backups/${id}`;
    safe(path.dirname(this.base)); fs.mkdirSync(this.base, { recursive: true, mode: 0o700 });
    for (const n of ['backup', 'quarantine', 'archive']) fs.mkdirSync(`${this.base}/${n}`, { mode: 0o700 });
    assert.equal(String(fs.statSync(this.base, { bigint: true }).dev), fileMeta(`${C}/agent-devkit.lock`).device);
    this.j = { id, base: this.base, status: 'active', config: { mode: this.config.mode, devkitRoot: D, projectDir: C },
      protectedBefore: initial.protectedBefore, inventory: this.config.inventory, originals: {}, moves: [], edits: [], createdDirs: [], steps: [] };
    this.save('preflight-passed', { processes: initial.processes });
    this.tx = new Transaction([D, C], `${this.base}/guards.json`, undefined, { id, scope: this.config.mode }); this.tx.preflight();
    this.j.guardJournal = this.tx.file; this.save('guard-journal-created');
    for (const f of [...edits.map(n => `${D}/${n}`), initial.flat, `${C}/agent-devkit.json`, `${C}/agent-devkit.lock`]) {
      const backup = `${this.base}/backup/${f.startsWith(C + '/') ? 'consumer-' + path.basename(f) : path.relative(D, f).replaceAll('/', '__')}`;
      fs.copyFileSync(f, backup, fs.constants.COPYFILE_EXCL); assert.deepEqual(read(f), read(backup));
      this.j.originals[f] = { backup, before: fileMeta(f) };
    }
    const self = fileURLToPath(import.meta.url), guards = fileURLToPath(new URL('./migration-guards.mjs', import.meta.url));
    for (const source of [self, guards]) fs.copyFileSync(source, `${this.base}/backup/${path.basename(source)}`, fs.constants.COPYFILE_EXCL);
    this.save('backups-created');
    try {
      this.tx.acquire(`${C}/.agent-devkit-sync`); same(this.j.inventory); same(this.j.protectedBefore);
      this.at('after-consumer-guard');
      for (const [i, n] of edits.entries()) {
        const file = `${D}/${n}`; assert.deepEqual(fileMeta(file), this.j.originals[file].before);
        let text = read(file).toString(); for (const [from, to] of replacements[i]) { assert.equal(text.split(from).length, 2); text = text.replace(from, to); }
        const record = { file, expectedHash: sha(text), state: 'intent' }; this.j.edits.push(record); this.save('edit-intent', record);
        const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW);
        try { fs.ftruncateSync(fd, 0); fs.writeFileSync(fd, text); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
        assert.equal(sha(read(file)), record.expectedHash); record.after = fileMeta(file); record.state = 'edited'; this.save('edited', { file });
      }
      for (const n of ['agent-devkit.json', 'agent-devkit.lock']) this.move(`${C}/${n}`, `${this.base}/quarantine/${n}`);
      this.at('after-local-retirement');
      const options = { devkitRoot: D, projectDir: C, profile: 'chopp-delivery', stateScope: 'checkout' };
      const p = plan(options); assert.equal(p.state.length, 8); assert(p.state.every(s => s.status === 'synced' && s.source === 'core')); assert.equal(p.oldLockBytes, null);
      this.j.checkout = p.checkout; this.j.lockPath = p.lockPath; this.save('checkout-planned');
      this.tx.acquire(`${D}/.agent-devkit-checkout-${p.checkout.id}.sync`);
      assert.deepEqual(plan(options).checkout, p.checkout); same(this.j.protectedBefore);
      const newLock = { ...initial.legacy, checkoutState: { ...p.checkout.identity, profile: 'chopp-delivery' } };
      const { checkoutState, ...rest } = newLock; assert.deepEqual(rest, initial.legacy);
      const bytes = Buffer.from(JSON.stringify(newLock, null, 2) + '\n'); this.mkdir(path.dirname(p.lockPath));
      this.save('seed-intent', { file: p.lockPath, sha256: sha(bytes) });
      const fd = fs.openSync(p.lockPath, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o644);
      this.j.seed = { file: p.lockPath, inode: String(fs.fstatSync(fd, { bigint: true }).ino), sha256: sha(bytes), state: 'writing' }; this.save('seed-opened');
      try { fs.writeFileSync(fd, bytes); fs.fchmodSync(fd, 0o644); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
      this.j.seed.after = fileMeta(p.lockPath); this.j.seed.state = 'created'; this.save('seed-created'); this.at('after-seed');
      this.cli('verify'); this.cli('dry-run'); same(this.j.protectedBefore);
      const tests = spawnSync(process.execPath, ['--test', '--test-reporter=tap', 'tests/devkit-linux.test.mjs', 'tests/devkit-linux-resources.test.mjs', 'tests/devkit-checkout-state.test.mjs'],
        { cwd: D, env, encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024 });
      fs.writeFileSync(`${this.base}/tests.log`, (tests.stdout ?? '') + '\n' + (tests.stderr ?? '')); assert.equal(tests.status, 0, tests.stderr || tests.stdout?.slice(-4000));
      for (const line of ['# tests 169', '# pass 169', '# fail 0', '# skipped 0', '# cancelled 0']) assert(tests.stdout.split('\n').includes(line), line);
      for (const n of ['bin/agent-devkit.mjs', 'src/devkit-engine.mjs', ...edits.slice(1), 'tests/devkit-checkout-state.test.mjs'])
        execFileSync(process.execPath, ['--check', `${D}/${n}`], { env });
      git(D, 'diff', '--check'); same(this.j.protectedBefore); assert.equal(sha(read(initial.flat)), sha(initial.legacyBytes));
      this.at('pre-release-validation-passed'); this.move(initial.flat, `${this.base}/archive/central-legacy.lock`);
      this.cli('verify'); this.cli('dry-run'); same(this.j.protectedBefore);
      this.at('before-intermediate-gate'); this.tx.gate({ expected: this.expected() });
      this.at('before-release'); this.tx.release(this.config.releaseOptions); this.at('after-release');
      this.cli('verify'); this.cli('dry-run'); same(this.j.protectedBefore);
      this.at('before-final-gate'); this.tx.gate({ final: true, expected: this.expected() });
      this.j.status = 'completed'; this.j.lockHash = sha(read(p.lockPath)); this.save('completed');
    } catch (error) {
      this.j.failure = String(error.stack ?? error); this.j.status = 'failed'; this.save('failed');
      try { this.rollback(); } catch (conflict) { this.j.status = 'rollback-conflict'; this.j.rollbackError = String(conflict.stack ?? conflict); this.save('rollback-conflict'); }
    } finally { this.tx.dispose(); }
    return { status: this.j.status, base: this.base, failure: this.j.failure, rollbackError: this.j.rollbackError };
  }
  validateRollback() {
    const allowedEdits = edits.map(n => `${this.D}/${n}`);
    const allowedMoves = new Map(['agent-devkit.json', 'agent-devkit.lock'].map(n => [`${this.C}/${n}`, `${this.base}/quarantine/${n}`]));
    allowedMoves.set(`${this.D}/state/chopp-delivery/agent-devkit.lock`, `${this.base}/archive/central-legacy.lock`);
    const allowedOriginals = new Set([...allowedEdits, ...allowedMoves.keys()]);
    for (const [file, original] of Object.entries(this.j.originals)) {
      assert(allowedOriginals.has(file), 'unexpected original in journal');
      assert(path.dirname(original.backup) === `${this.base}/backup`, 'backup outside operation');
      assert.equal(fileMeta(original.backup).sha256, original.before.sha256, 'backup changed');
    }
    for (const move of this.j.moves) {
      assert.equal(allowedMoves.get(move.from), move.to, 'unexpected move in journal');
      assert.deepEqual(move.before, this.j.originals[move.from].before);
      if (exists(move.from) && !exists(move.to)) { assert.deepEqual(fileMeta(move.from), move.before); continue; }
      assert(!exists(move.from) && exists(move.to), 'rename rollback conflict'); assert.deepEqual(fileMeta(move.to), move.before);
    }
    for (const e of this.j.edits) {
      assert(allowedEdits.includes(e.file), 'unexpected edit in journal');
      const original = this.j.originals[e.file]; assert.equal(fileMeta(original.backup).sha256, original.before.sha256);
      if (e.state === 'restored' || e.state === 'restoring') {
        if (sha(read(e.file)) === original.before.sha256) continue;
      }
      assert.deepEqual(fileMeta(e.file), e.after, `third-party edit ${e.file}`);
    }
    const seed = this.j.seed;
    if (seed && seed.state !== 'removed') {
      assert(/^[a-f0-9]{64}$/.test(this.j.checkout.id));
      assert.equal(seed.file, `${this.D}/state/chopp-delivery/checkouts/${this.j.checkout.id}/agent-devkit.lock`);
      if (!exists(seed.file)) assert.equal(seed.state, 'removing', 'missing seed');
      else assert.deepEqual(fileMeta(seed.file), seed.after, 'seed changed or incomplete; manual recovery required');
    }
    for (const d of this.j.createdDirs) if (exists(d.dir)) {
      assert([`${this.D}/state/chopp-delivery/checkouts`, `${this.D}/state/chopp-delivery/checkouts/${this.j.checkout?.id}`].includes(d.dir), 'unexpected directory in journal');
      safe(d.dir); const s = fs.lstatSync(d.dir, { bigint: true });
      assert(s.isDirectory() && String(s.ino) === d.inode && String(s.dev) === d.device, 'directory ownership conflict');
    }
  }
  rollback() {
    this.tx.reacquireReleased(); for (const g of this.tx.j.guards) this.tx.validate(g);
    this.validateRollback(); this.save('rollback-started');
    const seed = this.j.seed;
    if (seed && seed.state !== 'removed') {
      if (exists(seed.file)) { assert.deepEqual(fileMeta(seed.file), seed.after); seed.state = 'removing'; this.save('seed-remove-intent'); fs.unlinkSync(seed.file); this.fsyncDir(path.dirname(seed.file)); }
      seed.state = 'removed'; this.save('rollback-seed-removed');
    }
    for (const d of this.j.createdDirs.toReversed()) if (exists(d.dir)) {
      fs.rmdirSync(d.dir); d.state = 'removed'; this.save('rollback-directory-removed', { dir: d.dir });
    }
    for (const m of this.j.moves.toReversed()) if (exists(m.to)) {
      assert.deepEqual(fileMeta(m.to), m.before); this.save('rollback-rename-intent', { from: m.to, to: m.from });
      this.rename(m.to, m.from); m.state = 'restored'; this.save('rollback-rename', { from: m.to, to: m.from });
    }
    for (const e of this.j.edits.toReversed()) {
      const original = this.j.originals[e.file];
      if (['restored', 'restoring'].includes(e.state) && sha(read(e.file)) === original.before.sha256) { e.state = 'restored'; continue; }
      assert.deepEqual(fileMeta(e.file), e.after, 'third-party edit before restore'); e.state = 'restoring'; this.save('rollback-edit-intent', { file: e.file });
      const fd = fs.openSync(e.file, fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW);
      try { fs.ftruncateSync(fd, 0); fs.writeFileSync(fd, read(original.backup)); fs.fchmodSync(fd, parseInt(original.before.mode, 8) & 0o777); fs.fsyncSync(fd); }
      finally { fs.closeSync(fd); }
      e.state = 'restored'; this.save('rollback-edit', { file: e.file });
    }
    same(this.j.protectedBefore);
    same(Object.fromEntries(Object.entries(this.j.inventory).filter(([f]) => !edits.some(n => f === `${this.D}/${n}`))));
    for (const e of this.j.edits) assert.equal(sha(read(e.file)), this.j.originals[e.file].before.sha256);
    this.tx.release();
    try { this.tx.gate({ final: true }); this.j.status = 'rolled-back'; }
    catch (error) { this.j.status = 'rolled-back-git-dirty'; this.j.rollbackGitError = String(error); }
    this.save(this.j.status);
  }
}

// No Transaction, journal, engine import or mutation is reachable through this entry.
export function preflightMigration(config) {
  try {
    const migration = new Migration({ ...config, mode: config?.mode ?? 'execute' });
    // Disable optional Git writes and executable fsmonitor configuration. Do not
    // inherit GIT_DIR/INDEX_FILE/config injection from the caller's environment.
    const readEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('GIT_')));
    Object.assign(readEnv, { GIT_OPTIONAL_LOCKS: '0', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' });
    const gitArgs = ['-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-c', 'diff.autoRefreshIndex=false'];
    const gitOptions = root => ({ cwd: root, env: readEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    const readGit = (root, ...args) => {
      if (args[0] === 'status') {
        // Status may otherwise execute clean/process filters while hashing files.
        const filters = spawnSync('git', [...gitArgs, 'config', '--includes', '--get-regexp', '^filter\\..*\\.(clean|process)$'], gitOptions(root));
        assert([0, 1].includes(filters.status) && !filters.stderr, 'cannot inspect Git filters');
        assert(!filters.stdout.trim(), 'external Git clean/process filters block read-only preflight');
      }
      return execFileSync('git', [...gitArgs, ...args], gitOptions(root));
    };
    // Node 24 can expose its process comm as MainThread on Linux.
    const initial = migration.preflight(readGit, /^(node|nodejs|MainThread|pwsh|powershell)$/);
    const { D, C } = migration;
    const profile = JSON.parse(read(`${D}/profiles/chopp-delivery/profile.json`));
    const origin = readGit(C, 'config', '--local', '--no-includes', '--get', 'remote.origin.url').trim();
    const repository = /^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([\w.-]+\/[\w.-]+?)(?:\.git)?\/?$/.exec(origin);
    assert(repository && profile.discovery?.githubRepository &&
      repository[1].toLowerCase() === profile.discovery.githubRepository.toLowerCase(), 'exclusive Git origin mismatch');
    for (const marker of profile.discovery.markers ?? []) {
      assert(!path.isAbsolute(marker) && !marker.split('/').includes('..'), 'unsafe project marker');
      const file = path.join(C, marker); safe(file); assert(exists(file), `missing project marker: ${marker}`);
    }
    assert.equal(initial.legacy.lockfileVersion, '1.0.0', 'incompatible legacy lock version');
    assert.deepEqual(Object.keys(initial.legacy.skills).sort(), profile.skills.toSorted(), 'unexpected legacy Skills');
    for (const skill of profile.skills) {
      assert.equal(initial.legacy.skills[skill].version, '1.0.0', 'incompatible legacy Skill version');
      assert.deepEqual(Object.keys(initial.legacy.skills[skill].files), ['SKILL.md'], 'unexpected legacy Skill files');
    }
    for (const section of ['hooks', 'instructions', 'rules', 'agents', 'configs', 'overlays']) {
      assert.deepEqual(profile[section] ?? [], [], `unexpected profile resource: ${section}`);
      assert.deepEqual(initial.legacy[section] ?? {}, {}, `unexpected legacy resource: ${section}`);
    }
    assert.equal(fs.statSync(path.dirname(initial.flat)).dev, fs.statSync(`${C}/agent-devkit.lock`).dev,
      'cross-filesystem migration would prevent no-overwrite renames');
    safe('/etc/machine-id');
    assert(/^[a-f0-9]{32}$/i.test(read('/etc/machine-id').toString('utf8').trim()), 'valid Linux machine-id required');
    const archiveRoot = `${D}/state/chopp-delivery/migration-backups`;
    let journals = 0;
    for (const file of Object.keys(config.archiveInventory ?? {})) {
      if (path.basename(file) !== 'journal.json' || path.dirname(path.dirname(file)) !== archiveRoot) continue;
      const journal = JSON.parse(read(file)); journals++;
      assert(['rolled-back', 'completed'].includes(journal.status), `unsettled migration journal: ${file}`);
      for (const guard of journal.guards ?? []) assert(!exists(guard.file), `previous journal guard still exists: ${guard.file}`);
      const guardsFile = path.join(path.dirname(file), 'guards.json');
      if (exists(guardsFile)) {
        const guards = JSON.parse(read(guardsFile));
        assert.equal(guards.id, journal.id, 'archive journal identity mismatch');
        assert(guards.guards.every(g => g.state === 'released' && !exists(g.file)), 'unsettled archive guards');
      }
    }
    return { status: 'preflight-passed', readOnly: true, devkitRoot: D, projectDir: C,
      protectedFiles: Object.keys(initial.protectedBefore).length, skills: initial.skills.length,
      archiveFiles: Object.keys(config.archiveInventory ?? {}).length, journals };
  } catch (error) {
    return { status: 'preflight-blocked', readOnly: true, error: String(error.message ?? error) };
  }
}

export const runMigration = async config => new Migration(config).run();
export function recoverMigration(base, { mode = 'scratch' } = {}) {
  assert(path.isAbsolute(base));
  if (mode === 'scratch') assert(base.startsWith('/tmp/'));
  else { assert.equal(mode, 'execute'); assert(base.startsWith('/home/zzzzz/dev/agent-devkit/state/chopp-delivery/migration-backups/')); }
  safe(base);
  const file = path.join(base, 'journal.json');
  assert.equal(fs.lstatSync(file).mode & 0o777, 0o600);
  const journal = JSON.parse(read(file)); assert.equal(journal.config.mode, mode, 'recovery scope mismatch');
  const migration = new Migration(journal.config, journal);
  try {
    migration.rollback(); return { status: migration.j.status, base };
  } catch (error) {
    migration.j.status = 'rollback-conflict'; migration.j.rollbackError = String(error.stack ?? error); migration.save('rollback-conflict');
    return { status: migration.j.status, base, rollbackError: migration.j.rollbackError };
  } finally { migration.tx.dispose(); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [mode, file, ...extra] = process.argv.slice(2); assert.equal(extra.length, 0);
    assert(['--preflight', '--scratch', '--recover-scratch', '--execute', '--recover'].includes(mode) && file,
      'usage: node scripts/migrate-2db.mjs --preflight CONFIG.json | --scratch CONFIG.json | --recover-scratch BASE; --execute/--recover require separate real-execution authorization');
    const result = mode === '--preflight' ? preflightMigration(JSON.parse(read(file))) : mode === '--scratch' || mode === '--execute'
      ? await runMigration({ ...JSON.parse(read(file)), mode: mode === '--scratch' ? 'scratch' : 'execute' })
      : recoverMigration(file, { mode: mode === '--recover-scratch' ? 'scratch' : 'execute' });
    console.log(JSON.stringify(result, null, 2));
    const recovery = mode === '--recover-scratch' || mode === '--recover';
    process.exitCode = result.status === (mode === '--preflight' ? 'preflight-passed' : recovery ? 'rolled-back' : 'completed') ? 0 : 1;
  } catch (error) {
    if (process.argv[2] === '--preflight') console.log(JSON.stringify({ status: 'preflight-blocked', readOnly: true, error: String(error.message ?? error) }, null, 2));
    else console.error(String(error.stack ?? error));
    process.exitCode = 1;
  }
}
