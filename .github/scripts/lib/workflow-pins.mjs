// Immutable-reference policy for GitHub Actions `uses:` values (issue #439).
//
// GitHub resolves a tag or branch reference at run time, so a retagged or
// compromised upstream release silently changes what CI executes without any
// change landing in this repository. A full-length commit SHA is the only
// remote reference form the upstream owner cannot move, so every remote
// `uses:` reference must be pinned to one and must carry the human-readable
// upstream tag it came from. Dependabot owns advancing those pins; this module
// only enforces the shape, so it stays deterministic and offline.

export const COMMIT_SHA_PATTERN = /^[0-9a-f]{40}$/;
export const IMAGE_DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/;
// A bare major such as `# v7` names a MOVING tag, so it silently becomes wrong
// the moment upstream re-points it — which is exactly how this repository ended
// up documenting a v7.0.0 commit as `# v7`. Require a specific release.
export const VERSION_COMMENT_PATTERN = /^v?\d+\.\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.-]+)?$/;

const REMOTE_REFERENCE_PATTERN =
  /^([A-Za-z0-9][A-Za-z0-9._-]*)\/([A-Za-z0-9._-]+)((?:\/[^/@\s][^@\s]*)?)@(.+)$/;

// A block scalar (`run: |`, `path: |`, `script: >`) owns every following line
// indented past its key, and those lines are opaque text. Without this the
// scanner reports a `uses:` written inside a shell heredoc as a real reference.
const BLOCK_SCALAR_PATTERN = /^[^\s#][^:]*:\s*[|>][+-]?\d*\s*(?:#.*)?$/;
const USES_PATTERN = /^uses:\s*(.*)$/;
const BLOCK_SCALAR_INDICATOR_PATTERN = /^[|>][+-]?\d*$/;

function splitIndent(line) {
  const match = /^([ \t]*)((?:-[ \t]+)*)(.*)$/.exec(line);

  return {
    indent: match[1].length,
    keyColumn: match[1].length + match[2].length,
    rest: match[3],
  };
}

function readComment(tail) {
  const match = /^\s*#\s*(.*)$/.exec(tail);
  if (!match) {
    return null;
  }

  const comment = match[1].trim();
  return comment === '' ? null : comment;
}

export function splitValueAndComment(rawValue) {
  const text = rawValue.trimStart();
  const quote = text[0];

  if (quote === '"' || quote === "'") {
    const closingIndex = text.indexOf(quote, 1);
    if (closingIndex !== -1) {
      return {
        value: text.slice(1, closingIndex),
        comment: readComment(text.slice(closingIndex + 1)),
      };
    }
  }

  // YAML ends a plain scalar at an unquoted `#` that follows whitespace.
  const commentIndex = text.search(/(?:^|\s)#/);
  if (commentIndex === -1) {
    return { value: text.trim(), comment: null };
  }

  return {
    value: text.slice(0, commentIndex).trim(),
    comment: readComment(text.slice(commentIndex)),
  };
}

export function scanUsesReferences(source) {
  const references = [];
  const lines = source.split(/\r?\n/);
  let blockScalarKeyColumn = null;

  lines.forEach((line, index) => {
    const { indent, keyColumn, rest } = splitIndent(line);

    if (blockScalarKeyColumn !== null) {
      if (rest === '' || indent > blockScalarKeyColumn) {
        return;
      }

      blockScalarKeyColumn = null;
    }

    const match = USES_PATTERN.exec(rest);

    if (!match) {
      if (BLOCK_SCALAR_PATTERN.test(rest)) {
        blockScalarKeyColumn = keyColumn;
      }

      return;
    }

    const { value, comment } = splitValueAndComment(match[1]);

    // `uses: >-` with the reference on the following line is legal YAML. Skipping
    // it as an opaque block would let a mutable reference through unexamined, so
    // record it as an unreadable reference and still consume the block body.
    if (BLOCK_SCALAR_INDICATOR_PATTERN.test(value)) {
      blockScalarKeyColumn = keyColumn;
      references.push({ line: index + 1, value: `uses: ${value}`, comment, blockScalar: true });
      return;
    }

    references.push({ line: index + 1, value, comment });
  });

  return references;
}

export function evaluateReference({ value, comment, blockScalar = false }) {
  const problems = [];

  if (blockScalar) {
    problems.push({
      code: 'block-scalar-reference',
      message: `\`${value}\` hides the reference in a YAML block scalar; write it inline as \`uses: owner/repo@<sha> # vX.Y.Z\` so the immutable-reference policy can read it.`,
    });

    return { kind: 'invalid', action: null, ref: null, version: null, problems };
  }

  if (value === '') {
    problems.push({
      code: 'empty-reference',
      message: '`uses:` has no value.',
    });

    return { kind: 'invalid', action: null, ref: null, version: null, problems };
  }

  if (value.startsWith('./') || value.startsWith('../')) {
    if (value.includes('@')) {
      problems.push({
        code: 'local-reference-with-ref',
        message: `Local reference \`${value}\` must not carry an \`@ref\`; GitHub always runs local actions from the current commit.`,
      });
    }

    return { kind: 'local', action: value, ref: null, version: null, problems };
  }

  if (value.startsWith('docker://')) {
    const digest = value.slice(value.lastIndexOf('@') + 1);
    if (!value.includes('@') || !IMAGE_DIGEST_PATTERN.test(digest)) {
      problems.push({
        code: 'mutable-container-image',
        message: `Container reference \`${value}\` must be pinned to an immutable \`@sha256:<digest>\`.`,
      });
    }

    return { kind: 'docker', action: value.split('@')[0], ref: digest, version: null, problems };
  }

  const match = REMOTE_REFERENCE_PATTERN.exec(value);
  if (!match) {
    problems.push({
      code: 'unparseable-reference',
      message: `\`${value}\` is not a recognizable \`owner/repo[/path]@ref\`, \`./local\`, or \`docker://\` reference.`,
    });

    return { kind: 'invalid', action: null, ref: null, version: null, problems };
  }

  const [, owner, repo, path, ref] = match;
  const action = `${owner}/${repo}`;
  const isWorkflow = path.startsWith('/.github/workflows/');

  if (!COMMIT_SHA_PATTERN.test(ref)) {
    problems.push({
      code: 'mutable-reference',
      message: `${
        isWorkflow ? 'Reusable workflow' : 'Action'
      } \`${action}${path}\` is pinned to \`${ref}\`; pin it to a full-length 40-character lowercase commit SHA.`,
    });
  }

  const version = comment;

  if (comment === null) {
    problems.push({
      code: 'missing-version-comment',
      message: `\`${action}${path}\` has no trailing version comment; append \`# <tag>\` so reviewers and Dependabot agree on the intended upstream release.`,
    });
  } else if (!VERSION_COMMENT_PATTERN.test(comment)) {
    problems.push({
      code: 'invalid-version-comment',
      message: `\`${action}${path}\` comment must be exactly one specific upstream release of at least \`MAJOR.MINOR\` (for example \`# v4.2.0\`), got \`# ${comment}\`. A bare major names a moving tag, and any trailing prose makes Dependabot skip the comment rewrite so the SHA advances while the comment goes stale.`,
    });
  }

  return {
    kind: isWorkflow ? 'reusable-workflow' : 'action',
    action,
    ref,
    version,
    problems,
  };
}

export function evaluateFile({ path, source }) {
  const references = [];
  const findings = [];

  for (const reference of scanUsesReferences(source)) {
    const evaluated = evaluateReference(reference);

    references.push({ ...reference, ...evaluated, path });

    for (const problem of evaluated.problems) {
      findings.push({ path, line: reference.line, ...problem });
    }
  }

  return { references, findings };
}

// Every occurrence of one upstream repository must advance together: Dependabot
// bumps them as a single dependency, and split pins are how a stale SHA (or a
// mismatched `# vX` comment) survives an update. Sub-paths of one repository
// (`github/codeql-action/init` and `.../analyze`) share a repository and so
// share a SHA by construction.
export function evaluateConsistency(references) {
  const findings = [];
  const byAction = new Map();

  for (const reference of references) {
    if (reference.kind !== 'action' && reference.kind !== 'reusable-workflow') {
      continue;
    }

    if (!COMMIT_SHA_PATTERN.test(reference.ref ?? '')) {
      continue;
    }

    const group = byAction.get(reference.action) ?? [];
    group.push(reference);
    byAction.set(reference.action, group);
  }

  for (const [action, group] of [...byAction.entries()].sort()) {
    const distinctRefs = [...new Set(group.map((reference) => reference.ref))];

    if (distinctRefs.length > 1) {
      for (const reference of group) {
        findings.push({
          path: reference.path,
          line: reference.line,
          code: 'inconsistent-action-pin',
          message: `\`${action}\` is pinned to ${distinctRefs.length} different commits across the repository (${formatLocations(
            group,
          )}); align them so one Dependabot update covers every call site.`,
        });
      }

      continue;
    }

    const distinctVersions = [...new Set(group.map((reference) => reference.version))];
    if (distinctVersions.length > 1) {
      for (const reference of group) {
        findings.push({
          path: reference.path,
          line: reference.line,
          code: 'inconsistent-version-comment',
          message: `\`${action}\` is pinned to one commit but documented as ${distinctVersions
            .map((version) => `\`${version ?? '(missing)'}\``)
            .join(' and ')}; exactly one of those comments is wrong.`,
        });
      }
    }
  }

  return findings;
}

function formatLocations(group) {
  return group.map((reference) => `${reference.path}:${reference.line}`).join(', ');
}

export function evaluateRepository(files, { root = '.github' } = {}) {
  const references = [];
  const findings = [];

  for (const file of [...files].sort((a, b) => a.path.localeCompare(b.path))) {
    const result = evaluateFile(file);
    references.push(...result.references);
    findings.push(...result.findings);
  }

  // A validator that silently inspected nothing is not a passing validator:
  // a rename, a bad glob, or a checkout without `.github/` would otherwise
  // report success while enforcing nothing.
  if (files.length === 0) {
    findings.push({
      path: root,
      line: 1,
      code: 'no-workflows-discovered',
      message: 'No workflow or action definition files were discovered; the pin policy checked nothing.',
    });
  } else if (references.length === 0) {
    findings.push({
      path: root,
      line: 1,
      code: 'no-references-discovered',
      message: `Discovered ${files.length} workflow file(s) but zero \`uses:\` references; the scanner is not seeing real content.`,
    });
  }

  findings.push(...evaluateConsistency(references));
  findings.sort(
    (a, b) => a.path.localeCompare(b.path) || a.line - b.line || a.code.localeCompare(b.code),
  );

  return { references, findings, ok: findings.length === 0 };
}

export function summarizeReferences(references) {
  const counts = references.reduce((accumulator, reference) => {
    accumulator.set(reference.kind, (accumulator.get(reference.kind) ?? 0) + 1);
    return accumulator;
  }, new Map());

  return [...counts.entries()]
    .sort()
    .map(([kind, count]) => `${kind}: ${count}`)
    .join(', ');
}
