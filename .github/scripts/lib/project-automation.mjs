const closingKeywordPattern =
  /\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)\s+(?:([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+))?#(\d+)\b/gi;

const validationLabelMap = new Map([
  ['not runtime-sensitive', 'not-required'],
  ['macos runtime validation pending', 'pending'],
  ['macos runtime validation complete', 'complete'],
]);

const runtimeSensitivePatterns = [
  /^Sources\/Quickey\/Services\/AccessibilityPermissionService\.swift$/,
  /^Sources\/Quickey\/Services\/AppSwitcher\.swift$/,
  /^Sources\/Quickey\/Services\/ApplicationObservation\.swift$/,
  /^Sources\/Quickey\/Services\/CarbonHotKeyProvider\.swift$/,
  /^Sources\/Quickey\/Services\/EventTapCaptureProvider\.swift$/,
  /^Sources\/Quickey\/Services\/EventTapManager\.swift$/,
  /^Sources\/Quickey\/Services\/LaunchAtLoginService\.swift$/,
  /^Sources\/Quickey\/Services\/ShortcutCaptureCoordinator\.swift$/,
  /^Sources\/Quickey\/Services\/ShortcutManager\.swift$/,
  /^Sources\/Quickey\/Services\/SkyLightBridge\.swift$/,
  /^Sources\/Quickey\/AppController\.swift$/,
  /^Sources\/Quickey\/AppDelegate\.swift$/,
  /^Sources\/Quickey\/main\.swift$/,
  /^Sources\/Quickey\/Resources\/Info\.plist$/,
  /^entitlements\.plist$/,
  /^scripts\/cgevent-helper\.swift$/,
  /^scripts\/e2e-.*\.(?:sh|bats)$/,
  /^scripts\/package-app\.sh$/,
  /^scripts\/package-dmg\.sh$/,
];

function normalizeLabel(text) {
  return text.trim().toLowerCase().replace(/\s+/g, ' ');
}

function extractValidationSection(body) {
  const lines = body.split(/\r?\n/);
  const startIndex = lines.findIndex((line) =>
    /^##\s*(?:Validation Status|Runtime Validation)\s*$/i.test(line),
  );

  if (startIndex === -1) {
    return '';
  }

  const collected = [];
  for (const line of lines.slice(startIndex + 1)) {
    if (/^##\s+/.test(line)) {
      break;
    }

    collected.push(line);
  }

  return collected.join('\n');
}

export function extractClosingIssueNumbers(body, { owner, repo }) {
  if (!body) {
    return [];
  }

  const issueNumbers = [];
  const seen = new Set();

  for (const match of body.matchAll(closingKeywordPattern)) {
    const [, , matchOwner, matchRepo, rawIssueNumber] = match;

    if (matchOwner && matchRepo) {
      if (
        matchOwner.toLowerCase() !== owner.toLowerCase() ||
        matchRepo.toLowerCase() !== repo.toLowerCase()
      ) {
        continue;
      }
    }

    const issueNumber = Number.parseInt(rawIssueNumber, 10);
    if (!Number.isFinite(issueNumber) || seen.has(issueNumber)) {
      continue;
    }

    seen.add(issueNumber);
    issueNumbers.push(issueNumber);
  }

  return issueNumbers;
}

export function parseValidationChecklist(body) {
  const details = {
    checkedOptions: [],
    presentOptions: [],
    status: null,
  };

  if (!body) {
    return details;
  }

  const checkboxPattern = /^-\s+\[([ xX])\]\s+(.+)$/gm;
  for (const match of body.matchAll(checkboxPattern)) {
    const isChecked = match[1].toLowerCase() === 'x';
    const normalizedLabel = normalizeLabel(match[2]);
    const status = validationLabelMap.get(normalizedLabel);

    if (!status) {
      continue;
    }

    details.presentOptions.push(status);
    if (isChecked) {
      details.checkedOptions.push(status);
    }
  }

  if (details.checkedOptions.length === 1) {
    details.status = details.checkedOptions[0];
  }

  return details;
}

export function parseValidationStatus(body) {
  const checklistStatus = parseValidationChecklist(body).status;
  if (checklistStatus) {
    return checklistStatus;
  }

  const validationSection = normalizeLabel(extractValidationSection(body));
  if (!validationSection) {
    return null;
  }

  if (validationSection.includes('macos runtime validation complete')) {
    return 'complete';
  }

  if (validationSection.includes('macos runtime validation pending')) {
    return 'pending';
  }

  if (validationSection.includes('not required')) {
    return 'not-required';
  }

  return null;
}

export function classifyRuntimeSensitivity(paths) {
  const matches = [];

  for (const path of paths) {
    if (runtimeSensitivePatterns.some((pattern) => pattern.test(path))) {
      matches.push(path);
    }
  }

  return {
    runtimeSensitive: matches.length > 0,
    matches,
  };
}

export function computeProjectStatus({ issueState, hasOpenLinkedPullRequest }) {
  if (issueState === 'CLOSED') {
    return 'Done';
  }

  if (hasOpenLinkedPullRequest) {
    return 'In Progress';
  }

  return 'Ready';
}

export function resolveRuntimeValidationOptionName({
  fallbackRuntimeSensitive = false,
  linkedPullRequestValidationStatus,
}) {
  if (linkedPullRequestValidationStatus === 'complete') {
    return 'macOS complete';
  }

  if (linkedPullRequestValidationStatus === 'pending' || fallbackRuntimeSensitive) {
    return 'macOS pending';
  }

  return 'None';
}

export function normalizePullRequestState(pullRequest) {
  if (pullRequest.state === 'OPEN') {
    return 'OPEN';
  }

  if (pullRequest.mergedAt) {
    return 'MERGED';
  }

  return 'CLOSED';
}

export function resolveIssueNumbersToEnsure({
  eventName,
  eventIssueNumber,
  linkedIssueNumbers = [],
  repositoryIssueNumbers = [],
}) {
  const issueNumbers =
    eventName === 'schedule' || eventName === 'workflow_dispatch'
      ? repositoryIssueNumbers
      : [eventIssueNumber, ...linkedIssueNumbers];

  const dedupedIssueNumbers = [];
  const seen = new Set();

  for (const issueNumber of issueNumbers) {
    if (!Number.isInteger(issueNumber) || seen.has(issueNumber)) {
      continue;
    }

    seen.add(issueNumber);
    dedupedIssueNumbers.push(issueNumber);
  }

  return dedupedIssueNumbers;
}

export function sortPullRequestsForIssue(pullRequests) {
  return [...pullRequests].sort((left, right) => {
    const leftPriority =
      normalizePullRequestState(left) === 'OPEN'
        ? 0
        : normalizePullRequestState(left) === 'MERGED'
          ? 1
          : 2;
    const rightPriority =
      normalizePullRequestState(right) === 'OPEN'
        ? 0
        : normalizePullRequestState(right) === 'MERGED'
          ? 1
          : 2;

    if (leftPriority !== rightPriority) {
      return leftPriority - rightPriority;
    }

    const leftTimestamp = Date.parse(left.mergedAt ?? left.updatedAt ?? 0);
    const rightTimestamp = Date.parse(right.mergedAt ?? right.updatedAt ?? 0);
    return rightTimestamp - leftTimestamp;
  });
}
