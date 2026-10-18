import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { getMachineIdentity, samePath, checkoutIdentity } from '../src/devkit-engine.mjs';

const hash = data => createHash('sha256').update(data).digest('hex');

test('getMachineIdentity: Linux native read returns valid SHA-256 matching /etc/machine-id', () => {
  const machine = getMachineIdentity({ platform: 'linux' });
  assert.equal(typeof machine, 'string');
  assert.equal(machine.length, 64);
  assert(/^[a-f0-9]{64}$/.test(machine));

  const raw = fs.readFileSync('/etc/machine-id', 'utf8').trim();
  assert.equal(machine, hash(raw));
});

test('getMachineIdentity: Linux reader fails closed on missing or invalid machine-id', () => {
  assert.throws(
    () => getMachineIdentity({ platform: 'linux', linuxReader: () => null }),
    /A valid Linux machine-id is required for checkout state/
  );
  assert.throws(
    () => getMachineIdentity({ platform: 'linux', linuxReader: () => Buffer.from('too-short\n') }),
    /A valid Linux machine-id is required for checkout state/
  );
  assert.throws(
    () => getMachineIdentity({ platform: 'linux', linuxReader: () => Buffer.from('g'.repeat(32)) }),
    /A valid Linux machine-id is required for checkout state/
  );
});

test('getMachineIdentity: Windows 11 simulated registry query produces stable SHA-256 hash', () => {
  const sampleGuid = 'd186c74d-456d-4952-b8df-d29b2bdfad7c';
  const mockRegOutput = `HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n    MachineGuid    REG_SZ    ${sampleGuid}\r\n`;

  const machine = getMachineIdentity({
    platform: 'win32',
    winRegReader: () => mockRegOutput
  });

  assert.equal(typeof machine, 'string');
  assert.equal(machine.length, 64);
  assert(/^[a-f0-9]{64}$/.test(machine));
  assert.equal(machine, hash(sampleGuid));
  // Raw GUID is not exposed in the return value
  assert.notEqual(machine, sampleGuid);
});

test('getMachineIdentity: Windows 11 handles case-insensitivity of MachineGuid', () => {
  const guidLower = 'd186c74d-456d-4952-b8df-d29b2bdfad7c';
  const guidUpper = 'D186C74D-456D-4952-B8DF-D29B2BDFAD7C';

  const hashLower = getMachineIdentity({
    platform: 'win32',
    winRegReader: () => `MachineGuid    REG_SZ    ${guidLower}`
  });
  const hashUpper = getMachineIdentity({
    platform: 'win32',
    winRegReader: () => `MachineGuid    REG_SZ    ${guidUpper}`
  });

  assert.equal(hashLower, hashUpper);
  assert.equal(hashLower, hash(guidLower));
});

test('getMachineIdentity: Windows 11 fails closed on registry errors or malformed GUIDs', () => {
  // Registry query throws
  assert.throws(
    () => getMachineIdentity({
      platform: 'win32',
      winRegReader: () => { throw new Error('Reg access denied'); }
    }),
    /Failed to query Windows MachineGuid for checkout state/
  );

  // Missing MachineGuid line
  assert.throws(
    () => getMachineIdentity({
      platform: 'win32',
      winRegReader: () => 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n'
    }),
    /A valid Windows MachineGuid is required for checkout state/
  );

  // Malformed GUID (not a valid UUID)
  assert.throws(
    () => getMachineIdentity({
      platform: 'win32',
      winRegReader: () => 'MachineGuid    REG_SZ    not-a-valid-guid'
    }),
    /A valid Windows MachineGuid is required for checkout state/
  );
});

test('samePath: strict on Linux and tolerant of drive letters and slashes on Windows', () => {
  // Linux platform
  assert.equal(samePath('/home/user/project', '/home/user/project', 'linux'), true);
  assert.equal(samePath('/home/user/project', '/home/user/Project', 'linux'), false);
  assert.equal(samePath('/home/user/project', '/home/user/other', 'linux'), false);

  // Windows platform
  assert.equal(samePath('C:\\dev\\project', 'c:\\dev\\project', 'win32'), true);
  assert.equal(samePath('C:/dev/project', 'c:\\dev\\project', 'win32'), true);
  assert.equal(samePath('C:\\dev\\project', 'C:\\dev\\other', 'win32'), false);
  assert.equal(samePath('C:\\dev\\project', 'D:\\dev\\project', 'win32'), false);
});

test('checkoutIdentity: Windows 11 simulated checkout produces valid identity', t => {
  const base = fs.mkdtempSync('/tmp/cross-platform-test-');
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));

  execFileSync('git', ['init', '--quiet', base]);
  execFileSync('git', ['-C', base, 'config', '--local', 'remote.origin.url', 'https://github.com/vimanoelkkj/chopp-delivery.git']);
  fs.writeFileSync(path.join(base, 'package.json'), '{}');

  const sampleGuid = 'e2b3c4d5-6f7a-4b5c-8d9e-0f1a2b3c4d5e';
  const mockReg = `MachineGuid    REG_SZ    ${sampleGuid}`;

  const checkout = checkoutIdentity(base, {
    platform: 'win32',
    winRegReader: () => mockReg
  });

  assert.equal(typeof checkout.id, 'string');
  assert.equal(checkout.id.length, 64);
  assert.equal(checkout.identity.version, 1);
  assert.equal(checkout.identity.machine, hash(sampleGuid));
  assert.equal(checkout.identity.origin, 'vimanoelkkj/chopp-delivery');
});

test('.gitattributes: policy enforces LF on code and content files', () => {
  const repoRoot = path.resolve(import.meta.dirname, '..');
  const gitattrPath = path.join(repoRoot, '.gitattributes');
  assert.ok(fs.existsSync(gitattrPath), '.gitattributes must exist at repository root');

  const content = fs.readFileSync(gitattrPath, 'utf8');
  assert.ok(content.includes('*.md text eol=lf'), '.gitattributes must set eol=lf for *.md');
  assert.ok(content.includes('*.json text eol=lf'), '.gitattributes must set eol=lf for *.json');
  assert.ok(content.includes('*.mjs text eol=lf'), '.gitattributes must set eol=lf for *.mjs');
  assert.ok(content.includes('*.ps1 text eol=lf'), '.gitattributes must set eol=lf for *.ps1');

  // Verify Git attributes engine resolution for sample files
  for (const sample of ['core/skills/minimal-diff/SKILL.md', 'package.json', 'bin/agent-devkit.mjs', 'bin/agent-devkit.ps1']) {
    const attr = execFileSync('git', ['-C', repoRoot, 'check-attr', 'eol', sample], { encoding: 'utf8' }).trim();
    assert.ok(attr.endsWith('eol: lf'), `Expected eol: lf for ${sample}, got: ${attr}`);
  }
});

