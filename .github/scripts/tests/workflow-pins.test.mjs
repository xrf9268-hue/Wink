import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, relative, sep } from 'node:path';
import { spawnSync } from 'node:child_process';

import {
  evaluateConsistency,
  evaluateReference,
  evaluateRepository,
  scanUsesReferences,
  splitValueAndComment,
} from '../lib/workflow-pins.mjs';

const repositoryRoot = fileURLToPath(new URL('../../..', import.meta.url));
const validatorPath = fileURLToPath(new URL('../validate-workflow-pins.mjs', import.meta.url));
const fixtureRoot = fileURLToPath(new URL('./fixtures/workflow-pins/', import.meta.url));

const CHECKOUT_SHA = 'de0fac2e4500dabe0009e67214ff5f5447ce83dd';
const CACHE_SHA = '27d5ce7f107fe9357f9df03efb73ab90386fccae';
const UPLOAD_SHA = '043fb46d1a93c77aae656e7c1c64a875d1fc6a0a';

async function loadFixture(name) {
  const root = join(fixtureRoot, name);
  const entries = await readdir(root, { recursive: true, withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    if (!entry.isFile() || !/\.ya?ml$/.test(entry.name)) {
      continue;
    }

    const absolutePath = join(entry.parentPath ?? entry.path, entry.name);
    files.push({
      path: relative(root, absolutePath).split(sep).join('/'),
      source: await readFile(absolutePath, 'utf8'),
    });
  }

  return files;
}

function codesFor(findings) {
  return [...new Set(findings.map((finding) => finding.code))].sort();
}

function runValidator(root) {
  return spawnSync(process.execPath, [validatorPath], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    env: root === null ? process.env : { ...process.env, WORKFLOW_PINS_ROOT: root },
  });
}

test('splitValueAndComment separates plain values from YAML comments', () => {
  assert.deepEqual(splitValueAndComment(`actions/checkout@${CHECKOUT_SHA} # v6.0.2`), {
    value: `actions/checkout@${CHECKOUT_SHA}`,
    comment: 'v6.0.2',
  });

  assert.deepEqual(splitValueAndComment(`actions/checkout@${CHECKOUT_SHA}`), {
    value: `actions/checkout@${CHECKOUT_SHA}`,
    comment: null,
  });

  assert.deepEqual(splitValueAndComment(`"actions/cache@${CACHE_SHA}" # v5.0.5`), {
    value: `actions/cache@${CACHE_SHA}`,
    comment: 'v5.0.5',
  });

  assert.deepEqual(splitValueAndComment(`actions/checkout@${CHECKOUT_SHA} #`), {
    value: `actions/checkout@${CHECKOUT_SHA}`,
    comment: null,
  });
});

test('splitValueAndComment keeps a `#` that YAML treats as part of the scalar', () => {
  // No whitespace before `#`, so YAML does not start a comment here and the
  // reference is genuinely malformed rather than merely undocumented.
  assert.deepEqual(splitValueAndComment('actions/checkout@main#v4'), {
    value: 'actions/checkout@main#v4',
    comment: null,
  });
});

test('scanUsesReferences ignores block scalars, comments, and lookalike text', async () => {
  const [file] = await loadFixture('noisy');
  const references = scanUsesReferences(file.source);

  assert.deepEqual(
    references.map((reference) => reference.value),
    [`actions/checkout@${CHECKOUT_SHA}`, `actions/upload-artifact@${UPLOAD_SHA}`],
  );
  assert.deepEqual(
    references.map((reference) => reference.comment),
    ['v6.0.2', 'v7.0.1'],
  );
});

test('evaluateReference accepts every immutable reference shape', () => {
  const accepted = [
    { value: `actions/checkout@${CHECKOUT_SHA}`, comment: 'v6.0.2' },
    { value: `example-org/toolkit/setup/node@${CACHE_SHA}`, comment: 'v5.0.5' },
    {
      value: `example-org/shared/.github/workflows/build.yml@${CHECKOUT_SHA}`,
      comment: 'v3.2.1',
    },
    { value: './.github/actions/summarize', comment: null },
    {
      value:
        'docker://ghcr.io/example-org/scanner@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      comment: null,
    },
  ];

  for (const reference of accepted) {
    assert.deepEqual(evaluateReference(reference).problems, [], `expected ${reference.value} to pass`);
  }
});

test('a quoted `uses` mapping key is read as a real reference', () => {
  const references = scanUsesReferences(
    ['jobs:', '  a:', '    steps:', `      - "uses": actions/cache@main`].join('\n'),
  );

  assert.equal(references.length, 1);
  assert.equal(references[0].value, 'actions/cache@main');
  assert.deepEqual(
    evaluateReference(references[0]).problems.map((problem) => problem.code),
    ['mutable-reference', 'missing-version-comment'],
  );
});

