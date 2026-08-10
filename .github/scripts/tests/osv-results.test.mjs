import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

import {
  collectScannedPackages,
  evaluateScanReport,
  evaluateSuppressions,
  expectedPackagesFromPackageResolved,
  normalizeSwiftLocation,
  parseSuppressions,
  stripTomlComment,
} from '../lib/osv-results.mjs';

const repositoryRoot = fileURLToPath(new URL('../../..', import.meta.url));
const assertPath = fileURLToPath(new URL('../assert-osv-scan.mjs', import.meta.url));
const fixtureRoot = fileURLToPath(new URL('./fixtures/osv/', import.meta.url));

// Captured verbatim from `osv-scanner 2.5.0 scan source --lockfile <path>
// --format json --all-packages` so the shape these tests assert on is the shape
// the scanner really emits, not a hand-written guess.
const VULNERABLE_REPORT = JSON.parse(
  await readFile(join(fixtureRoot, 'vulnerable-sparkle-2.9.1.json'), 'utf8'),
);
const CLEAN_REPORT = JSON.parse(await readFile(join(fixtureRoot, 'clean-sparkle-2.9.5.json'), 'utf8'));

const SPARKLE_2_9_5 = [
  { name: 'github.com/sparkle-project/Sparkle', version: '2.9.5', ecosystem: 'SwiftURL' },
];
const NOW = Date.parse('2026-08-10T00:00:00Z');

function codesFor(findings) {
  return [...new Set(findings.map((finding) => finding.code))].sort();
}

test('normalizeSwiftLocation matches the extractor key osv-scalibr emits', () => {
  assert.equal(
    normalizeSwiftLocation('https://github.com/sparkle-project/Sparkle'),
    'github.com/sparkle-project/Sparkle',
  );
  assert.equal(
    normalizeSwiftLocation('http://github.com/sparkle-project/Sparkle.git'),
    'github.com/sparkle-project/Sparkle',
  );
  assert.equal(
    normalizeSwiftLocation('https://github.com/sparkle-project/Sparkle/'),
    'github.com/sparkle-project/Sparkle',
  );
});

test('expectedPackagesFromPackageResolved reads a v3 lockfile', () => {
  const expected = expectedPackagesFromPackageResolved({
    version: 3,
    pins: [
      {
        identity: 'sparkle',
        location: 'https://github.com/sparkle-project/Sparkle',
        state: { version: '2.9.5' },
      },
    ],
  });

  assert.deepEqual(expected, [{ ...SPARKLE_2_9_5[0], revision: null }]);
});

test('expectedPackagesFromPackageResolved yields nothing for a v1 lockfile shape', () => {
  // v1 nests pins under `object.pins`. osv-scalibr decodes only a top-level
  // `pins`, so it would extract nothing; this must surface as "no expectations"
  // and fail the entrypoint rather than silently pass.
  assert.deepEqual(
    expectedPackagesFromPackageResolved({ object: { pins: [{ package: 'Sparkle' }] } }),
    [],
  );
});

test('collectScannedPackages reads the real scanner report shape', () => {
  const scanned = collectScannedPackages(VULNERABLE_REPORT);

  assert.equal(scanned.length, 1);
  assert.equal(scanned[0].name, 'github.com/sparkle-project/Sparkle');
  assert.equal(scanned[0].version, '2.9.1');
  assert.equal(scanned[0].ecosystem, 'SwiftURL');
  assert.deepEqual(
    scanned[0].vulnerabilities.map((vulnerability) => vulnerability.id).sort(),
    ['GHSA-g3hp-f6mg-559v', 'GHSA-hg88-v3cw-3qrh'],
  );
});

test('a clean scan of every pinned package passes', () => {
  const result = evaluateScanReport({
    report: CLEAN_REPORT,
    expectedPackages: SPARKLE_2_9_5,
    now: NOW,
  });

  assert.deepEqual(result.findings, []);
  assert.equal(result.ok, true);
});

test('a real advisory fails the gate', () => {
  const result = evaluateScanReport({
    report: VULNERABLE_REPORT,
    expectedPackages: [{ ...SPARKLE_2_9_5[0], version: '2.9.1' }],
    now: NOW,
  });

  assert.deepEqual(codesFor(result.findings), ['unsuppressed-vulnerability']);
  assert.equal(result.findings.length, 2);
});

test('zero extracted packages fails even though zero vulnerabilities were reported', () => {
  const result = evaluateScanReport({
    report: { results: [] },
    expectedPackages: SPARKLE_2_9_5,
    now: NOW,
  });

  assert.deepEqual(codesFor(result.findings), ['expected-package-missing', 'no-packages-extracted']);
});

