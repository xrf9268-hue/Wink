// Non-vacuity policy for the OSV dependency gate (issue #441).
//
// `osv-scanner` reports "0 vulnerabilities" both when a dependency is clean and
// when it extracted nothing at all — a renamed lockfile, an extractor that lost
// Swift support, or a scan pointed at the wrong directory all produce a green
// run that proves nothing. The scanner's own exit code 128 covers only the
// total-zero case, and the upstream reusable workflows run the scanner under
// `continue-on-error: true`, so that code never fails the job.
//
// This module therefore decides pass/fail from the JSON report itself: every
// package SwiftPM resolved must appear in the scan output before a clean result
// is allowed to mean anything.

export const SUPPRESSION_ID_PATTERN = /^(?:GHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}|CVE-\d{4}-\d{4,}|OSV-\d{4}-\d+)$/;
// osv-scanner's own schema has no owner field and does not require a reason, so
// accountability is encoded in `reason` and enforced here instead.
export const SUPPRESSION_REASON_PATTERN = /^owner:@[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\s+—\s+\S(?:.|\n)*$/;
const MINIMUM_REASON_LENGTH = 24;

// Mirrors osv-scalibr's `normalizeSwiftURL`: the extractor keys a SwiftPM pin by
// its location with the scheme and any `.git` suffix removed.
export function normalizeSwiftLocation(location) {
  return location
    .replace(/^https?:\/\//, '')
    .replace(/\.git$/, '')
    .replace(/\/+$/, '');
}

export function expectedPackagesFromPackageResolved(packageResolved) {
  const pins = Array.isArray(packageResolved?.pins) ? packageResolved.pins : [];

  return pins.map((pin) => ({
    name: pin.location ? normalizeSwiftLocation(pin.location) : pin.identity,
    version: pin.state?.version ?? null,
    ecosystem: 'SwiftURL',
  }));
}

export function collectScannedPackages(report) {
  const packages = [];

  for (const result of report?.results ?? []) {
    for (const entry of result.packages ?? []) {
      packages.push({
        name: entry.package?.name,
        version: entry.package?.version,
        ecosystem: entry.package?.ecosystem,
        source: result.source?.path,
        vulnerabilities: (entry.vulnerabilities ?? []).map((vulnerability) => ({
          id: vulnerability.id,
          aliases: vulnerability.aliases ?? [],
          summary: vulnerability.summary ?? '',
        })),
      });
    }
  }

  return packages;
}

function suppressionMatches(suppression, vulnerability) {
  return (
    suppression.id === vulnerability.id ||
    vulnerability.aliases.includes(suppression.id)
  );
}

export function evaluateSuppressions(suppressions, { now }) {
  const findings = [];

  for (const suppression of suppressions) {
    const label = suppression.id || `entry ${suppression.index + 1}`;

    if (!suppression.id || !SUPPRESSION_ID_PATTERN.test(suppression.id)) {
      findings.push({
        code: 'invalid-suppression',
        message: `Suppression ${label} needs an \`id\` that is a GHSA, CVE, or OSV identifier.`,
      });
      continue;
    }

    if (!suppression.reason || !SUPPRESSION_REASON_PATTERN.test(suppression.reason)) {
      findings.push({
        code: 'invalid-suppression',
        message: `Suppression ${label} needs \`reason = "owner:@handle — why this is accepted"\`; osv-scanner records no accountable owner on its own.`,
      });
      continue;
    }

    if (suppression.reason.replace(/^owner:@\S+\s+—\s+/, '').trim().length < MINIMUM_REASON_LENGTH) {
      findings.push({
        code: 'invalid-suppression',
        message: `Suppression ${label} needs a technical reason of at least ${MINIMUM_REASON_LENGTH} characters after the owner, not a placeholder.`,
      });
      continue;
    }

    if (!suppression.ignoreUntil) {
      findings.push({
        code: 'invalid-suppression',
        message: `Suppression ${label} needs an \`ignoreUntil\` review date; omitting it suppresses the advisory forever.`,
      });
      continue;
    }

    const expiry = Date.parse(`${suppression.ignoreUntil}T00:00:00Z`);
    if (Number.isNaN(expiry)) {
      findings.push({
        code: 'invalid-suppression',
        message: `Suppression ${label} has an unparseable \`ignoreUntil\` (${suppression.ignoreUntil}); use a bare TOML date such as 2026-09-01.`,
      });
      continue;
    }

    if (expiry <= now) {
      findings.push({
        code: 'expired-suppression',
        message: `Suppression ${label} expired on ${suppression.ignoreUntil}; re-triage the advisory or extend the review date deliberately.`,
      });
    }
  }

  return findings;
}

export function evaluateScanReport({
  report,
  expectedPackages = [],
  suppressions = [],
  now = Date.now(),
}) {
  const findings = [];
  const scanned = collectScannedPackages(report);

  findings.push(...evaluateSuppressions(suppressions, { now }));

  const active = new Set(
    suppressions
      .filter((suppression) => suppression.id)
      .map((suppression) => suppression.id),
  );
  const expired = new Set(
    findings
      .filter((finding) => finding.code === 'expired-suppression' || finding.code === 'invalid-suppression')
      .map((finding) => finding.message.match(/Suppression (\S+)/)?.[1]),
  );

  if (scanned.length === 0) {
    findings.push({
      code: 'no-packages-extracted',
      message:
        'The scanner extracted zero packages, so a clean result proves nothing. Check that the lockfile path is right and that the Swift extractor is still enabled.',
    });
  }

  for (const expectedPackage of expectedPackages) {
    const match = scanned.find(
      (entry) => entry.name === expectedPackage.name && entry.ecosystem === expectedPackage.ecosystem,
    );

    if (!match) {
      findings.push({
        code: 'expected-package-missing',
        message: `\`${expectedPackage.name}\` (${expectedPackage.ecosystem}) is pinned in Package.resolved but absent from the scan output; the gate is not actually covering it.`,
      });
      continue;
    }

    if (expectedPackage.version && match.version !== expectedPackage.version) {
      findings.push({
        code: 'expected-package-version-mismatch',
        message: `\`${expectedPackage.name}\` is pinned at ${expectedPackage.version} but the scanner read ${match.version}; the scan did not run against this checkout.`,
      });
    }
  }

  for (const entry of scanned) {
    for (const vulnerability of entry.vulnerabilities) {
      const suppression = suppressions.find(
        (candidate) => active.has(candidate.id) && suppressionMatches(candidate, vulnerability),
      );

      if (suppression && !expired.has(suppression.id)) {
        continue;
      }

      findings.push({
        code: 'unsuppressed-vulnerability',
        message: `${vulnerability.id} affects ${entry.name}@${entry.version} (${entry.ecosystem})${
          vulnerability.summary ? `: ${vulnerability.summary}` : ''
        }`,
      });
    }
  }

  return {
    ok: findings.length === 0,
    findings,
    scanned,
  };
}

// A narrow reader for the only osv-scanner.toml shape this repository allows.
// Node ships no TOML parser and the repository has no package.json, so anything
// outside `[[IgnoredVulns]]` with these three keys is rejected rather than
// silently ignored.
export function parseSuppressions(tomlText) {
  const suppressions = [];
  const findings = [];
  let current = null;
  let index = 0;

  const lines = (tomlText ?? '').split(/\r?\n/);

  lines.forEach((rawLine, lineIndex) => {
    const line = rawLine.replace(/\s+#.*$/, '').trim();
    if (line === '' || line.startsWith('#')) {
      return;
    }

    if (line === '[[IgnoredVulns]]') {
      current = { index: index++, line: lineIndex + 1 };
      suppressions.push(current);
      return;
    }

    if (line.startsWith('[')) {
      findings.push({
        code: 'unsupported-config-section',
        message: `\`${line}\` is not part of Wink's allowed osv-scanner.toml schema (line ${lineIndex + 1}); only \`[[IgnoredVulns]]\` is permitted.`,
      });
      current = null;
      return;
    }

    const match = /^([A-Za-z]+)\s*=\s*(.+)$/.exec(line);
    if (!match || !current) {
      findings.push({
        code: 'unsupported-config-key',
        message: `Cannot read line ${lineIndex + 1} of osv-scanner.toml: \`${rawLine.trim()}\`.`,
      });
      return;
    }

    const [, key, rawValue] = match;
    const value = rawValue.replace(/^["']|["']$/g, '');

    if (key !== 'id' && key !== 'reason' && key !== 'ignoreUntil') {
      findings.push({
        code: 'unsupported-config-key',
        message: `\`${key}\` (line ${lineIndex + 1}) is not an allowed \`[[IgnoredVulns]]\` key; use id, reason, and ignoreUntil.`,
      });
      return;
    }

    current[key] = value;
  });

  return { suppressions, findings };
}
