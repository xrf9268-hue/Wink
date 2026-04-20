import { appendFile, readFile } from 'node:fs/promises';

import { evaluateReviewState, summarizeBlockingThreads } from './lib/review-state.mjs';

const apiVersion = '2022-11-28';

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }

  return value;
}

async function graphqlRequest(query, variables) {
  const response = await fetch('https://api.github.com/graphql', {
    method: 'POST',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${requiredEnv('GITHUB_TOKEN')}`,
      'Content-Type': 'application/json',
      'User-Agent': 'wink-review-gate',
      'X-GitHub-Api-Version': apiVersion,
    },
    body: JSON.stringify({ query, variables }),
  });

  const payload = await response.json();
  if (!response.ok || payload.errors?.length) {
    const details = JSON.stringify(payload.errors ?? payload, null, 2);
    throw new Error(`GraphQL request failed: ${details}`);
  }

  return payload.data;
}

async function loadReviewState(owner, repo, pullRequestNumber) {
  if (process.env.PR_REVIEW_STATE) {
    return JSON.parse(process.env.PR_REVIEW_STATE);
  }

  let after = null;
  let reviewDecision = null;
  const reviewThreads = [];

  do {
    const data = await graphqlRequest(
      `
        query ReviewState($owner: String!, $repo: String!, $pullRequestNumber: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $pullRequestNumber) {
              reviewDecision
              reviewThreads(first: 100, after: $after) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                nodes {
                  isResolved
                  isOutdated
                  path
                  line
                  originalLine
                  startLine
                  originalStartLine
                  comments(first: 1) {
                    nodes {
                      author {
                        login
                      }
                      bodyText
                    }
                  }
                }
              }
            }
          }
        }
      `,
      { owner, repo, pullRequestNumber, after },
    );

    const pullRequest = data.repository.pullRequest;
    if (!pullRequest) {
      throw new Error(`Pull request #${pullRequestNumber} was not found.`);
    }

    reviewDecision = pullRequest.reviewDecision;

    for (const thread of pullRequest.reviewThreads.nodes) {
      const comment = thread.comments.nodes[0];

      reviewThreads.push({
        isResolved: thread.isResolved,
        isOutdated: thread.isOutdated,
        path: thread.path,
        line: thread.line ?? thread.originalLine ?? thread.startLine ?? thread.originalStartLine,
        reviewer: comment?.author?.login ?? 'ghost',
        bodyText: comment?.bodyText ?? '',
      });
    }

    after = pullRequest.reviewThreads.pageInfo.hasNextPage
      ? pullRequest.reviewThreads.pageInfo.endCursor
      : null;
  } while (after);

  return { reviewDecision, reviewThreads };
}

function stepSummary(result) {
  if (result.ok) {
    return '## Review Gate\n\nNo unresolved actionable review feedback remains.\n';
  }

  const lines = [
    '## Review Gate',
    '',
    'Merge is blocked until the following review state is cleared:',
    '',
  ];

  if (result.reasons.includes('changes-requested')) {
    lines.push('- Pull request review decision is `CHANGES_REQUESTED`.');
  }

  if (result.blockingThreads.length > 0) {
    lines.push('- Unresolved actionable inline review threads remain.');
    lines.push('');
    lines.push(summarizeBlockingThreads(result.blockingThreads));
  }

  return `${lines.join('\n')}\n`;
}

async function writeStepSummary(summary) {
  if (!process.env.GITHUB_STEP_SUMMARY) {
    return;
  }

  await appendFile(process.env.GITHUB_STEP_SUMMARY, summary);
}

async function main() {
  const event = JSON.parse(await readFile(requiredEnv('GITHUB_EVENT_PATH'), 'utf8'));
  const owner = process.env.REPO_OWNER ?? event.repository?.owner?.login;
  const repo = process.env.REPO_NAME ?? event.repository?.name;
  const pullRequestNumber = event.pull_request?.number;

  if (!owner || !repo || !pullRequestNumber) {
    throw new Error('This script must run from a pull request-related workflow event.');
  }

  const reviewState = await loadReviewState(owner, repo, pullRequestNumber);
  const result = evaluateReviewState(reviewState);
  const summary = stepSummary(result);

  await writeStepSummary(summary);

  if (result.ok) {
    console.log('No unresolved actionable review feedback remains.');
    return;
  }

  console.error('Found unresolved actionable review feedback.');
  if (result.reasons.includes('changes-requested')) {
    console.error('- Pull request review decision is CHANGES_REQUESTED.');
  }

  if (result.blockingThreads.length > 0) {
    console.error(summarizeBlockingThreads(result.blockingThreads));
  }

  process.exitCode = 1;
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exitCode = 1;
});
