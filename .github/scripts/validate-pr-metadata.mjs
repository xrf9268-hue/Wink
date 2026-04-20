import { readFile } from 'node:fs/promises';

import {
  classifyRuntimeSensitivity,
  extractClosingIssueNumbers,
  parseValidationChecklist,
} from './lib/project-automation.mjs';

const apiVersion = '2022-11-28';

async function githubRequest(pathname) {
  const response = await fetch(`https://api.github.com${pathname}`, {
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
      'User-Agent': 'wink-pr-metadata-validator',
      'X-GitHub-Api-Version': apiVersion,
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`GitHub API ${pathname} failed (${response.status}): ${body}`);
  }

  return response.json();
}

async function listPullRequestFiles(owner, repo, pullRequestNumber) {
  if (process.env.PR_FILES) {
    return JSON.parse(process.env.PR_FILES);
  }

  const files = [];
  let page = 1;

  while (true) {
    const result = await githubRequest(
      `/repos/${owner}/${repo}/pulls/${pullRequestNumber}/files?per_page=100&page=${page}`,
    );

    files.push(...result);
    if (result.length < 100) {
      return files;
    }

    page += 1;
  }
}

function formatIssueNumbers(issueNumbers) {
  return issueNumbers.map((issueNumber) => `#${issueNumber}`).join(', ');
}

async function main() {
  const event = JSON.parse(await readFile(process.env.GITHUB_EVENT_PATH, 'utf8'));
  const owner = process.env.REPO_OWNER ?? event.repository.owner.login;
  const repo = process.env.REPO_NAME ?? event.repository.name;
  const pullRequest = event.pull_request;

  if (!pullRequest) {
    throw new Error('This script must run from a pull_request_target workflow event.');
  }

  const pullRequestNumber = pullRequest.number;
  const body = process.env.PR_BODY ?? pullRequest.body ?? '';
  const files = await listPullRequestFiles(owner, repo, pullRequestNumber);
  const issueNumbers = extractClosingIssueNumbers(body, { owner, repo });
  const validation = parseValidationChecklist(body);
  const runtimeSensitivity = classifyRuntimeSensitivity(files.map((file) => file.filename));
  const errors = [];

  if (issueNumbers.length === 0) {
    errors.push(
      'PR body must include a closing keyword such as `Fixes #123` so merge closes the linked issue automatically.',
    );
  }

  if (validation.presentOptions.length !== 3) {
    errors.push(
      'PR body must keep all three `Validation Status` checklist options from the template.',
    );
  }

  if (validation.checkedOptions.length !== 1) {
    errors.push('PR body must check exactly one `Validation Status` option.');
  }

  if (runtimeSensitivity.runtimeSensitive && validation.status === 'not-required') {
    errors.push(
      `Runtime-sensitive files changed (${runtimeSensitivity.matches.join(
        ', ',
      )}); choose \`macOS runtime validation pending\` or \`macOS runtime validation complete\`.`,
    );
  }

  const summary = [
    `Linked issues: ${issueNumbers.length > 0 ? formatIssueNumbers(issueNumbers) : 'none'}`,
    `Validation status: ${validation.status ?? 'missing'}`,
    `Runtime-sensitive paths: ${
      runtimeSensitivity.runtimeSensitive ? runtimeSensitivity.matches.join(', ') : 'none'
    }`,
  ];

  if (errors.length > 0) {
    for (const error of errors) {
      console.error(`::error::${error}`);
    }

    console.log(summary.join('\n'));
    process.exitCode = 1;
    return;
  }

  console.log(summary.join('\n'));
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exitCode = 1;
});
