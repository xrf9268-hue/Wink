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
  assert.deepEqual(ruleset.bypass_actors, [
    {
      actor_id: 5,
      actor_type: 'RepositoryRole',
      bypass_mode: 'pull_request',
    },
  ]);
  assert.equal(pullRequestRule.parameters.required_approving_review_count, 1);
  assert.equal(pullRequestRule.parameters.dismiss_stale_reviews_on_push, true);
  assert.equal(pullRequestRule.parameters.require_last_push_approval, true);
  assert.equal(pullRequestRule.parameters.required_review_thread_resolution, true);
  assert.equal(pullRequestRule.parameters.require_code_owner_review, false);
  assert.deepEqual(pullRequestRule.parameters.allowed_merge_methods, ['merge', 'squash', 'rebase']);
});

test('main ruleset requires the deterministic Wink checks', () => {
  const statusChecksRule = findRule('required_status_checks');
  const contexts = statusChecksRule.parameters.required_status_checks.map(
    (check) => check.context,
  );

  assert.equal(statusChecksRule.parameters.do_not_enforce_on_create, false);
  assert.deepEqual(contexts, [
    'CI / Build and Test',
    'PR Metadata / Validate PR metadata',
    'Review Gate / Validate review state',
  ]);
});
