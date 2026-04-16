import { readFile } from 'node:fs/promises';

import {
  classifyRuntimeSensitivity,
  computeProjectStatus,
  extractClosingIssueNumbers,
  normalizePullRequestState,
  parseValidationStatus,
  resolveIssueNumbersToEnsure,
  resolveRuntimeValidationOptionName,
  sortPullRequestsForIssue,
} from './lib/project-automation.mjs';

const apiVersion = '2022-11-28';
const projectTitle = 'Quickey Backlog';
const statusFieldName = 'Status';
const runtimeValidationFieldName = 'Runtime Validation';

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }

  return value;
}

async function graphqlRequest(query, variables = {}) {
  const response = await fetch('https://api.github.com/graphql', {
    method: 'POST',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${requiredEnv('PROJECT_AUTOMATION_TOKEN')}`,
      'Content-Type': 'application/json',
      'User-Agent': 'quickey-project-sync',
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

async function restRequest(pathname) {
  const response = await fetch(`https://api.github.com${pathname}`, {
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${requiredEnv('PROJECT_AUTOMATION_TOKEN')}`,
      'User-Agent': 'quickey-project-sync',
      'X-GitHub-Api-Version': apiVersion,
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`REST request ${pathname} failed (${response.status}): ${body}`);
  }

  return response.json();
}

async function resolveProject(owner, repo) {
  const data = await graphqlRequest(
    `
      query ResolveProject($owner: String!, $repo: String!, $projectQuery: String!) {
        repository(owner: $owner, name: $repo) {
          owner {
            __typename
            login
            ... on User {
              projectsV2(first: 20, query: $projectQuery) {
                nodes {
                  id
                  title
                }
              }
            }
            ... on Organization {
              projectsV2(first: 20, query: $projectQuery) {
                nodes {
                  id
                  title
                }
              }
            }
          }
        }
      }
    `,
    { owner, repo, projectQuery: projectTitle },
  );

  const projects = data.repository.owner.projectsV2.nodes;
  const project = projects.find((candidate) => candidate.title === projectTitle);

  if (!project) {
    throw new Error(`Project "${projectTitle}" was not found for ${owner}.`);
  }

  return project;
}

async function loadProjectSnapshot(projectId) {
  const items = [];
  let after = null;
  let fields = null;

  do {
    const data = await graphqlRequest(
      `
        query ProjectSnapshot($projectId: ID!, $after: String) {
          node(id: $projectId) {
            ... on ProjectV2 {
              fields(first: 20) {
                nodes {
                  ... on ProjectV2SingleSelectField {
                    id
                    name
                    options {
                      id
                      name
                    }
                  }
                }
              }
              items(first: 100, after: $after) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                nodes {
                  id
                  content {
                    __typename
                    ... on Issue {
                      id
                      number
                      state
                      title
                      url
                    }
                  }
                  fieldValues(first: 20) {
                    nodes {
                      ... on ProjectV2ItemFieldSingleSelectValue {
                        field {
                          ... on ProjectV2SingleSelectField {
                            id
                            name
                          }
                        }
                        name
                        optionId
                      }
                    }
                  }
                }
              }
            }
          }
        }
      `,
      { projectId, after },
    );

    const projectNode = data.node;
    if (!fields) {
      fields = projectNode.fields.nodes.filter(Boolean);
    }

    items.push(...projectNode.items.nodes);
    after = projectNode.items.pageInfo.hasNextPage ? projectNode.items.pageInfo.endCursor : null;
  } while (after);

  return { fields, items };
}

async function addIssueToProject(projectId, issueNodeId) {
  await graphqlRequest(
    `
      mutation AddIssueToProject($projectId: ID!, $contentId: ID!) {
        addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
          item {
            id
          }
        }
      }
    `,
    { projectId, contentId: issueNodeId },
  );
}

async function updateSingleSelectField(projectId, itemId, fieldId, optionId) {
  await graphqlRequest(
    `
      mutation UpdateProjectField(
        $projectId: ID!
        $itemId: ID!
        $fieldId: ID!
        $optionId: String!
      ) {
        updateProjectV2ItemFieldValue(
          input: {
            projectId: $projectId
            itemId: $itemId
            fieldId: $fieldId
            value: { singleSelectOptionId: $optionId }
          }
        ) {
          projectV2Item {
            id
          }
        }
      }
    `,
    { projectId, itemId, fieldId, optionId },
  );
}

async function listAllPullRequests(owner, repo) {
  const pullRequests = [];
  let after = null;

  do {
    const data = await graphqlRequest(
      `
        query PullRequests($owner: String!, $repo: String!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequests(
              first: 100
              after: $after
              states: [OPEN, CLOSED, MERGED]
              orderBy: { field: UPDATED_AT, direction: DESC }
            ) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                number
                state
                body
                mergedAt
                updatedAt
                url
              }
            }
          }
        }
      `,
      { owner, repo, after },
    );

    pullRequests.push(...data.repository.pullRequests.nodes);
    after = data.repository.pullRequests.pageInfo.hasNextPage
      ? data.repository.pullRequests.pageInfo.endCursor
      : null;
  } while (after);

  return pullRequests;
}

async function listPullRequestFiles(owner, repo, pullRequestNumber) {
  const files = [];
  let page = 1;

  while (true) {
    const result = await restRequest(
      `/repos/${owner}/${repo}/pulls/${pullRequestNumber}/files?per_page=100&page=${page}`,
    );

    files.push(...result);
    if (result.length < 100) {
      return files;
    }

    page += 1;
  }
}

async function fetchIssueNodeId(owner, repo, issueNumber) {
  const issue = await restRequest(`/repos/${owner}/${repo}/issues/${issueNumber}`);
  return issue.node_id;
}

async function listRepositoryIssues(owner, repo) {
  const issues = [];
  let page = 1;

  while (true) {
    const result = await restRequest(
      `/repos/${owner}/${repo}/issues?state=all&per_page=100&page=${page}`,
    );

    issues.push(
      ...result.filter((item) => !Object.prototype.hasOwnProperty.call(item, 'pull_request')),
    );

    if (result.length < 100) {
      return issues;
    }

    page += 1;
  }
}

function buildFieldMaps(fields) {
  const fieldByName = new Map(fields.map((field) => [field.name, field]));
  const statusField = fieldByName.get(statusFieldName);
  const runtimeField = fieldByName.get(runtimeValidationFieldName);

  if (!statusField) {
    throw new Error(`Project field "${statusFieldName}" was not found.`);
  }

  if (!runtimeField) {
    throw new Error(`Project field "${runtimeValidationFieldName}" was not found.`);
  }

  return {
    statusField,
    runtimeField,
  };
}

function optionIdByName(field, optionName) {
  const option = field.options.find((candidate) => candidate.name === optionName);
  if (!option) {
    throw new Error(`Option "${optionName}" was not found on field "${field.name}".`);
  }

  return option.id;
}

function currentSingleSelectName(item, fieldName) {
  const fieldValue = item.fieldValues.nodes.find((candidate) => candidate.field?.name === fieldName);
  return fieldValue?.name ?? null;
}

async function ensureIssuesInProject(owner, repo, projectId, snapshotItems, event) {
  const knownIssueNumbers = new Set(
    snapshotItems
      .map((item) => item.content)
      .filter((content) => content?.__typename === 'Issue')
      .map((issue) => issue.number),
  );

  const repositoryIssueNumbers =
    eventName(event) === 'schedule' || eventName(event) === 'workflow_dispatch'
      ? (await listRepositoryIssues(owner, repo)).map((issue) => issue.number)
      : [];
  const issueNumbersToEnsure = resolveIssueNumbersToEnsure({
    eventIssueNumber: event.issue?.number ?? null,
    eventName: eventName(event),
    linkedIssueNumbers: event.pull_request?.body
      ? extractClosingIssueNumbers(event.pull_request.body, { owner, repo })
      : [],
    repositoryIssueNumbers,
  });

  for (const issueNumber of issueNumbersToEnsure) {
    if (knownIssueNumbers.has(issueNumber)) {
      continue;
    }

    const issueNodeId = await fetchIssueNodeId(owner, repo, issueNumber);
    await addIssueToProject(projectId, issueNodeId);
    console.log(`Added issue #${issueNumber} to project "${projectTitle}".`);
  }
}

