import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { checkoutIdentity, plan, sync, verify } from '../src/devkit-engine.mjs';

const devkitRoot = path.resolve(import.meta.dirname, '..');
const choppDir = '/home/zzzzz/dev/chopp-delivery';

function runPwsh(cmd) {
  const result = execFileSync('pwsh', ['-NoProfile', '-Command', cmd], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  return result.trim();
}

test('Cross-engine checkout identity: exact byte-for-byte equivalence on Chopp Delivery', () => {
  const nodeCheckout = checkoutIdentity(choppDir);
  const pwshScript = `
    Import-Module "${path.join(devkitRoot, 'src/DevKit.Engine.psm1')}" -Force -DisableNameChecking
    $c = Get-DevKitCheckoutIdentity -ProjectDir "${choppDir}"
    $c | ConvertTo-Json -Depth 5 -Compress
  `;
  const pwshOut = runPwsh(pwshScript);
  const pwshParsed = JSON.parse(pwshOut);

  assert.equal(pwshParsed.Id, nodeCheckout.id);
  assert.equal(pwshParsed.Identity.version, nodeCheckout.identity.version);
  assert.equal(pwshParsed.Identity.machine, nodeCheckout.identity.machine);
  assert.equal(pwshParsed.Identity.projectDir, nodeCheckout.identity.projectDir);
  assert.equal(pwshParsed.Identity.gitDir, nodeCheckout.identity.gitDir);
  assert.equal(pwshParsed.Identity.commonDir, nodeCheckout.identity.commonDir);
  assert.equal(pwshParsed.Identity.project.device, nodeCheckout.identity.project.device);
  assert.equal(pwshParsed.Identity.project.inode, nodeCheckout.identity.project.inode);
  assert.equal(pwshParsed.Identity.git.device, nodeCheckout.identity.git.device);
  assert.equal(pwshParsed.Identity.git.inode, nodeCheckout.identity.git.inode);
  assert.equal(pwshParsed.Identity.origin, nodeCheckout.identity.origin);
});

test('Cross-engine verify: both engines verify Chopp Delivery with 100% equivalence', () => {
  const nodeResult = verify({
    devkitRoot,
    projectDir: choppDir,
    profile: 'chopp-delivery',
    stateScope: 'checkout'
  });
  assert.equal(nodeResult.verified, true);
  assert.equal(nodeResult.state.length, 8);
  assert.ok(nodeResult.state.every(s => s.status === 'synced'));

  const pwshScript = `
    Import-Module "${path.join(devkitRoot, 'src/DevKit.Engine.psm1')}" -Force -DisableNameChecking
    $v = Invoke-DevKitVerify -ProjectDir "${choppDir}" -Profile chopp-delivery -DevKitRoot "${devkitRoot}" -StateScope checkout
    [PSCustomObject]@{
      Verified = $v.Verified
      TotalFiles = $v.TotalFiles
      DiscrepanciesCount = $v.Discrepancies.Count
    } | ConvertTo-Json -Compress
  `;
  const pwshOut = runPwsh(pwshScript);
  const pwshParsed = JSON.parse(pwshOut);

  assert.equal(pwshParsed.Verified, true);
  assert.equal(pwshParsed.TotalFiles, 8);
  assert.equal(pwshParsed.DiscrepanciesCount, 0);
});

test('Cross-engine CLI: both Node and PowerShell CLIs verify Chopp Delivery with exit code 0', () => {
  const nodeCli = execFileSync(process.execPath, [
    path.join(devkitRoot, 'bin/agent-devkit.mjs'),
    'verify',
    '--profile', 'chopp-delivery',
    '--project-dir', choppDir,
    '--state-scope', 'checkout'
  ], { encoding: 'utf8' });
  const nodeParsed = JSON.parse(nodeCli);
  assert.equal(nodeParsed.command, 'verify');
  assert.equal(nodeParsed.verified, true);

  const pwshCli = execFileSync('pwsh', [
    '-NoProfile',
    path.join(devkitRoot, 'bin/agent-devkit.ps1'),
    'verify',
    '-Profile', 'chopp-delivery',
    '-ProjectDir', choppDir,
    '-StateScope', 'checkout'
  ], { encoding: 'utf8' });
  assert.ok(pwshCli.includes('SUCCESS: All managed components are strictly synchronized.'));
});

test('Fail-closed: foreign binding mismatch diagnosis across both engines', t => {
  const sandbox = fs.mkdtempSync('/tmp/cross-engine-fail-');
  t.after(() => fs.rmSync(sandbox, { recursive: true, force: true }));

  execFileSync('git', ['init', '--quiet', sandbox]);
  execFileSync('git', ['-C', sandbox, 'config', '--local', 'remote.origin.url', 'https://github.com/vimanoelkkj/chopp-delivery.git']);
  fs.writeFileSync(path.join(sandbox, 'package.json'), '{}');

  const checkout = checkoutIdentity(sandbox);
  const mockDevKit = path.join(sandbox, 'devkit');
  fs.mkdirSync(mockDevKit, { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'profiles'), path.join(mockDevKit, 'profiles'), { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'core'), path.join(mockDevKit, 'core'), { recursive: true });

  const lockDir = path.join(mockDevKit, 'state/chopp-delivery/checkouts', checkout.id);
  fs.mkdirSync(lockDir, { recursive: true });

  // Foreign lock with wrong machine hash
  const foreignLock = {
    lockfileVersion: '1.0.0',
    generatedAt: new Date().toISOString(),
    profile: 'chopp-delivery@1.0.0',
    skills: {},
    hooks: {},
    instructions: {},
    rules: {},
    agents: {},
    configs: {},
    overlays: {},
    checkoutState: {
      ...checkout.identity,
      machine: '0'.repeat(64),
      profile: 'chopp-delivery'
    }
  };
  fs.writeFileSync(path.join(lockDir, 'agent-devkit.lock'), JSON.stringify(foreignLock, null, 2) + '\n');

  // Node engine fails closed with exact message
  assert.throws(
    () => plan({ devkitRoot: mockDevKit, projectDir: sandbox, profile: 'chopp-delivery', stateScope: 'checkout' }),
    /Checkout state binding mismatch \(foreign, missing or incompatible ownership\)/
  );

  // PowerShell engine fails closed with exact message
  const pwshScript = `
    Import-Module "${path.join(devkitRoot, 'src/DevKit.Engine.psm1')}" -Force -DisableNameChecking
    try {
      Get-DevKitLock -ProjectDir "${sandbox}" -ProfileName "chopp-delivery" -DevKitRoot "${mockDevKit}" -StateScope "checkout"
      Write-Output "DID_NOT_THROW"
    } catch {
      Write-Output "THREW: $($_.Exception.Message)"
    }
  `;
  const pwshResult = runPwsh(pwshScript);
  assert.ok(pwshResult.includes('Checkout state binding mismatch (foreign, missing or incompatible ownership)'));
});

test('Fail-closed: missing checkoutState fails closed across both engines', t => {
  const sandbox = fs.mkdtempSync('/tmp/cross-engine-missing-');
  t.after(() => fs.rmSync(sandbox, { recursive: true, force: true }));

  execFileSync('git', ['init', '--quiet', sandbox]);
  execFileSync('git', ['-C', sandbox, 'config', '--local', 'remote.origin.url', 'https://github.com/vimanoelkkj/chopp-delivery.git']);
  fs.writeFileSync(path.join(sandbox, 'package.json'), '{}');

  const checkout = checkoutIdentity(sandbox);
  const mockDevKit = path.join(sandbox, 'devkit');
  fs.mkdirSync(mockDevKit, { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'profiles'), path.join(mockDevKit, 'profiles'), { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'core'), path.join(mockDevKit, 'core'), { recursive: true });

  const lockDir = path.join(mockDevKit, 'state/chopp-delivery/checkouts', checkout.id);
  fs.mkdirSync(lockDir, { recursive: true });

  // Lock without checkoutState
  const nakedLock = {
    lockfileVersion: '1.0.0',
    generatedAt: new Date().toISOString(),
    profile: 'chopp-delivery@1.0.0',
    skills: {},
    hooks: {},
    instructions: {},
    rules: {},
    agents: {},
    configs: {},
    overlays: {}
  };
  fs.writeFileSync(path.join(lockDir, 'agent-devkit.lock'), JSON.stringify(nakedLock, null, 2) + '\n');

  // Node engine fails closed
  assert.throws(
    () => plan({ devkitRoot: mockDevKit, projectDir: sandbox, profile: 'chopp-delivery', stateScope: 'checkout' }),
    /Checkout state binding mismatch \(foreign, missing or incompatible ownership\)/
  );

  // PowerShell engine fails closed
  const pwshScript = `
    Import-Module "${path.join(devkitRoot, 'src/DevKit.Engine.psm1')}" -Force -DisableNameChecking
    try {
      Get-DevKitLock -ProjectDir "${sandbox}" -ProfileName "chopp-delivery" -DevKitRoot "${mockDevKit}" -StateScope "checkout"
      Write-Output "DID_NOT_THROW"
    } catch {
      Write-Output "THREW: $($_.Exception.Message)"
    }
  `;
  const pwshResult = runPwsh(pwshScript);
  assert.ok(pwshResult.includes('Checkout state binding mismatch (foreign, missing or incompatible ownership)'));
});

test('Fail-closed: legacy scope rejects lock containing checkoutState across both engines', t => {
  const sandbox = fs.mkdtempSync('/tmp/cross-engine-legacy-');
  t.after(() => fs.rmSync(sandbox, { recursive: true, force: true }));

  execFileSync('git', ['init', '--quiet', sandbox]);
  execFileSync('git', ['-C', sandbox, 'config', '--local', 'remote.origin.url', 'https://github.com/vimanoelkkj/chopp-delivery.git']);
  fs.writeFileSync(path.join(sandbox, 'package.json'), '{}');

  const mockDevKit = path.join(sandbox, 'devkit');
  fs.mkdirSync(mockDevKit, { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'profiles'), path.join(mockDevKit, 'profiles'), { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'core'), path.join(mockDevKit, 'core'), { recursive: true });

  const lockDir = path.join(mockDevKit, 'state/chopp-delivery');
  fs.mkdirSync(lockDir, { recursive: true });

  const lockWithCheckoutState = {
    lockfileVersion: '1.0.0',
    generatedAt: new Date().toISOString(),
    profile: 'chopp-delivery@1.0.0',
    skills: {},
    hooks: {},
    instructions: {},
    rules: {},
    agents: {},
    configs: {},
    overlays: {},
    checkoutState: { version: 1 }
  };
  fs.writeFileSync(path.join(lockDir, 'agent-devkit.lock'), JSON.stringify(lockWithCheckoutState, null, 2) + '\n');

  // Node engine rejects
  assert.throws(
    () => plan({ devkitRoot: mockDevKit, projectDir: sandbox, profile: 'chopp-delivery' }),
    /Checkout state binding mismatch \(foreign, missing or incompatible ownership\)/
  );

  // PowerShell engine rejects
  const pwshScript = `
    Import-Module "${path.join(devkitRoot, 'src/DevKit.Engine.psm1')}" -Force -DisableNameChecking
    try {
      Get-DevKitLock -ProjectDir "${sandbox}" -ProfileName "chopp-delivery" -DevKitRoot "${mockDevKit}"
      Write-Output "DID_NOT_THROW"
    } catch {
      Write-Output "THREW: $($_.Exception.Message)"
    }
  `;
  const pwshResult = runPwsh(pwshScript);
  assert.ok(pwshResult.includes('Checkout state binding mismatch (foreign, missing or incompatible ownership)'));
});

test('Sync guard: legacy .agent-devkit-sync guard blocks checkout sync in both engines', t => {
  const sandbox = fs.mkdtempSync('/tmp/cross-engine-guard-');
  t.after(() => fs.rmSync(sandbox, { recursive: true, force: true }));

  execFileSync('git', ['init', '--quiet', sandbox]);
  execFileSync('git', ['-C', sandbox, 'config', '--local', 'remote.origin.url', 'https://github.com/vimanoelkkj/chopp-delivery.git']);
  fs.writeFileSync(path.join(sandbox, 'package.json'), '{}');
  fs.writeFileSync(path.join(sandbox, '.agent-devkit-sync'), '');

  // Node engine fails
  assert.throws(
    () => sync({ devkitRoot, projectDir: sandbox, profile: 'chopp-delivery', stateScope: 'checkout' }),
    /Legacy sync guard exists for this checkout/
  );

  // PowerShell engine fails
  const pwshScript = `
    Import-Module "${path.join(devkitRoot, 'src/DevKit.Engine.psm1')}" -Force -DisableNameChecking
    try {
      Invoke-DevKitSync -ProjectDir "${sandbox}" -Profile "chopp-delivery" -DevKitRoot "${devkitRoot}" -StateScope "checkout"
      Write-Output "DID_NOT_THROW"
    } catch {
      Write-Output "THREW: $($_.Exception.Message)"
    }
  `;
  const pwshResult = runPwsh(pwshScript);
  assert.ok(pwshResult.includes('Legacy sync guard exists for this checkout'));
});

test('Mutual interop: Node sync creates lockfile -> PowerShell verify validates cleanly', t => {
  const sandbox = fs.mkdtempSync('/tmp/cross-engine-node2ps-');
  t.after(() => fs.rmSync(sandbox, { recursive: true, force: true }));

  execFileSync('git', ['init', '--quiet', sandbox]);
  execFileSync('git', ['-C', sandbox, 'config', '--local', 'remote.origin.url', 'https://github.com/vimanoelkkj/chopp-delivery.git']);
  fs.writeFileSync(path.join(sandbox, 'package.json'), '{}');

  const mockDevKit = path.join(sandbox, 'devkit');
  fs.mkdirSync(mockDevKit, { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'profiles'), path.join(mockDevKit, 'profiles'), { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'core'), path.join(mockDevKit, 'core'), { recursive: true });

  const syncResult = sync({
    devkitRoot: mockDevKit,
    projectDir: sandbox,
    profile: 'chopp-delivery',
    stateScope: 'checkout'
  });
  assert.equal(syncResult.blocked, false);
  assert.equal(syncResult.written, 8);

  const pwshScript = `
    Import-Module "${path.join(devkitRoot, 'src/DevKit.Engine.psm1')}" -Force -DisableNameChecking
    $v = Invoke-DevKitVerify -ProjectDir "${sandbox}" -Profile chopp-delivery -DevKitRoot "${mockDevKit}" -StateScope checkout
    [PSCustomObject]@{
      Verified = $v.Verified
      TotalFiles = $v.TotalFiles
      DiscrepanciesCount = $v.Discrepancies.Count
    } | ConvertTo-Json -Compress
  `;
  const pwshOut = runPwsh(pwshScript);
  const pwshParsed = JSON.parse(pwshOut);
  assert.equal(pwshParsed.Verified, true);
  assert.equal(pwshParsed.TotalFiles, 8);
  assert.equal(pwshParsed.DiscrepanciesCount, 0);
});

test('Mutual interop: PowerShell sync creates lockfile -> Node verify validates cleanly', t => {
  const sandbox = fs.mkdtempSync('/tmp/cross-engine-ps2node-');
  t.after(() => fs.rmSync(sandbox, { recursive: true, force: true }));

  execFileSync('git', ['init', '--quiet', sandbox]);
  execFileSync('git', ['-C', sandbox, 'config', '--local', 'remote.origin.url', 'https://github.com/vimanoelkkj/chopp-delivery.git']);
  fs.writeFileSync(path.join(sandbox, 'package.json'), '{}');

  const mockDevKit = path.join(sandbox, 'devkit');
  fs.mkdirSync(mockDevKit, { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'profiles'), path.join(mockDevKit, 'profiles'), { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'core'), path.join(mockDevKit, 'core'), { recursive: true });

  const pwshScript = `
    Import-Module "${path.join(devkitRoot, 'src/DevKit.Engine.psm1')}" -Force -DisableNameChecking
    $s = Invoke-DevKitSync -ProjectDir "${sandbox}" -Profile chopp-delivery -DevKitRoot "${mockDevKit}" -StateScope checkout
    [PSCustomObject]@{
      Blocked = $s.Blocked
      Materialized = $s.Materialized
    } | ConvertTo-Json -Compress
  `;
  const pwshOut = runPwsh(pwshScript);
  const pwshParsed = JSON.parse(pwshOut);
  assert.equal(pwshParsed.Blocked, 0);
  assert.equal(pwshParsed.Materialized, 8);

  const nodeResult = verify({
    devkitRoot: mockDevKit,
    projectDir: sandbox,
    profile: 'chopp-delivery',
    stateScope: 'checkout'
  });
  assert.equal(nodeResult.verified, true);
  assert.equal(nodeResult.state.length, 8);
  assert.ok(nodeResult.state.every(s => s.status === 'synced'));
});

test('Concurrent guard: active checkout sync guard blocks both engines and is preserved on failure', t => {
  const sandbox = fs.mkdtempSync('/tmp/cross-engine-concurrent-');
  t.after(() => fs.rmSync(sandbox, { recursive: true, force: true }));

  execFileSync('git', ['init', '--quiet', sandbox]);
  execFileSync('git', ['-C', sandbox, 'config', '--local', 'remote.origin.url', 'https://github.com/vimanoelkkj/chopp-delivery.git']);
  fs.writeFileSync(path.join(sandbox, 'package.json'), '{}');

  const mockDevKit = path.join(sandbox, 'devkit');
  fs.mkdirSync(mockDevKit, { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'profiles'), path.join(mockDevKit, 'profiles'), { recursive: true });
  fs.cpSync(path.join(devkitRoot, 'core'), path.join(mockDevKit, 'core'), { recursive: true });

  const checkout = checkoutIdentity(sandbox);
  const guardPath = path.join(mockDevKit, `.agent-devkit-checkout-${checkout.id}.sync`);
  // Simulate active concurrent sync guard
  fs.writeFileSync(guardPath, 'active-sync-guard');

  // 1. Node engine attempt must fail
  assert.throws(
    () => sync({ devkitRoot: mockDevKit, projectDir: sandbox, profile: 'chopp-delivery', stateScope: 'checkout' }),
    { code: 'EEXIST' }
  );
  // Guard file must NOT be removed by failed Node process
  assert.equal(fs.existsSync(guardPath), true);

  // 2. PowerShell engine attempt must fail
  const pwshScript = `
    Import-Module "${path.join(devkitRoot, 'src/DevKit.Engine.psm1')}" -Force -DisableNameChecking
    try {
      Invoke-DevKitSync -ProjectDir "${sandbox}" -Profile "chopp-delivery" -DevKitRoot "${mockDevKit}" -StateScope "checkout"
      Write-Output "DID_NOT_THROW"
    } catch {
      Write-Output "THREW: $($_.Exception.GetBaseException().GetType().Name)"
    }
  `;
  const pwshOut = runPwsh(pwshScript);
  assert.ok(pwshOut.includes('THREW: IOException'));

  // Guard file must STILL be intact and NOT deleted by failed PowerShell process
  assert.equal(fs.existsSync(guardPath), true);
  assert.equal(fs.readFileSync(guardPath, 'utf8'), 'active-sync-guard');
});
