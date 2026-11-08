#!/usr/bin/env node
// Hub contract: everything this repository's workflows call in the private
// components must exist in the assembled workspace. Run from the workspace root.
//
//   node .github/compose/check-hub-contract.mjs              # names and paths only
//   node .github/compose/check-hub-contract.mjs --run-tests  # also run ci.yml's node:test suites
//
// Component CI runs it on every private-repo PR, so removing or renaming a script
// that a deploy-branch workflow uses fails there, not after release (server v1.0.5).
// --run-tests brings ci.yml's dependency-free node:test suites to PR time, such as
// the production migration approval guard (the 0034 incident).
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

const workflowsDir = '.github/workflows';
// Tests come from ci.yml's Application checks job (verify), which needs no services;
// these of its suites need a build or the workerd runtime that PR CI does not set up.
const testsNeedingBuild = new Set(['scripts/google-oauth-workerd.test.mjs', 'scripts/cost-monitor-watchdog.test.mjs', 'scripts/cost-monitor-verify.test.mjs', 'scripts/traffic-report-preview.test.mjs']);
const pnpmBuiltins = new Set(['install', 'i', 'add', 'exec', 'dlx', 'run', 'why', 'store', 'list', 'ls', 'audit']);

// Commands only: comment lines often quote commands that no longer exist.
const commandText = file => readFileSync(`${workflowsDir}/${file}`, 'utf8').split('\n').filter(line => !/^\s*#/.test(line)).join('\n');
// component-*.yml run in the private repos' own CI, which already fails on them.
const workflows = readdirSync(workflowsDir).filter(f => /\.ya?ml$/.test(f) && !f.startsWith('component-')).map(file => ({ file, text: commandText(file) }));
// A step starts at "- key:"; its commands resolve against its working-directory.
const steps = text => text.split(/\n(?=\s*- [\w-]+:)/).map(body => ({ body, dir: body.match(/^\s*working-directory:\s*['"]?([^'"\s]+)/m)?.[1] ?? '.' }));
const scriptsIn = dir => existsSync(join(dir, 'package.json')) ? JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')).scripts ?? {} : {};
const problems = [];

for (const { file, text } of workflows) {
  for (const { body, dir } of steps(text)) {
    if (dir.includes('${{')) continue;
    const scripts = scriptsIn(dir);
    for (const [, name] of body.matchAll(/(?:^|[ \t;&|(])pnpm[ \t]+(?:run[ \t]+)?([a-z][\w:.-]*)/gm)) {
      if (!pnpmBuiltins.has(name) && !Object.hasOwn(scripts, name)) problems.push(`${file}: pnpm ${name} — no such script in ${join(dir, 'package.json')}`);
    }
    for (const [path] of body.matchAll(/(?<![\w/.-])scripts\/[\w./-]+\.(?:mjs|mts|cjs|js|ts|py|sh)\b/g)) {
      if (!existsSync(join(dir, path))) problems.push(`${file}: ${join(dir, path)} — file missing`);
    }
  }
}

if (problems.length) {
  console.error(`hub contract: ${problems.length} broken reference(s) from FindAny/ghfind workflows:`);
  for (const p of [...new Set(problems)]) console.error(`  - ${p}`);
  console.error('Release the hub change that drops these references before releasing the component (docs/runbook.md, "Release order").');
  process.exit(1);
}
console.log(`hub contract: ${workflows.length} workflows, every pnpm script and scripts/ path resolves`);

if (process.argv.includes('--run-tests')) {
  const ci = workflows.find(w => w.file === 'ci.yml').text;
  const verifyJob = ci.match(/\n  verify:\n([\s\S]*?)(?=\n  [a-z][\w-]*:\n|$)/)?.[1];
  if (!verifyJob) throw new Error('hub contract: ci.yml has no verify job');
  const tests = [...new Set([...verifyJob.matchAll(/node --test ([^\n;&|]+)/g)].flatMap(([, list]) => list.trim().split(/\s+/)))].filter(t => !testsNeedingBuild.has(t));
  console.log(`hub contract: running ${tests.length} ci.yml node:test suites`);
  execFileSync(process.execPath, ['--test', ...tests], { stdio: 'inherit' });
}
