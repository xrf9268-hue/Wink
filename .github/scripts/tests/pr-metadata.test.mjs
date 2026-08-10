import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const validatorPath = fileURLToPath(new URL('../validate-pr-metadata.mjs', import.meta.url));

const COMPLETE_TEMPLATE_BODY = [
  'Fixes #439',
  '',
  '## Validation Status',
  '- [x] Not runtime-sensitive',
  '- [ ] macOS runtime validation pending',
  '- [ ] macOS runtime validation complete',
].join('\n');

const DEPENDABOT_BODY = [
  'Bumps [actions/checkout](https://github.com/actions/checkout) from 6.0.2 to 7.0.1.',
  '',
  'Dependabot will resolve any conflicts with this PR as long as you do not alter it yourself.',
].join('\n');

async function runValidator({ body, files, authorLogin }) {
  const directory = await mkdtemp(join(tmpdir(), 'wink-pr-metadata-'));
  const eventPath = join(directory, 'event.json');

  await writeFile(
    eventPath,
    JSON.stringify({
      pull_request: { number: 1, body, user: { login: authorLogin } },
      repository: { owner: { login: 'xrf9268-hue' }, name: 'Wink' },
    }),
    'utf8',
  );

  return spawnSync(process.execPath, [validatorPath], {
    encoding: 'utf8',
    env: {
      ...process.env,
      GITHUB_EVENT_PATH: eventPath,
      PR_BODY: body,
      PR_FILES: JSON.stringify(files.map((filename) => ({ filename }))),
    },
  });
}

test('a maintainer pull request with the full template passes', async () => {
  const result = await runValidator({
    body: COMPLETE_TEMPLATE_BODY,
    files: ['.github/workflows/ci.yml'],
    authorLogin: 'zjlgdx',
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Linked issues: #439/);
});

test('a maintainer pull request without a closing keyword fails', async () => {
  const result = await runValidator({
    body: COMPLETE_TEMPLATE_BODY.replace('Fixes #439', 'Relates to #439'),
    files: ['.github/workflows/ci.yml'],
    authorLogin: 'zjlgdx',
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /closing keyword/);
});

test('a maintainer pull request cannot call runtime-sensitive changes not runtime-sensitive', async () => {
  const result = await runValidator({
    body: COMPLETE_TEMPLATE_BODY,
    files: ['Sources/Wink/Services/EventTapManager.swift'],
    authorLogin: 'zjlgdx',
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /Runtime-sensitive files changed/);
});

test('a Dependabot action bump passes without an issue link or checklist', async () => {
  const result = await runValidator({
    body: DEPENDABOT_BODY,
    files: ['.github/workflows/ci.yml', '.github/workflows/release.yml'],
    authorLogin: 'dependabot[bot]',
  });

  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /automated dependency update/);
});

test('a Dependabot pull request touching runtime-sensitive files still fails', async () => {
  const result = await runValidator({
    body: DEPENDABOT_BODY,
    files: ['scripts/package-app.sh'],
    authorLogin: 'dependabot[bot]',
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /reopen it as a maintainer pull request/);
});
