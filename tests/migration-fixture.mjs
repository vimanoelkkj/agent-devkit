import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { git, sha } from '../scripts/migration-guards.mjs';
import { fileMeta } from '../scripts/migrate-2db.mjs';
export function makeSeeds(base) {
  const source = process.env.DEVKIT_TEST_SOURCE ?? fileURLToPath(new URL('..', import.meta.url));
  const consumerSource = process.env.DEVKIT_TEST_CONSUMER_SOURCE ?? source;
  const empty = path.join(base, 'empty-template'); fs.mkdirSync(empty);
  const roots = [path.join(base, 'seed-devkit'), path.join(base, 'seed-consumer')];
  for (const [i, root] of roots.entries()) {
    git(base, 'clone', '--no-hardlinks', `--template=${empty}`, i ? consumerSource : source, root);
    fs.mkdirSync(path.join(root, '.git/info'), { recursive: true });
    fs.writeFileSync(path.join(root, '.git/info/exclude'), '.agents/\n.claude/\nagent-devkit.json\nagent-devkit.lock\n');
  }
  git(roots[1], 'remote', 'set-url', 'origin', 'https://github.com/vimanoelkkj/chopp-delivery.git');
  return roots;
}
export function migrationFixture(base, seeds) {
  const dir = fs.mkdtempSync(path.join(base, 'case-'));
  const [D, C] = ['devkit', 'consumer'].map((n, i) => {
    const p = path.join(dir, n); fs.cpSync(seeds[i], p, { recursive: true }); return p;
  });
  const profile = JSON.parse(fs.readFileSync(`${D}/profiles/chopp-delivery/profile.json`));
  const legacy = { lockfileVersion: '1.0.0', generatedAt: '2026-10-17T20:06:23.575Z', profile: 'chopp-delivery@1.0.0',
    skills: {}, ...Object.fromEntries(['hooks', 'instructions', 'rules', 'agents', 'configs', 'overlays'].map(n => [n, {}])) };
  const skills = [];
  for (const n of profile.skills) {
    const bytes = fs.readFileSync(`${D}/core/skills/${n}/SKILL.md`);
    legacy.skills[n] = { source: 'core', version: '1.0.0', files: { 'SKILL.md': { sha256: sha(bytes) } } };
    for (const target of ['.agents/skills', '.claude/skills']) {
      const f = `${C}/${target}/${n}/SKILL.md`; fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, bytes); skills.push(f);
    }
  }
  const bytes = JSON.stringify(legacy, null, 2) + '\n'; fs.mkdirSync(`${D}/state/chopp-delivery`, { recursive: true });
  fs.writeFileSync(`${D}/state/chopp-delivery/agent-devkit.lock`, bytes); fs.writeFileSync(`${C}/agent-devkit.lock`, bytes);
  const { name, version, description, discovery, ...manifest } = profile;
  manifest.profile = 'chopp-delivery'; manifest.targets.skills = ['.agents/skills', '.claude/skills'];
  fs.writeFileSync(`${C}/agent-devkit.json`, JSON.stringify(manifest, null, 2));
  const files = [...skills, ...profile.skills.map(n => `${D}/core/skills/${n}/SKILL.md`), `${D}/profiles/chopp-delivery/profile.json`,
    `${D}/profiles/rp-doces/profile.json`, `${D}/state/chopp-delivery/agent-devkit.lock`, `${C}/agent-devkit.json`, `${C}/agent-devkit.lock`];
  const config = { mode: 'scratch', devkitRoot: D, projectDir: C,
    heads: Object.fromEntries([D, C].map(root => [root, git(root, 'rev-parse', 'HEAD').trim()])),
    branches: Object.fromEntries([D, C].map(root => [root, git(root, 'branch', '--show-current').trim()])),
    inventory: Object.fromEntries(files.map(f => [f, fileMeta(f)])) };
  const configFile = path.join(dir, 'config.json'); fs.writeFileSync(configFile, JSON.stringify(config, null, 2));
  return { dir, D, C, config, configFile, skills };
}