function eventName(event) {
  return process.env.GITHUB_EVENT_NAME ?? event?.action ?? 'workflow_dispatch';
}

async function buildPullRequestIndex(owner, repo, event) {
  const currentPullRequestNumber = event.pull_request?.number ?? null;
  let currentPullRequestRuntimeSensitive = false;

  if (currentPullRequestNumber) {
    const currentFiles = await listPullRequestFiles(owner, repo, currentPullRequestNumber);
    currentPullRequestRuntimeSensitive = classifyRuntimeSensitivity(
      currentFiles.map((file) => file.filename),
    ).runtimeSensitive;
  }

  const pullRequests = await listAllPullRequests(owner, repo);
  const linkedPullRequests = new Map();

  for (const pullRequest of pullRequests) {
    const issueNumbers = extractClosingIssueNumbers(pullRequest.body ?? '', { owner, repo });
    if (issueNumbers.length === 0) {
      continue;
    }

    const linkedValidationStatus =
      parseValidationStatus(pullRequest.body ?? '') ??
      (pullRequest.number === currentPullRequestNumber && currentPullRequestRuntimeSensitive
        ? 'pending'
        : null);

    for (const issueNumber of issueNumbers) {
      const entries = linkedPullRequests.get(issueNumber) ?? [];
      entries.push({
        mergedAt: pullRequest.mergedAt,
        number: pullRequest.number,
        state: normalizePullRequestState(pullRequest),
        updatedAt: pullRequest.updatedAt,
        url: pullRequest.url,
        validationStatus: linkedValidationStatus,
      });
      linkedPullRequests.set(issueNumber, entries);
    }
  }

  return linkedPullRequests;
}

