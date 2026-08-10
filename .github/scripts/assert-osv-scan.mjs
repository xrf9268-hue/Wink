import { readFile } from 'node:fs/promises';

import {
  evaluateScanReport,
  expectedPackagesFromPackageResolved,
  parseSuppressions,
} from './lib/osv-results.mjs';

async function readOptional(path) {
  try {
    return await readFile(path, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') {
      return null;
    }

    throw error;
  }
}

async function main() {
  const resultsPath = process.env.OSV_RESULTS_PATH ?? 'osv-results.json';
  const lockfilePath = process.env.OSV_LOCKFILE_PATH ?? 'Package.resolved';
  const configPath = process.env.OSV_CONFIG_PATH ?? 'osv-scanner.toml';
  // The negative-proof job scans a fixture that is known to be vulnerable; there
  // a clean report is the failure, so the expectation is inverted rather than
  // the gate being skipped.
  const expectVulnerabilities = process.env.OSV_EXPECT_VULNERABILITIES === 'true';

  const rawReport = await readOptional(resultsPath);
  if (rawReport === null) {
    console.error(`::error::No scanner report at ${resultsPath}; the scan step did not produce output.`);
    process.exitCode = 1;
    return;
  }

  // Exit code 128 ("no packages found") writes nothing at all, so an empty file
  // is the vacuous-scan case rather than a corrupt one. Name it precisely: the
  // upstream reusable workflows run the scanner under `continue-on-error`, so
  // this is the only place that outcome can still fail the job.
  if (rawReport.trim() === '') {
    console.error(
      `::error::Scanner report at ${resultsPath} is empty. osv-scanner writes no report when it extracts zero packages, so this run proved nothing.`,
    );
    process.exitCode = 1;
    return;
  }

  let report;
  try {
    report = JSON.parse(rawReport);
  } catch (error) {
    console.error(`::error::Scanner report at ${resultsPath} is not valid JSON: ${error.message}`);
    process.exitCode = 1;
    return;
  }

  const rawLockfile = await readOptional(lockfilePath);
  if (rawLockfile === null) {
    console.error(`::error::No lockfile at ${lockfilePath}; there is nothing to prove coverage against.`);
    process.exitCode = 1;
    return;
  }

  const expectedPackages = expectedPackagesFromPackageResolved(JSON.parse(rawLockfile));
  if (expectedPackages.length === 0) {
    console.error(
      `::error::${lockfilePath} resolved zero packages; a scan of nothing cannot be a passing dependency gate.`,
    );
    process.exitCode = 1;
    return;
  }

  const rawConfig = await readOptional(configPath);
  const { suppressions, findings: configFindings } = parseSuppressions(rawConfig);
  const evaluation = evaluateScanReport({ report, expectedPackages, suppressions });
  const findings = [...configFindings, ...evaluation.findings];

  const summary = [
    `Lockfile: ${lockfilePath} (${expectedPackages.length} pinned package(s))`,
    `Report: ${resultsPath} (${evaluation.scanned.length} extracted package(s))`,
    `Suppressions: ${rawConfig === null ? 'none configured' : `${suppressions.length} in ${configPath}`}`,
    ...evaluation.scanned.map(
      (entry) =>
        `  extracted ${entry.name}@${entry.version} [${entry.ecosystem}] — ${
          entry.vulnerabilities.length
        } advisory(ies)${
          entry.vulnerabilities.length > 0
            ? `: ${entry.vulnerabilities.map((vulnerability) => vulnerability.id).join(', ')}`
            : ''
        }`,
    ),
  ];

  const vulnerabilityFindings = findings.filter(
    (finding) => finding.code === 'unsuppressed-vulnerability',
  );

  if (expectVulnerabilities) {
    console.log(summary.join('\n'));

    if (vulnerabilityFindings.length === 0) {
      console.error(
        '::error::The known-advisory fixture reported no vulnerabilities. The gate would not catch a real one — do not trust a green scan of the production lockfile.',
      );
      process.exitCode = 1;
      return;
    }

    console.log(
      `Negative proof: the gate reported ${vulnerabilityFindings.length} advisory(ies) on the fixture, so it can fail.`,
    );
    return;
  }

  if (findings.length > 0) {
    for (const finding of findings) {
      console.error(`::error::[${finding.code}] ${finding.message}`);
    }

    console.log(summary.join('\n'));
    console.log(`Dependency gate failed with ${findings.length} finding(s).`);
    process.exitCode = 1;
    return;
  }

  console.log(summary.join('\n'));
  console.log('Every pinned package was extracted and carries no unsuppressed advisory.');
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exitCode = 1;
});