test('a `uses` inside a YAML flow mapping fails closed instead of vanishing', () => {
  const references = scanUsesReferences(
    ['jobs:', '  a:', '    steps:', '      - { name: Cache, uses: actions/cache@main }'].join('\n'),
  );

  assert.equal(references.length, 1);
  assert.equal(references[0].flowMapping, true);
  assert.deepEqual(
    evaluateReference(references[0]).problems.map((problem) => problem.code),
    ['flow-mapping-reference'],
  );
});

test('a brace that is not a flow-mapping `uses` key is left alone', () => {
  const references = scanUsesReferences(
    [
      'jobs:',
      '  a:',
      '    steps:',
      '      - name: Interpolated',
      '        if: ${{ github.event_name == "push" }}',
      '        run: echo "{ uses: not/a-reference@v1 }"',
    ].join('\n'),
  );

  assert.deepEqual(references, []);
});

test('a reference hidden in a block scalar is reported, not skipped as opaque text', () => {
  const references = scanUsesReferences(
    ['jobs:', '  a:', '    steps:', '      - uses: >-', '          actions/checkout@main'].join('\n'),
  );

  assert.equal(references.length, 1);
  assert.equal(references[0].blockScalar, true);
  assert.deepEqual(
    evaluateReference(references[0]).problems.map((problem) => problem.code),
    ['block-scalar-reference'],
  );
});

test('evaluateReference classifies references by kind', () => {
  assert.equal(evaluateReference({ value: `actions/checkout@${CHECKOUT_SHA}`, comment: 'v6' }).kind, 'action');
  assert.equal(
    evaluateReference({
      value: `example-org/shared/.github/workflows/build.yml@${CHECKOUT_SHA}`,
      comment: 'v3',
    }).kind,
    'reusable-workflow',
  );
  assert.equal(evaluateReference({ value: './.github/actions/x', comment: null }).kind, 'local');
});

test('evaluateReference rejects every mutable or undocumented reference shape', () => {
  const cases = [
    [{ value: 'actions/checkout@v4', comment: 'v4' }, 'mutable-reference'],
    [{ value: 'actions/checkout@main', comment: 'v6.0.2' }, 'mutable-reference'],
    [{ value: 'actions/cache@27d5ce7f', comment: 'v5.0.5' }, 'mutable-reference'],
    [{ value: `actions/cache@${CACHE_SHA.toUpperCase()}`, comment: 'v5.0.5' }, 'mutable-reference'],
    [
      { value: `example-org/shared/.github/workflows/build.yml@v1`, comment: 'v1' },
      'mutable-reference',
    ],
    [{ value: `actions/upload-artifact@${UPLOAD_SHA}`, comment: null }, 'missing-version-comment'],
    [
      { value: `actions/upload-artifact@${UPLOAD_SHA}`, comment: 'pinned by hand' },
      'invalid-version-comment',
    ],
    [{ value: `actions/upload-artifact@${UPLOAD_SHA}`, comment: 'v7' }, 'invalid-version-comment'],
    // Dependabot skips the comment rewrite when anything follows the version,
    // so the SHA would advance while the comment silently went stale.
    [
      { value: `actions/upload-artifact@${UPLOAD_SHA}`, comment: 'v7.0.1 (do not change)' },
      'invalid-version-comment',
    ],
    [{ value: './.github/actions/summarize@main', comment: null }, 'local-reference-with-ref'],
    [{ value: 'docker://ghcr.io/example-org/scanner:latest', comment: null }, 'mutable-container-image'],
    [{ value: 'totally-bogus', comment: null }, 'unparseable-reference'],
    [{ value: '', comment: null }, 'empty-reference'],
  ];

  for (const [reference, expectedCode] of cases) {
    const codes = evaluateReference(reference).problems.map((problem) => problem.code);
    assert.ok(
      codes.includes(expectedCode),
      `expected ${JSON.stringify(reference.value)} to report ${expectedCode}, got ${codes.join(', ') || 'nothing'}`,
    );
  }
});

test('evaluateConsistency rejects one repository pinned to two commits', () => {
  const findings = evaluateConsistency([
    { kind: 'action', action: 'example-org/artifact', ref: CHECKOUT_SHA, version: 'v7.0.0', path: 'a.yml', line: 1 },
    { kind: 'action', action: 'example-org/artifact', ref: UPLOAD_SHA, version: 'v7.0.1', path: 'b.yml', line: 2 },
  ]);

  assert.deepEqual(codesFor(findings), ['inconsistent-action-pin']);
  assert.equal(findings.length, 2, 'every drifted call site is annotated');
});

