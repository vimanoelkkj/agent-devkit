import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { git, sha } from '../scripts/migration-guards.mjs';
import { fileMeta } from '../scripts/migrate-2db.mjs';
import { makeSeeds, migrationFixture } from './migration-fixture.mjs';

const base = fs.mkdtempSync('/tmp/devkit-preflight-tests-'), seeds = makeSeeds(base);
const runner = new URL('../scripts/migrate-2db.mjs', import.meta.url);
const results = [];
function snapshot(root) {
  const out = {};
  function walk(p) {
    const s = fs.lstatSync(p, { bigint: true });
    out[path.relative(root, p)] = { mode: String(s.mode), ino: String(s.ino), dev: String(s.dev), nlink: String(s.nlink),
      mtime: String(s.mtimeNs), ctime: String(s.ctimeNs), size: String(s.size),
      content: s.isFile() ? sha(fs.readFileSync(p)) : s.isSymbolicLink() ? fs.readlinkSync(p) : null };
    if (s.isDirectory()) for (const n of fs.readdirSync(p).sort()) walk(path.join(p, n));
  }
  walk(root); return out;
}
function inspect(f, { cli = true, args = [], environment = {}, invalidJSON = false, invalidMachine = false, crossDevice = false } = {}) {
  fs.writeFileSync(f.configFile, invalidJSON ? '{broken' : JSON.stringify(f.config));
  const before = snapshot(f.dir);
  // This guard is installed before loading the CLI. Any attempted Node fs
  // mutation fails the test even if the preflight catches and reports it.
  const source = `import fs from 'node:fs';
    const config=${invalidJSON ? 'null' : `JSON.parse(fs.readFileSync(${JSON.stringify(f.configFile)}))`};
    const attempts=[];
    ${invalidMachine ? "const read=fs.readFileSync;fs.readFileSync=(p,...args)=>p==='/etc/machine-id'?Buffer.from('invalid'):read(p,...args);" : ''}
    ${crossDevice ? `const stat=fs.statSync;fs.statSync=(p,...args)=>{const s=stat(p,...args);return p===${JSON.stringify(`${f.D}/state/chopp-delivery`)}?{...s,dev:s.dev+1}:s};` : ''}
    const deny=name=>(...args)=>{attempts.push(name);throw new Error('FORBIDDEN_WRITE:'+name)};
    const names=['writeFile','appendFile','mkdir','mkdtemp','unlink','rename','rm','rmdir','copyFile','cp',
      'link','symlink','truncate','ftruncate','chmod','fchmod','chown','fchown','lchown','utimes','futimes','lutimes','write','writev'];
    for(const name of names) {
      if(typeof fs[name]==='function')fs[name]=deny(name);
      if(typeof fs[name+'Sync']==='function')fs[name+'Sync']=deny(name+'Sync');
      if(typeof fs.promises[name]==='function')fs.promises[name]=deny('promises.'+name);
    }
    const open=fs.openSync;
    fs.openSync=(p,flags,...rest)=>{
      const writes=typeof flags==='string'?!['r','rs'].includes(flags):
        !!(flags&(fs.constants.O_WRONLY|fs.constants.O_RDWR|fs.constants.O_CREAT|fs.constants.O_TRUNC|fs.constants.O_APPEND|fs.constants.O_EXCL));
      if(writes)return deny('openSync-write')(p);
      return open(p,flags,...rest);
    };
    fs.open=deny('async-open');fs.promises.open=deny('promises.open');fs.createWriteStream=deny('createWriteStream');
    ${cli ? `process.argv=[process.execPath,${JSON.stringify(runner.pathname)},'--preflight',${JSON.stringify(f.configFile)},...${JSON.stringify(args)}];
      await import(${JSON.stringify(runner.href)});` : `const {preflightMigration}=await import(${JSON.stringify(runner.href)});
      const result=preflightMigration({...config,checkpoint:deny('checkpoint'),releaseOptions:{unlink:deny('release')}});
      process.stdout.write(JSON.stringify(result));process.exitCode=result.status==='preflight-passed'?0:1;`}
    if(attempts.length){process.stderr.write('FORBIDDEN_ATTEMPTS:'+JSON.stringify(attempts));process.exitCode=86;}`;
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', source], { encoding: 'utf8', timeout: 30000,
    env: { ...process.env, NODE_DISABLE_COMPILE_CACHE: '1', ...environment } });
  assert.deepEqual(snapshot(f.dir), before, 'preflight mutated files/directories, including Git metadata');
  assert(!child.stderr.includes('FORBIDDEN_'), child.stderr);
  assert.equal(child.signal, null, child.stderr);
  return child;
}
function scenario(name, mutate = () => {}, { approved = false, ...options } = {}) {
  test(name, async () => {
    const f = migrationFixture(base, seeds);
    let cleanup;
    try {
      cleanup = await mutate(f);
      const child = inspect(f, options);
      assert.equal(child.status, approved ? 0 : 1, child.stderr || child.stdout);
      {
        const result = JSON.parse(child.stdout);
        assert.equal(result.status, approved ? 'preflight-passed' : 'preflight-blocked');
        assert.equal(result.readOnly, true);
        if (approved) { assert.equal(result.skills, 8); assert(result.protectedFiles > 0); }
        else assert(result.error);
      }
      results.push({ name, passed: true, dir: f.dir, writesAttempted: 0, identicalBeforeAfter: true });
    } catch (e) { results.push({ name, passed: false, error: String(e.stack), dir: f.dir }); throw e; }
    finally { await cleanup?.(); fs.writeFileSync(`${base}/results.json`, JSON.stringify(results, null, 2)); }
  });
}
const refresh = (f, file) => { f.config.inventory[file] = fileMeta(file); };
const archive = (f, status) => {
  const dir = `${f.D}/state/chopp-delivery/migration-backups/prior-operation`; fs.mkdirSync(dir, { recursive: true });
  const file = `${dir}/journal.json`; fs.writeFileSync(file, JSON.stringify({ id: 'prior-operation', status }));
  f.config.archiveInventory = { [file]: fileMeta(file) }; return { dir, file };
};

