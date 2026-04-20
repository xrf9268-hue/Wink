import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

import {
  evaluateReviewState,
  firstLine,
  summarizeBlockingThreads,
} from '../lib/review-state.mjs';

test('evaluateReviewState fails when reviewDecision is CHANGES_REQUESTED', () => {
  const result = evaluateReviewState({
    reviewDecision: 'CHANGES_REQUESTED',
    reviewThreads: [],
  });

  assert.equal(result.ok, false);
  assert.deepEqual(result.reasons, ['changes-requested']);
});

test('evaluateReviewState fails on unresolved non-outdated inline threads', () => {
  const result = evaluateReviewState({
    reviewDecision: 'APPROVED',
    reviewThreads: [
      {
        isResolved: false,
        isOutdated: false,
        path: 'Sources/Wink/AppController.swift',
        line: 88,
        reviewer: 'wink-review-bot',
        bodyText: 'Guard the no-window path before marking activation stable.',
      },
    ],
  });

  assert.equal(result.ok, false);
  assert.deepEqual(result.reasons, ['unresolved-thread']);
  assert.equal(result.blockingThreads.length, 1);
});

test('evaluateReviewState fails when changes requested and actionable threads both exist', () => {
  const result = evaluateReviewState({
    reviewDecision: 'CHANGES_REQUESTED',
    reviewThreads: [
      {
        isResolved: false,
        isOutdated: false,
        path: 'Sources/Wink/AppController.swift',
        line: 88,
        reviewer: 'octocat',
        bodyText: 'Still blocked.',
      },
    ],
  });

  assert.equal(result.ok, false);
  assert.deepEqual(result.reasons, ['changes-requested', 'unresolved-thread']);
});

test('evaluateReviewState ignores outdated unresolved threads', () => {
  const result = evaluateReviewState({
    reviewDecision: 'APPROVED',
    reviewThreads: [
      {
        isResolved: false,
        isOutdated: true,
        path: 'Sources/Wink/AppController.swift',
        line: 88,
        reviewer: 'octocat',
        bodyText: 'Old comment',
      },
    ],
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.reasons, []);
  assert.equal(result.blockingThreads.length, 0);
});

test('evaluateReviewState ignores resolved threads', () => {
  const result = evaluateReviewState({
    reviewDecision: 'APPROVED',
    reviewThreads: [
      {
        isResolved: true,
        isOutdated: false,
        path: 'Sources/Wink/AppController.swift',
        line: 88,
        reviewer: 'octocat',
        bodyText: 'Resolved comment',
      },
    ],
  });

  assert.equal(result.ok, true);
});

test('summarizeBlockingThreads renders file reviewer and first line', () => {
  const summary = summarizeBlockingThreads([
    {
      path: 'Sources/Wink/AppController.swift',
      line: 88,
      reviewer: 'octocat',
      bodyText: 'Guard the no-window path before marking activation stable.\nExtra detail.',
    },
  ]);

  assert.match(summary, /AppController\.swift:88/);
  assert.match(summary, /octocat/);
  assert.match(summary, /Guard the no-window path before marking activation stable\./);
});

test('firstLine trims blank lines and collapses whitespace', () => {
  assert.equal(firstLine('\n  Needs follow-up here.  \n\nSecond line'), 'Needs follow-up here.');
});

test('validate-review-state writes a step summary and exits non-zero for blocking threads', async () => {
  const tempDir = await mkdtemp(join(tmpdir(), 'wink-review-gate-'));
  const eventPath = join(tempDir, 'event.json');
  const summaryPath = join(tempDir, 'summary.md');

  await writeFile(
    eventPath,
    JSON.stringify({
      repository: { owner: { login: 'xrf9268-hue' }, name: 'Wink' },
      pull_request: { number: 999, body: '' },
    }),
  );

  const result = spawnSync('node', ['.github/scripts/validate-review-state.mjs'], {
    cwd: process.cwd(),
    encoding: 'utf8',
    env: {
      ...process.env,
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_STEP_SUMMARY: summaryPath,
      PR_REVIEW_STATE: JSON.stringify({
        reviewDecision: 'APPROVED',
        reviewThreads: [
          {
            isResolved: false,
            isOutdated: false,
            path: 'Sources/Wink/AppController.swift',
            line: 88,
            reviewer: 'wink-review-bot',
            bodyText: 'Guard the no-window path before marking activation stable.',
          },
        ],
      }),
    },
  });

  assert.equal(result.status, 1);
  assert.match(await readFile(summaryPath, 'utf8'), /AppController\.swift:88/);
  assert.match(result.stderr, /unresolved actionable review feedback/i);
});
