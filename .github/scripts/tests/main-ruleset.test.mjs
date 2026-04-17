import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const ruleset = JSON.parse(
  await readFile(new URL('../../governance/main-ruleset.json', import.meta.url), 'utf8'),
);

function findRule(type) {
  return ruleset.rules.find((rule) => rule.type === type);
}

test('main ruleset requires pull requests and review freshness', () => {
  const pullRequestRule = findRule('pull_request');

  assert.equal(ruleset.target, 'branch');
  assert.equal(ruleset.enforcement, 'active');
  assert.deepEqual(ruleset.conditions.ref_name.include, ['~DEFAULT_BRANCH']);
  assert.equal(pullRequestRule.parameters.required_approving_review_count, 1);
  assert.equal(pullRequestRule.parameters.dismiss_stale_reviews_on_push, true);
  assert.equal(pullRequestRule.parameters.require_last_push_approval, true);
  assert.equal(pullRequestRule.parameters.required_review_thread_resolution, true);
});

test('main ruleset requires the deterministic Quickey checks', () => {
  const statusChecksRule = findRule('required_status_checks');
  const contexts = statusChecksRule.parameters.required_status_checks.map(
    (check) => check.context,
  );

  assert.deepEqual(contexts, [
    'CI / Build and Test',
    'PR Metadata / Validate PR metadata',
    'Review Gate / Validate review state',
  ]);
});
