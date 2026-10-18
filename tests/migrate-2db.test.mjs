import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { runMigration, recoverMigration, fileMeta } from '../scripts/migrate-2db.mjs';
import { git, status, sha } from '../scripts/migration-guards.mjs';
import { makeSeeds, migrationFixture } from './migration-fixture.mjs';
const base = fs.mkdtempSync('/tmp/devkit-runner-tests-'), seeds = makeSeeds(base);
const results = [];
const json = f => JSON.parse(fs.readFileSync(f));
function scenario(name, fn) {
  test(name, async () => {
    const f = migrationFixture(base, seeds);
    try { await fn(f); results.push({ name, passed: true, dir: f.dir }); }
    catch (error) { results.push({ name, passed: false, dir: f.dir, error: String(error.stack) }); throw error; }
    finally { fs.writeFileSync(path.join(base, 'results.json'), JSON.stringify(results, null, 2)); }
  });
}
function restored(f) {
  assert.deepEqual(status(f.D), []); assert.deepEqual(status(f.C), []);
  for (const [p, before] of Object.entries(f.config.inventory)) {
    if (p === `${f.D}/profiles/chopp-delivery/profile.json`) assert.equal(sha(fs.readFileSync(p)), before.sha256);
    else assert.deepEqual(fileMeta(p), before);
  }
}
scenario('integrated-success-preserves-skills-and-orders-final-gate', async f => {
  const result = await runMigration(f.config); assert.equal(result.status, 'completed', JSON.stringify(result));
  assert.deepEqual(status(f.C), []); assert.equal(status(f.D).length, 3);
  for (const p of f.skills) assert.deepEqual(fileMeta(p), f.config.inventory[p]);
  assert(!fs.existsSync(`${f.C}/agent-devkit.json`)); assert(!fs.existsSync(`${f.C}/agent-devkit.lock`));
  const journal = json(`${result.base}/journal.json`), guards = json(`${result.base}/guards.json`);
  assert.equal(json(`${result.base}/verify.json`).verified, true); assert.equal(json(`${result.base}/dry-run.json`).written, 0);
  assert.equal(journal.status, 'completed'); assert(!journal.steps.some(s => s.action === 'all-gates-passed'));
  const steps = guards.steps.map(s => s.action);
  assert(steps.lastIndexOf('guard-released') < steps.indexOf('final-git-gate-passed'));
  assert(guards.guards.every(g => g.state === 'released' && !fs.existsSync(g.file)));
  assert.equal(recoverMigration(result.base).status, 'rolled-back'); restored(f);
});
for (const stage of ['after-consumer-guard', 'after-local-retirement', 'after-seed', 'before-release', 'after-release', 'before-final-gate']) {
  scenario(`integrated-failure-${stage}`, async f => {
    const result = await runMigration({ ...f.config, checkpoint: at => { if (at === stage) throw new Error(`injected ${stage}`); } });
    assert.equal(result.status, 'rolled-back', JSON.stringify(result)); restored(f);
    assert.equal(json(`${result.base}/journal.json`).failure.includes(`injected ${stage}`), true);
  });
}
for (const stage of ['before-intermediate-gate', 'before-final-gate']) {
  scenario(`untracked-at-${stage}-preserved-after-rollback`, async f => {
    const file = `${f.C}/third-party.txt`; let before;
    const result = await runMigration({ ...f.config, checkpoint: at => { if (at === stage) { fs.writeFileSync(file, 'keep'); before = fileMeta(file); } } });
    assert.equal(result.status, 'rolled-back-git-dirty', JSON.stringify(result)); assert.deepEqual(fileMeta(file), before);
    assert.deepEqual(status(f.D), []); assert.deepEqual(status(f.C), ['?? third-party.txt']);
    assert.equal(sha(fs.readFileSync(`${f.C}/agent-devkit.json`)), f.config.inventory[`${f.C}/agent-devkit.json`].sha256);
  });
}
scenario('preexisting-guard-no-migration-no-deletion', async f => {
  const file = `${f.C}/.agent-devkit-sync`; fs.writeFileSync(file, 'preexisting'); const before = fileMeta(file);
  await assert.rejects(runMigration(f.config)); assert.deepEqual(fileMeta(file), before);
  assert.deepEqual(fileMeta(`${f.C}/agent-devkit.lock`), f.config.inventory[`${f.C}/agent-devkit.lock`]);
});
scenario('foreign-guard-during-migration-conflict-preserved', async f => {
  const file = `${f.C}/.agent-devkit-foreign.sync`; let before;
  const result = await runMigration({ ...f.config, checkpoint: at => { if (at === 'before-intermediate-gate') { fs.writeFileSync(file, 'other'); before = fileMeta(file); } } });
  assert.equal(result.status, 'rollback-conflict', JSON.stringify(result)); assert.deepEqual(fileMeta(file), before);
  assert(fs.existsSync(`${f.C}/.agent-devkit-sync`));
});
scenario('altered-own-guard-conflict-no-deletion', async f => {
  const file = `${f.C}/.agent-devkit-sync`; let before;
  const result = await runMigration({ ...f.config, checkpoint: at => { if (at === 'before-intermediate-gate') { fs.writeFileSync(file, 'altered'); before = fileMeta(file); } } });
  assert.equal(result.status, 'rollback-conflict', JSON.stringify(result)); assert.deepEqual(fileMeta(file), before);
});
scenario('release-eacces-rolls-back-without-completed', async f => {
  const result = await runMigration({ ...f.config, releaseOptions: { unlink: () => { throw new Error('EACCES injected'); } } });
  assert.equal(result.status, 'rolled-back', JSON.stringify(result)); restored(f);
  assert(!json(`${result.base}/journal.json`).steps.some(s => s.action === 'completed'));
});
scenario('partial-release-then-failure-reacquires-before-rollback', async f => {
  let calls = 0;
  const result = await runMigration({ ...f.config, releaseOptions: { unlink: p => { if (++calls === 2) throw new Error('EACCES injected'); fs.unlinkSync(p); } } });
  assert.equal(result.status, 'rolled-back', JSON.stringify(result)); restored(f);
});
scenario('crash-window-after-unlink-reconciled-in-rollback', async f => {
  const result = await runMigration({ ...f.config, releaseOptions: { afterUnlink: () => { throw new Error('interrupted release'); } } });
  assert.equal(result.status, 'rolled-back', JSON.stringify(result)); restored(f);
});
scenario('new-writer-after-release-blocks-rollback', async f => {
  const file = `${f.C}/.agent-devkit-sync`; let before;
  const result = await runMigration({ ...f.config, checkpoint: at => { if (at === 'after-release') { fs.writeFileSync(file, 'new writer'); before = fileMeta(file); } } });
  assert.equal(result.status, 'rollback-conflict', JSON.stringify(result)); assert.deepEqual(fileMeta(file), before);
});
scenario('third-party-tracked-edit-preserved', async f => {
  const file = `${f.D}/profiles/chopp-delivery/profile.json`; let before;
  const result = await runMigration({ ...f.config, checkpoint: at => { if (at === 'before-intermediate-gate') { fs.appendFileSync(file, '\nthird-party'); before = fileMeta(file); } } });
  assert.equal(result.status, 'rollback-conflict', JSON.stringify(result)); assert.deepEqual(fileMeta(file), before);
});
for (const stage of ['after-local-retirement', 'after-seed', 'after-release']) {
  scenario(`sigkill-and-durable-recovery-${stage}`, f => {
    const url = new URL('../scripts/migrate-2db.mjs', import.meta.url).href;
    const source = `import fs from 'node:fs';import {runMigration} from ${JSON.stringify(url)};
      const config=JSON.parse(fs.readFileSync(${JSON.stringify(f.configFile)}));
      await runMigration({...config,checkpoint:at=>{if(at===${JSON.stringify(stage)})process.kill(process.pid,'SIGKILL')}});`;
    const child = spawnSync(process.execPath, ['--input-type=module', '-e', source], { encoding: 'utf8', timeout: 60000 });
    assert.equal(child.signal, 'SIGKILL', child.stderr);
    const backups = `${f.D}/state/chopp-delivery/migration-backups`, run = fs.readdirSync(backups)[0];
    const result = recoverMigration(`${backups}/${run}`); assert.equal(result.status, 'rolled-back', JSON.stringify(result)); restored(f);
    assert.equal(recoverMigration(result.base).status, 'rolled-back'); restored(f);
  });
}
scenario('real-paths-rejected-before-any-mutation', async f => {
  await assert.rejects(runMigration({ ...f.config, mode: 'real' }), /scratch/);
  await assert.rejects(runMigration({ ...f.config, projectDir: '/home/zzzzz/dev/chopp-delivery' }), /scratch root/);
  restored(f);
});
scenario('cli-import-and-recovery-entrypoints', async f => {
  const runner = new URL('../scripts/migrate-2db.mjs', import.meta.url).pathname;
  const result = spawnSync(process.execPath, [runner, '--scratch', f.configFile], { encoding: 'utf8', timeout: 60000 });
  assert.equal(result.status, 0, result.stderr); const completed = JSON.parse(result.stdout); assert.equal(completed.status, 'completed');
  const recovery = spawnSync(process.execPath, [runner, '--recover-scratch', completed.base], { encoding: 'utf8' });
  assert.equal(recovery.status, 0, recovery.stderr); assert.equal(JSON.parse(recovery.stdout).status, 'rolled-back'); restored(f);
});
scenario('untracked-devkit-file-rejected-and-preserved', async f => {
  const file = `${f.D}/third-party.txt`; let before;
  const result = await runMigration({ ...f.config, checkpoint: at => { if (at === 'before-intermediate-gate') { fs.writeFileSync(file, 'keep'); before = fileMeta(file); } } });
  assert.equal(result.status, 'rolled-back-git-dirty', JSON.stringify(result)); assert.deepEqual(fileMeta(file), before);
  assert.deepEqual(status(f.D), ['?? third-party.txt']); assert.deepEqual(status(f.C), []);
});
scenario('cli-clean-rollback-is-still-a-failed-migration', f => {
  const runner = new URL('../scripts/migrate-2db.mjs', import.meta.url);
  const source = `import fs from 'node:fs';const unlink=fs.unlinkSync;let first=true;
    fs.unlinkSync=p=>{if(first){first=false;throw new Error('EACCES injected')}return unlink(p)};
    process.argv=[process.execPath,${JSON.stringify(runner.pathname)},'--scratch',${JSON.stringify(f.configFile)}];
    await import(${JSON.stringify(runner.href)});`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', source], { encoding: 'utf8', timeout: 60000 });
  assert.equal(result.status, 1, result.stderr); assert.equal(JSON.parse(result.stdout).status, 'rolled-back'); restored(f);
});
scenario('prior-backups-require-inventory-and-remain-identical', async f => {
  const dir = `${f.D}/state/chopp-delivery/migration-backups/prior-operation`; fs.mkdirSync(dir, { recursive: true });
  const file = `${dir}/journal.json`; fs.writeFileSync(file, '{"status":"rolled-back"}\n'); const before = fileMeta(file);
  await assert.rejects(runMigration(f.config), /approved inventory/); assert.deepEqual(fileMeta(file), before);
  const result = await runMigration({ ...f.config, archiveInventory: { [file]: before } });
  assert.equal(result.status, 'completed', JSON.stringify(result)); assert.deepEqual(fileMeta(file), before);
  assert.equal(recoverMigration(result.base).status, 'rolled-back'); assert.deepEqual(fileMeta(file), before); restored(f);
});
