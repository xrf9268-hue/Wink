export function firstLine(bodyText) {
  return (
    bodyText
      .split(/\r?\n/)
      .map((line) => line.trim().replace(/\s+/g, ' '))
      .find(Boolean) ?? '(no summary text)'
  );
}

export function isActionableThread(thread) {
  return thread.isResolved === false && thread.isOutdated === false;
}

export function evaluateReviewState({ reviewDecision, reviewThreads }) {
  const blockingThreads = reviewThreads.filter(isActionableThread);
  const reasons = [];

  if (reviewDecision === 'CHANGES_REQUESTED') {
    reasons.push('changes-requested');
  }

  if (blockingThreads.length > 0) {
    reasons.push('unresolved-thread');
  }

  return {
    ok: reasons.length === 0,
    reasons,
    blockingThreads,
  };
}

export function summarizeBlockingThreads(blockingThreads) {
  return blockingThreads
    .map((thread) => {
      const path = thread.path ?? '(unknown path)';
      const anchor =
        thread.line ?? thread.originalLine ?? thread.startLine ?? thread.originalStartLine ?? '?';
      const reviewer = thread.reviewer ?? 'ghost';

      return `- ${path}:${anchor} - ${reviewer} - ${firstLine(thread.bodyText ?? '')}`;
    })
    .join('\n');
}
