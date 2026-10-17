#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { profileShow, sync, verify } from '../src/devkit-engine.mjs';

try {
  if (Number(process.versions.node.split('.')[0]) < 24) throw new Error('Node.js 24+ required');
  const args = process.argv.slice(2);
  const devkitRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const command = args.shift();
  if (command === 'profile') {
    if (args.shift() !== 'show' || args.length !== 1) throw new Error('Usage: profile show <name>');
    console.log(JSON.stringify(profileShow(devkitRoot, args[0]), null, 2));
  } else {
    if (!['sync', 'verify'].includes(command)) throw new Error('Supported commands: profile show, sync [--dry-run], verify');
    const options = { devkitRoot, projectDir: process.cwd() };
    const seen = new Set();
    while (args.length) {
      const flag = args.shift();
      if (seen.has(flag)) throw new Error(`Repeated option: ${flag}`);
      seen.add(flag);
      if (flag === '--dry-run' && command === 'sync') options.dryRun = true;
      else {
        const keys = { '--project-dir': 'projectDir', '--profile': 'profile', '--manifest-file': 'manifestFile' };
        const key = Object.hasOwn(keys, flag) ? keys[flag] : undefined;
        if (!key) throw new Error(`Unsupported option: ${flag}`);
        const value = args.shift();
        if (!value || value.startsWith('--')) throw new Error(`Missing value: ${flag}`);
        options[key] = value;
      }
    }
    const result = command === 'sync' ? sync(options) : verify(options);
    console.log(JSON.stringify({ command, dryRun: !!options.dryRun, lockPath: result.lockPath,
      written: result.written, verified: result.verified, blocked: result.blocked,
      lockPresent: result.oldLockBytes !== null,
      state: result.state.map(({ type, target, status, sha256, source }) => ({ type, target, status, sha256, source })) }, null, 2));
    process.exitCode = command === 'verify' ? (result.verified ? 0 : 1) : (result.blocked ? 2 : 0);
  }
} catch (error) {
  console.error(`agent-devkit: ${error.message}`);
  process.exitCode = 1;
}