scenario('cli-approved-with-zero-writes', undefined, { approved: true });
scenario('api-approved-with-no-transaction-or-checkpoint', undefined, { approved: true, cli: false });
scenario('wrong-head-blocked-with-zero-writes', f => { f.config.heads[f.D] = '0'.repeat(40); });
scenario('wrong-branch-blocked-with-zero-writes', f => { f.config.branches[f.C] = 'wrong'; });
scenario('api-failure-with-zero-writes', f => { delete f.config.inventory; }, { cli: false });
scenario('unknown-untracked-blocked-with-zero-writes', f => { fs.writeFileSync(`${f.C}/unknown.txt`, 'keep'); });
scenario('staged-change-blocked-with-zero-writes', f => { fs.writeFileSync(`${f.C}/unknown.txt`, 'keep'); git(f.C, 'add', '--', 'unknown.txt'); });
scenario('legacy-guard-preserved', f => { fs.writeFileSync(`${f.C}/.agent-devkit-sync`, 'foreign'); });
scenario('scoped-guard-preserved', f => { fs.writeFileSync(`${f.D}/.agent-devkit-checkout-foreign.sync`, 'foreign'); });
scenario('ignored-guard-still-blocked', f => {
  fs.appendFileSync(`${f.C}/.git/info/exclude`, '.agent-devkit-sync\n'); fs.writeFileSync(`${f.C}/.agent-devkit-sync`, 'foreign');
});
scenario('skill-drift-blocked-with-zero-writes', f => { fs.appendFileSync(f.skills[0], 'drift'); });
scenario('symlink-preserved', f => { fs.unlinkSync(f.skills[0]); fs.symlinkSync(`${f.D}/core/skills/efficient-coding-workflow/SKILL.md`, f.skills[0]); });
scenario('hardlink-preserved', f => { fs.linkSync(f.skills[0], `${f.dir}/hardlink`); });
scenario('different-lock-bytes-blocked', f => {
  fs.appendFileSync(`${f.C}/agent-devkit.lock`, '\n'); refresh(f, `${f.C}/agent-devkit.lock`);
});
scenario('incompatible-legacy-schema-blocked', f => {
  for (const p of [`${f.C}/agent-devkit.lock`, `${f.D}/state/chopp-delivery/agent-devkit.lock`]) {
    const lock = JSON.parse(fs.readFileSync(p)); lock.lockfileVersion = '2.0.0'; fs.writeFileSync(p, JSON.stringify(lock)); refresh(f, p);
  }
});
scenario('wrong-manifest-targets-blocked', f => {
  const file = `${f.C}/agent-devkit.json`, m = JSON.parse(fs.readFileSync(file)); m.targets.skills = ['.agents/skills'];
  fs.writeFileSync(file, JSON.stringify(m)); refresh(f, file);
});
scenario('foreign-origin-blocked', f => { git(f.C, 'remote', 'set-url', 'origin', 'https://github.com/example/foreign.git'); });
scenario('previous-backups-preserved', f => { archive(f, 'rolled-back'); }, { approved: true });
scenario('uninventoried-backup-blocked', f => { archive(f, 'rolled-back'); delete f.config.archiveInventory; });
scenario('backup-inventory-drift-blocked', f => { const a = archive(f, 'rolled-back'); fs.appendFileSync(a.file, '\n'); });
scenario('unsettled-journal-blocked', f => { archive(f, 'rollback-conflict'); });
scenario('unsettled-guard-journal-blocked', f => {
  const a = archive(f, 'rolled-back'), file = `${a.dir}/guards.json`;
  fs.writeFileSync(file, JSON.stringify({ id: 'prior-operation', guards: [{ file: `${f.C}/.agent-devkit-sync`, state: 'held' }] }));
  f.config.archiveInventory[file] = fileMeta(file);
});
scenario('unexpected-active-state-blocked', f => { fs.writeFileSync(`${f.D}/state/unexpected.lock`, 'keep'); });
scenario('invalid-json-blocked-with-zero-writes', undefined, { invalidJSON: true });
scenario('extra-execute-argument-cannot-start-migration', undefined, { args: ['--execute'] });
scenario('fsmonitor-program-never-executed', f => {
  const program = `${f.dir}/monitor.sh`;
  fs.writeFileSync(program, `#!/bin/sh\ntouch '${f.dir}/FS-MONITOR-EXECUTED'\necho token\n`, { mode: 0o755 });
  git(f.C, 'config', '--local', 'core.fsmonitor', program);
}, { approved: true });
scenario('git-environment-cannot-redirect-preflight', undefined, { approved: true,
  environment: { GIT_DIR: '/nonexistent', GIT_INDEX_FILE: '/nonexistent/index', GIT_CONFIG_COUNT: '1',
    GIT_CONFIG_KEY_0: 'core.fsmonitor', GIT_CONFIG_VALUE_0: '/nonexistent/program' } });