test('evaluateConsistency rejects one commit documented as two versions', () => {
  const findings = evaluateConsistency([
    { kind: 'action', action: 'example-org/analysis', ref: CHECKOUT_SHA, version: 'v4.30.0', path: 'a.yml', line: 1 },
    { kind: 'action', action: 'example-org/analysis', ref: CHECKOUT_SHA, version: 'v4.29.0', path: 'a.yml', line: 4 },
  ]);

  assert.deepEqual(codesFor(findings), ['inconsistent-version-comment']);
});

test('evaluateConsistency accepts sub-paths of one repository sharing a commit', () => {
  const findings = evaluateConsistency([
    { kind: 'action', action: 'example-org/analysis', ref: CHECKOUT_SHA, version: 'v4.30.0', path: 'a.yml', line: 1 },
    { kind: 'action', action: 'example-org/analysis', ref: CHECKOUT_SHA, version: 'v4.30.0', path: 'a.yml', line: 4 },
  ]);

  assert.deepEqual(findings, []);
});

test('the compliant fixture passes the whole policy', async () => {
  const result = evaluateRepository(await loadFixture('compliant'));

  assert.deepEqual(result.findings, []);
  assert.equal(result.ok, true);
  assert.equal(result.references.length, 7);
});

test('the violation fixtures fail with every expected policy code', async () => {
  const result = evaluateRepository(await loadFixture('violations'));

  assert.equal(result.ok, false);
  assert.deepEqual(codesFor(result.findings), [
    'block-scalar-reference',
    'flow-mapping-reference',
    'inconsistent-action-pin',
    'inconsistent-version-comment',
    'invalid-version-comment',
    'local-reference-with-ref',
    'missing-version-comment',
    'mutable-container-image',
    'mutable-reference',
    'unparseable-reference',
  ]);
});

test('the noisy fixture reports no findings, proving the scanner has no false positives', async () => {
  const result = evaluateRepository(await loadFixture('noisy'));

  assert.deepEqual(result.findings, []);
  assert.equal(result.references.length, 2);
});

test('a validator that inspected nothing fails instead of reporting success', async () => {
  assert.deepEqual(codesFor(evaluateRepository([]).findings), ['no-workflows-discovered']);
  assert.deepEqual(codesFor(evaluateRepository([], { root: 'custom' }).findings), [
    'no-workflows-discovered',
  ]);

  const result = evaluateRepository(await loadFixture('no-references'));
  assert.deepEqual(codesFor(result.findings), ['no-references-discovered']);
});

test('the validator entrypoint passes on the real repository workflows', () => {
  const result = runValidator(null);

  assert.equal(
    result.status,
    0,
    `validator failed on the real workflows:\n${result.stdout}\n${result.stderr}`,
  );
  assert.match(result.stdout, /Checked \d+ `uses:` reference\(s\)/);
  assert.doesNotMatch(result.stdout, /Checked 0 `uses:` reference\(s\)/);
});

test('the validator entrypoint exits non-zero with annotations on violations', () => {
  const result = runValidator(join(fixtureRoot, 'violations'));

  assert.equal(result.status, 1);
  assert.match(result.stderr, /::error file=.*mutable-references\.yml,line=\d+::/);
  assert.match(result.stdout, /Immutable-reference policy failed with \d+ finding\(s\)\./);
});

test('the validator entrypoint fails on a discovery root with no definitions', async () => {
  const emptyRoot = await mkdtemp(join(tmpdir(), 'wink-workflow-pins-'));
  const result = runValidator(emptyRoot);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /No workflow or action definition files were discovered/);
});

test('CI runs the pin validator and the governance script tests', async () => {
  const ciWorkflow = await readFile(join(repositoryRoot, '.github/workflows/ci.yml'), 'utf8');

  assert.match(ciWorkflow, /node --test \.github\/scripts\/tests\/\*\.test\.mjs/);
  assert.match(ciWorkflow, /node \.github\/scripts\/validate-workflow-pins\.mjs/);
});

test('Dependabot keeps the github-actions ecosystem updated on a weekly cadence', async () => {
  const config = await readFile(join(repositoryRoot, '.github/dependabot.yml'), 'utf8');

  assert.match(config, /^version:\s*2$/m);
  assert.match(config, /package-ecosystem:\s*"github-actions"/);
  assert.match(config, /interval:\s*"weekly"/);
  assert.match(config, /open-pull-requests-limit:\s*\d+/);
});