test('a pinned package missing from the scan output fails', () => {
  const result = evaluateScanReport({
    report: CLEAN_REPORT,
    expectedPackages: [
      ...SPARKLE_2_9_5,
      { name: 'github.com/apple/swift-nio', version: '2.99.0', ecosystem: 'SwiftURL' },
    ],
    now: NOW,
  });

  assert.deepEqual(codesFor(result.findings), ['expected-package-missing']);
});

test('a scan of a different revision than the checkout fails', () => {
  const result = evaluateScanReport({
    report: CLEAN_REPORT,
    expectedPackages: [{ ...SPARKLE_2_9_5[0], version: '2.9.1' }],
    now: NOW,
  });

  assert.deepEqual(codesFor(result.findings), ['expected-package-version-mismatch']);
});

test('a valid, unexpired suppression silences its advisory', () => {
  const result = evaluateScanReport({
    report: VULNERABLE_REPORT,
    expectedPackages: [{ ...SPARKLE_2_9_5[0], version: '2.9.1' }],
    suppressions: [
      {
        index: 0,
        id: 'GHSA-g3hp-f6mg-559v',
        reason: 'owner:@xrf9268-hue — local-only metadata spoofing, tracked in #447 and fixed by 2.9.2',
        ignoreUntil: '2026-12-01',
      },
    ],
    now: NOW,
  });

  assert.deepEqual(codesFor(result.findings), ['unsuppressed-vulnerability']);
  assert.equal(result.findings.length, 1, 'only the unsuppressed advisory remains');
});

test('a suppression may reference an advisory by its CVE alias', () => {
  const result = evaluateScanReport({
    report: VULNERABLE_REPORT,
    expectedPackages: [{ ...SPARKLE_2_9_5[0], version: '2.9.1' }],
    suppressions: [
      {
        index: 0,
        id: 'CVE-2026-47122',
        reason: 'owner:@xrf9268-hue — referenced by alias rather than GHSA identifier on purpose',
        ignoreUntil: '2026-12-01',
      },
    ],
    now: NOW,
  });

  assert.equal(result.findings.filter((finding) => finding.code === 'unsuppressed-vulnerability').length, 1);
});

test('an expired suppression fails and stops silencing its advisory', () => {
  const result = evaluateScanReport({
    report: VULNERABLE_REPORT,
    expectedPackages: [{ ...SPARKLE_2_9_5[0], version: '2.9.1' }],
    suppressions: [
      {
        index: 0,
        id: 'GHSA-g3hp-f6mg-559v',
        reason: 'owner:@xrf9268-hue — accepted while the upstream fix was unreleased, now overdue',
        ignoreUntil: '2026-08-09',
      },
    ],
    now: NOW,
  });

  assert.ok(codesFor(result.findings).includes('expired-suppression'));
  assert.equal(
    result.findings.filter((finding) => finding.code === 'unsuppressed-vulnerability').length,
    2,
    'an expired suppression must not keep hiding its advisory',
  );
});

test('evaluateSuppressions rejects every malformed shape', () => {
  const cases = [
    [{ index: 0, id: 'not-an-id', reason: 'owner:@a — x'.padEnd(40, 'y'), ignoreUntil: '2026-12-01' }],
    [{ index: 0, id: 'GHSA-g3hp-f6mg-559v', ignoreUntil: '2026-12-01' }],
    [{ index: 0, id: 'GHSA-g3hp-f6mg-559v', reason: 'because', ignoreUntil: '2026-12-01' }],
    [{ index: 0, id: 'GHSA-g3hp-f6mg-559v', reason: 'owner:@xrf9268-hue — short', ignoreUntil: '2026-12-01' }],
    [
      {
        index: 0,
        id: 'GHSA-g3hp-f6mg-559v',
        reason: 'owner:@xrf9268-hue — no review date was ever recorded here',
      },
    ],
    [
      {
        index: 0,
        id: 'GHSA-g3hp-f6mg-559v',
        reason: 'owner:@xrf9268-hue — the review date cannot be parsed at all',
        ignoreUntil: 'someday',
      },
    ],
  ];

  for (const suppressions of cases) {
    const findings = evaluateSuppressions(suppressions, { now: NOW });
    assert.deepEqual(
      codesFor(findings),
      ['invalid-suppression'],
      `expected ${JSON.stringify(suppressions[0])} to be rejected`,
    );
  }
});