async function main() {
  const event = JSON.parse(await readFile(process.env.GITHUB_EVENT_PATH, 'utf8'));
  const owner = event.repository.owner.login;
  const repo = event.repository.name;
  const project = await resolveProject(owner, repo);

  let snapshot = await loadProjectSnapshot(project.id);
  await ensureIssuesInProject(owner, repo, project.id, snapshot.items, event);
  snapshot = await loadProjectSnapshot(project.id);

  const { statusField, runtimeField } = buildFieldMaps(snapshot.fields);
  const linkedPullRequests = await buildPullRequestIndex(owner, repo, event);
  let updates = 0;

  for (const item of snapshot.items) {
    if (item.content?.__typename !== 'Issue') {
      continue;
    }

    const issue = item.content;
    const linkedEntries = sortPullRequestsForIssue(
      (linkedPullRequests.get(issue.number) ?? []).filter(
        (pullRequest) => pullRequest.state === 'OPEN' || pullRequest.state === 'MERGED',
      ),
    );
    const desiredStatus = computeProjectStatus({
      issueState: issue.state,
      hasOpenLinkedPullRequest: linkedEntries.some((pullRequest) => pullRequest.state === 'OPEN'),
    });
    const desiredRuntimeValidation = resolveRuntimeValidationOptionName({
      linkedPullRequestValidationStatus: linkedEntries[0]?.validationStatus ?? null,
    });

    if (currentSingleSelectName(item, statusFieldName) !== desiredStatus) {
      await updateSingleSelectField(
        project.id,
        item.id,
        statusField.id,
        optionIdByName(statusField, desiredStatus),
      );
      console.log(`Updated issue #${issue.number} status -> ${desiredStatus}`);
      updates += 1;
    }

    if (currentSingleSelectName(item, runtimeValidationFieldName) !== desiredRuntimeValidation) {
      await updateSingleSelectField(
        project.id,
        item.id,
        runtimeField.id,
        optionIdByName(runtimeField, desiredRuntimeValidation),
      );
      console.log(`Updated issue #${issue.number} runtime validation -> ${desiredRuntimeValidation}`);
      updates += 1;
    }
  }

  console.log(`Project sync complete for "${projectTitle}" with ${updates} field update(s).`);
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exitCode = 1;
});