scenario('invalid-machine-id-blocked-with-zero-writes', undefined, { invalidMachine: true });
scenario('cross-filesystem-rename-blocked-with-zero-writes', undefined, { crossDevice: true });
scenario('concurrent-writer-blocked-with-zero-writes', async f => {
  const writer = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)', `${f.D}/bin/agent-devkit.mjs`, 'sync'],
    { stdio: 'ignore', env: { ...process.env, NODE_DISABLE_COMPILE_CACHE: '1' } });
  await once(writer, 'spawn');
  const command = spawnSync('ps', ['-p', String(writer.pid), '-o', 'comm='], { encoding: 'utf8' }).stdout.trim();
  assert(['node', 'nodejs', 'MainThread'].includes(command), `unexpected Node process comm: ${command}`);
  return async () => { const exited = once(writer, 'exit'); writer.kill(); await exited; };
});
for (const corruption of ['version', 'files']) scenario(`legacy-skill-${corruption}-blocked-with-zero-writes`, f => {
  for (const p of [`${f.C}/agent-devkit.lock`, `${f.D}/state/chopp-delivery/agent-devkit.lock`]) {
    const lock = JSON.parse(fs.readFileSync(p)), entry = lock.skills['minimal-diff'];
    if (corruption === 'version') entry.version = '0.9.0';
    else entry.files['unexpected.md'] = { sha256: 'a'.repeat(64) };
    fs.writeFileSync(p, JSON.stringify(lock)); refresh(f, p);
  }
});
scenario('external-clean-filter-blocked-before-status-can-execute-it', f => {
  const program = `${f.dir}/filter.sh`;
  fs.writeFileSync(program, `#!/bin/sh\ntouch '${f.dir}/FILTER-EXECUTED'\ncat\n`, { mode: 0o755 });
  fs.writeFileSync(`${f.C}/.git/info/attributes`, 'README.md filter=external\n');
  git(f.C, 'config', '--local', 'filter.external.clean', program);
});