test('parseSuppressions reads the allowed schema and rejects everything else', () => {
  const { suppressions, findings } = parseSuppressions(
    [
      '# Wink allows exactly one section shape.',
      '[[IgnoredVulns]]',
      'id = "GHSA-g3hp-f6mg-559v"',
      'ignoreUntil = 2026-12-01',
      'reason = "owner:@xrf9268-hue — accepted for now, tracked in #447"',
    ].join('\n'),
  );

  assert.deepEqual(findings, []);
  assert.equal(suppressions.length, 1);
  assert.equal(suppressions[0].id, 'GHSA-g3hp-f6mg-559v');
  assert.equal(suppressions[0].ignoreUntil, '2026-12-01');

  assert.deepEqual(codesFor(parseSuppressions('[[PackageOverrides]]\nname = "x"').findings), [
    'unsupported-config-key',
    'unsupported-config-section',
  ]);
  assert.deepEqual(
    codesFor(parseSuppressions('[[IgnoredVulns]]\nid = "GHSA-g3hp-f6mg-559v"\nowner = "x"').findings),
    ['unsupported-config-key'],
  );
});

test('parseSuppressions treats an absent config as no suppressions', () => {
  assert.deepEqual(parseSuppressions(null), { suppressions: [], findings: [] });
  assert.deepEqual(parseSuppressions(''), { suppressions: [], findings: [] });
});

function runAssert(env) {
  return spawnSync(process.execPath, [assertPath], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });
}

test('the entrypoint fails on an empty report rather than reading it as clean', () => {
  const result = runAssert({
    OSV_RESULTS_PATH: join(fixtureRoot, 'no-packages.json'),
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /is empty\./);
  assert.match(result.stderr, /proved nothing/);
});

test('the entrypoint fails when the report is missing entirely', () => {
  const result = runAssert({ OSV_RESULTS_PATH: join(fixtureRoot, 'does-not-exist.json') });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /did not produce output/);
});

test('the negative-proof mode fails when the fixture reports nothing', () => {
  const result = runAssert({
    OSV_RESULTS_PATH: join(fixtureRoot, 'clean-sparkle-2.9.5.json'),
    OSV_EXPECT_VULNERABILITIES: 'true',
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /would not catch a real one/);
});

test('the negative-proof mode passes when the fixture reports advisories', () => {
  const result = runAssert({
    OSV_RESULTS_PATH: join(fixtureRoot, 'known-advisory-swift-nio.json'),
    OSV_LOCKFILE_PATH: '.github/osv-fixtures/known-advisory/Package.resolved',
    OSV_EXPECT_VULNERABILITIES: 'true',
  });

  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /Negative proof: the gate reported 4 advisory\(ies\)/);
});

test('stripTomlComment keeps a `#` that lives inside a quoted value', () => {
  assert.equal(
    stripTomlComment('reason = "owner:@alice — tracked in #447 because upstream is unreleased"'),
    'reason = "owner:@alice — tracked in #447 because upstream is unreleased"',
  );
  assert.equal(stripTomlComment('id = "GHSA-x" # a real comment'), 'id = "GHSA-x" ');
  assert.equal(stripTomlComment('# whole-line comment'), '');
  assert.equal(stripTomlComment('reason = "escaped \\" quote # still inside"'), 'reason = "escaped \\" quote # still inside"');
});

test('a suppression reason may reference an issue without being truncated', () => {
  const reason = 'owner:@xrf9268-hue — accepted while upstream is unreleased, tracked in #447';
  const { suppressions, findings } = parseSuppressions(
    ['[[IgnoredVulns]]', 'id = "GHSA-g3hp-f6mg-559v"', 'ignoreUntil = 2026-12-01', `reason = "${reason}"`].join('\n'),
  );

  assert.deepEqual(findings, []);
  assert.equal(suppressions[0].reason, reason);
  assert.deepEqual(evaluateSuppressions(suppressions, { now: NOW }), []);
});

test('a pin with no resolved version cannot satisfy the exact-resolution proof', () => {
  const expected = expectedPackagesFromPackageResolved({
    version: 3,
    pins: [
      {
        identity: 'sparkle',
        location: 'https://github.com/sparkle-project/Sparkle',
        state: { revision: '79bc9e872948e47877e76f194cb0c8e0412b0b90', branch: 'main' },
      },
    ],
  });

  assert.equal(expected[0].version, null);
  assert.equal(expected[0].revision, '79bc9e872948e47877e76f194cb0c8e0412b0b90');

  const result = evaluateScanReport({ report: CLEAN_REPORT, expectedPackages: expected, now: NOW });
  assert.deepEqual(codesFor(result.findings), ['unverifiable-pin-resolution']);
});

test('the negative proof fails when it scanned something other than the fixture', () => {
  // Vulnerable Sparkle report while expecting the swift-nio fixture: advisories
  // are present, but not from the package the proof claims to exercise.
  const result = runAssert({
    OSV_RESULTS_PATH: join(fixtureRoot, 'vulnerable-sparkle-2.9.1.json'),
    OSV_LOCKFILE_PATH: '.github/osv-fixtures/known-advisory/Package.resolved',
    OSV_EXPECT_VULNERABILITIES: 'true',
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /expected-package-missing/);
  assert.match(result.stderr, /did not scan what it claims to scan/);
});
