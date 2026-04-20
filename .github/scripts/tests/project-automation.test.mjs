import test from 'node:test';
import assert from 'node:assert/strict';

import {
  classifyRuntimeSensitivity,
  computeProjectStatus,
  extractClosingIssueNumbers,
  normalizePullRequestState,
  parseValidationStatus,
  resolveIssueNumbersToEnsure,
  resolveRuntimeValidationOptionName,
} from '../lib/project-automation.mjs';

test('extractClosingIssueNumbers finds closing keywords for local issues', () => {
  const body = `
Fixes #135
Resolves xrf9268-hue/Wink#140

Refs #141
`;

  assert.deepEqual(
    extractClosingIssueNumbers(body, { owner: 'xrf9268-hue', repo: 'Wink' }),
    [135, 140],
  );
});

test('parseValidationStatus returns the checked validation option', () => {
  const body = `
## Validation Status
- [ ] Not runtime-sensitive
- [x] macOS runtime validation pending
- [ ] macOS runtime validation complete
`;

  assert.equal(parseValidationStatus(body), 'pending');
});

test('parseValidationStatus supports legacy free-text runtime validation sections', () => {
  const body = `
## Runtime Validation
- not required for this persistence-only change; no macOS runtime validation was performed
`;

  assert.equal(parseValidationStatus(body), 'not-required');
});

test('classifyRuntimeSensitivity marks capture and packaging paths as runtime-sensitive', () => {
  const classification = classifyRuntimeSensitivity([
    'Sources/Wink/Services/CarbonHotKeyProvider.swift',
    'scripts/package-app.sh',
    'README.md',
  ]);

  assert.equal(classification.runtimeSensitive, true);
  assert.deepEqual(classification.matches, [
    'Sources/Wink/Services/CarbonHotKeyProvider.swift',
    'scripts/package-app.sh',
  ]);
});

test('computeProjectStatus prefers Done for closed issues', () => {
  assert.equal(
    computeProjectStatus({ issueState: 'CLOSED', hasOpenLinkedPullRequest: true }),
    'Done',
  );
});

test('computeProjectStatus returns In Progress for open issues with an open linked PR', () => {
  assert.equal(
    computeProjectStatus({ issueState: 'OPEN', hasOpenLinkedPullRequest: true }),
    'In Progress',
  );
});

test('resolveRuntimeValidationOptionName keeps complete when latest linked PR is complete', () => {
  const optionName = resolveRuntimeValidationOptionName({
    fallbackRuntimeSensitive: true,
    linkedPullRequestValidationStatus: 'complete',
  });

  assert.equal(optionName, 'macOS complete');
});

test('resolveRuntimeValidationOptionName defaults to None for non-runtime-sensitive work', () => {
  const optionName = resolveRuntimeValidationOptionName({
    fallbackRuntimeSensitive: false,
    linkedPullRequestValidationStatus: 'not-required',
  });

  assert.equal(optionName, 'None');
});

test('normalizePullRequestState treats merged pull requests as MERGED even when GraphQL reports CLOSED', () => {
  assert.equal(
    normalizePullRequestState({
      mergedAt: '2026-04-16T02:49:00Z',
      state: 'CLOSED',
    }),
    'MERGED',
  );
});

test('resolveIssueNumbersToEnsure uses repository issues during scheduled reconciliation', () => {
  assert.deepEqual(
    resolveIssueNumbersToEnsure({
      eventIssueNumber: null,
      eventName: 'schedule',
      linkedIssueNumbers: [144],
      repositoryIssueNumbers: [133, 134, 135, 144],
    }),
    [133, 134, 135, 144],
  );
});
