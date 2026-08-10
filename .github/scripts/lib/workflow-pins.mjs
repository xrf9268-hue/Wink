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
// YAML accepts the indentation and chomping indicators in EITHER order, so both
// `|-2` and `|2-` are valid. Missing one order would leave a `run:` body
// unrecognized and its shell text scanned as workflow content.
const BLOCK_SCALAR_INDICATOR = String.raw`[|>](?:\d[+-]?|[+-]\d?)?`;
const BLOCK_SCALAR_PATTERN = new RegExp(`^[^\\s#][^:]*:\\s*${BLOCK_SCALAR_INDICATOR}\\s*(?:#.*)?$`);
const BLOCK_SCALAR_INDICATOR_PATTERN = new RegExp(`^${BLOCK_SCALAR_INDICATOR}$`);
// YAML permits a quoted mapping key, and GitHub accepts `"uses": owner/repo@ref`.
// A double-quoted key may also carry escapes, so `"uses"` is the same key —
// keys are decoded before comparison rather than matched literally.
const USES_PATTERN =
  /^(?:uses(?=\s*:(?:\s|$))|"((?:[^"\\]|\\.)*)"|'((?:[^']|'')*)')\s*:\s*(.*)$/;
// A flow mapping (`- { name: Cache, uses: owner/repo@main }`) is valid YAML that
// GitHub honors, but its `uses` never starts a line. Rather than grow a YAML
// parser, detect the shape and fail closed — an unreadable reference must never
// be mistaken for an absent one.
const FLOW_MAPPING_USES_PATTERN = /[{[,]\s*(?:uses|"uses"|'uses')\s*:/;
// A flow collection only ever opens in value position: `- { … }` / `- [ … ]`
// (the leading `- ` is already stripped) or `key: { … }` / `key: [ … ]`. A flow
// sequence counts because `steps: [ { uses: … } ]` reaches a mapping through
// one. Anchoring here, after quoted spans are blanked out, keeps
// `run: echo "{ uses: x }"` from reading as a reference.
const FLOW_MAPPING_OPENS_PATTERN = /^[{[]|:\s*[{[]/;
const USES_KEY = String.raw`(?:uses|"uses"|'uses')`;
// What may follow the key `uses`, and nothing else may.
//
//   `\s*:(?=[\s,\]}]|$)`  a real separator. A colon only separates when what
//                          follows IT does too, so `uses:foo` stays one plain
//                          scalar naming an unrelated key.
//   `\s*(?=[,\]}#]|$)`     the key ends here, with its `:` on the next line, a
//                          comment, a flow delimiter, or end of input.
//
// The second alternative must NOT accept bare whitespace with content after it:
// `? uses cache` is the plain scalar `uses cache`, a different key again.
const USES_KEY_END = String.raw`(?:\s*:(?=[\s,\]}]|$)|\s*(?=[,\]}#]|$))`;
// `? uses` may be followed by `: <value>` on the same line or by a `:` line of
// its own.
const EXPLICIT_USES_KEY_PATTERN = new RegExp(String.raw`^\?\s+${USES_KEY}${USES_KEY_END}`);
// The same key on a flow CONTINUATION line has no delimiter ahead of it:
// `steps: [` followed by `? uses : actions/cache@main`.
const LEADING_EXPLICIT_USES_KEY_PATTERN = new RegExp(String.raw`^\?\s*${USES_KEY}${USES_KEY_END}`);
// The same explicit-key form is legal inside a flow collection, where it never
// starts a line: `steps: [ ? uses : actions/cache@main ]`. The `?` sits between
// the collection delimiter and the key, so neither the flow `uses` pattern nor
// the whole-line explicit-key pattern sees it.
const FLOW_EXPLICIT_USES_KEY_PATTERN = new RegExp(
  String.raw`[{[,]\s*\?\s*${USES_KEY}${USES_KEY_END}`,
);
const QUOTED_SPAN_PATTERN = /("(?:[^"\\]|\\.)*"|'(?:[^']|'')*')(\s*:)?/g;

// Blank quoted *values* so `run: echo "{ uses: x }"` cannot be mistaken for a
// flow mapping, while leaving quoted *keys* intact so `{ "uses": … }` still
// reads as one. A span followed by `:` is a key; anything else is a value.
function blankQuotedValues(text) {
  return text.replace(QUOTED_SPAN_PATTERN, (match, _span, colon) => (colon ? match : '""'));
}

const YAML_SIMPLE_ESCAPES = {
  0: '\0',
  a: '\x07',
  b: '\b',
  t: '\t',
  n: '\n',
  v: '\v',
  f: '\f',
  r: '\r',
  e: '\x1b',
  '"': '"',
  '\\': '\\',
  '/': '/',
  ' ': ' ',
  N: '',
  _: ' ',
};

// A double-quoted YAML key is a scalar, so `"uses"` IS the key `uses`.
// Matching the literal text would let an escape hide a mutable reference.
export function decodeDoubleQuoted(text) {
  return text.replace(
    /\\(?:x([0-9A-Fa-f]{2})|u([0-9A-Fa-f]{4})|U([0-9A-Fa-f]{8})|(.))/g,
    (match, hex2, hex4, hex8, simple) => {
      const hex = hex2 ?? hex4 ?? hex8;
      if (hex !== undefined) {
        return String.fromCodePoint(Number.parseInt(hex, 16));
      }

      return Object.prototype.hasOwnProperty.call(YAML_SIMPLE_ESCAPES, simple)
        ? YAML_SIMPLE_ESCAPES[simple]
        : simple;
    },
  );
}

export function matchUsesKey(text) {
  const match = USES_PATTERN.exec(text);
  if (!match) {
    return null;
  }

  const [, doubleQuotedKey, singleQuotedKey, value] = match;

  if (doubleQuotedKey !== undefined && decodeDoubleQuoted(doubleQuotedKey) !== 'uses') {
    return null;
  }

  if (singleQuotedKey !== undefined && singleQuotedKey.replace(/''/g, "'") !== 'uses') {
    return null;
  }

  return { value };
}

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

// Only safe to call after `blankQuotedValues`, which has already removed any
// `#` living inside a quoted scalar.
export function stripYamlComment(text) {
  const commentIndex = text.search(/(?:^|\s)#/);
  return commentIndex === -1 ? text : text.slice(0, commentIndex);
}

// No real workflow keeps a flow collection open across this many lines; the
// cap only exists so a misread brace cannot swallow the rest of the file.
const MAX_FLOW_CONTINUATION_LINES = 200;

function flowDelta(text) {
  let delta = 0;

  for (const character of text) {
    if (character === '{' || character === '[') {
      delta += 1;
    } else if (character === '}' || character === ']') {
      delta -= 1;
    }
  }

  return delta;
}

export function scanUsesReferences(source) {
  const references = [];
  const lines = source.split(/\r?\n/);
  let blockScalarKeyColumn = null;
  // A flow collection can span lines, and its `uses` key may sit on a
  // continuation line behind another key: `- { name: Checkout,` followed by
  // `id: checkout, uses: actions/checkout@main }`. Neither line matches on its
  // own, so track how deep we are inside braces instead.
  let flowDepth = 0;
  let flowOpenLines = 0;

  lines.forEach((line, index) => {
    const { indent, keyColumn, rest } = splitIndent(line);

    if (blockScalarKeyColumn !== null) {
      if (rest === '' || indent > blockScalarKeyColumn) {
        return;
      }

      blockScalarKeyColumn = null;
    }

    // Bound a runaway depth from an unbalanced brace the scanner misread,
    // without using indentation to do it: a flow collection ignores
    // indentation, so a legitimate continuation may sit at column zero and
    // resetting there would drop an open collection before its `uses` is seen.
    if (flowDepth > 0) {
      flowOpenLines += 1;
      if (flowOpenLines > MAX_FLOW_CONTINUATION_LINES) {
        // Resuming here would be the same bug the cap exists to prevent: past
        // this point a `uses` on a continuation line is read as ordinary
        // content and ignored. The scanner has admitted it cannot follow the
        // file, which is exactly when it must not report success.
        references.push({
          line: index + 1,
          value: rest.trim(),
          comment: null,
          flowOverflow: true,
        });
        flowDepth = 0;
        flowOpenLines = 0;
        return;
      }
    } else {
      flowOpenLines = 0;
    }

    // Values are blanked so `run: echo "{ uses: x }"` is not a flow mapping;
    // the surviving quoted spans are keys, so decoding their escapes is what
    // makes `{ "uses": … }` readable as the `uses` key it really is.
    // Comments must go before the braces are counted: a `}` written inside a
    // trailing comment would otherwise close a flow collection that is still
    // open, dropping the depth and hiding a `uses` on the continuation line.
    const bare = stripYamlComment(decodeDoubleQuoted(blankQuotedValues(rest)));
    const continuesFlow = flowDepth > 0;
    // A flow collection that opens and closes on one line still needs the
    // `uses` check; only the depth bookkeeping cares whether it stayed open.
    const opensFlow = FLOW_MAPPING_OPENS_PATTERN.test(bare);

    if (continuesFlow || opensFlow) {
      if (
        FLOW_EXPLICIT_USES_KEY_PATTERN.test(bare) ||
        LEADING_EXPLICIT_USES_KEY_PATTERN.test(bare)
      ) {
        references.push({ line: index + 1, value: rest.trim(), comment: null, explicitKey: true });
      } else if (FLOW_MAPPING_USES_PATTERN.test(bare) || matchUsesKey(bare) !== null) {
        references.push({ line: index + 1, value: rest.trim(), comment: null, flowMapping: true });
      }

      flowDepth = Math.max(0, flowDepth + flowDelta(bare));
      return;
    }

    // YAML's explicit-key form (`? uses` then `: <value>`) parses to the same
    // mapping as `uses: <value>`. Rather than model two-line key/value pairs,
    // fail closed on the shape.
    if (EXPLICIT_USES_KEY_PATTERN.test(bare)) {
      references.push({ line: index + 1, value: rest.trim(), comment: null, explicitKey: true });
      return;
    }

    const usesKey = matchUsesKey(rest);

    if (!usesKey) {
      if (BLOCK_SCALAR_PATTERN.test(rest)) {
        blockScalarKeyColumn = keyColumn;
      }

      return;
    }

    const { value, comment } = splitValueAndComment(usesKey.value);

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

export function evaluateReference({
  value,
  comment,
  blockScalar = false,
  flowMapping = false,
  explicitKey = false,
  flowOverflow = false,
}) {
  const problems = [];

  if (flowOverflow) {
    problems.push({
      code: 'flow-tracking-overflow',
      message: `A YAML flow collection stayed open for more than ${MAX_FLOW_CONTINUATION_LINES} lines, so the scanner can no longer tell structure from content and stopped following it here. Rewrite the step in block style.`,
    });

    return { kind: 'invalid', action: null, ref: null, version: null, problems };
  }

  if (explicitKey) {
    problems.push({
      code: 'explicit-key-reference',
      message: `\`${value}\` uses YAML's explicit-key form; write the step as \`uses: owner/repo@<sha> # vX.Y.Z\` so the immutable-reference policy can read it.`,
    });

    return { kind: 'invalid', action: null, ref: null, version: null, problems };
  }

  if (flowMapping) {
    problems.push({
      code: 'flow-mapping-reference',
      message: `\`${value}\` puts \`uses\` inside a YAML flow mapping; rewrite the step in block style so each \`uses:\` starts its own line and the immutable-reference policy can read it.`,
    });

    return { kind: 'invalid', action: null, ref: null, version: null, problems };
  }

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

  // `$/` is GitHub's self-repository reference: it resolves to the running
  // commit, so it is immutable by construction. The docs are explicit that it
  // "must not include an `@{ref}` suffix".
  if (value.startsWith('$/')) {
    if (value.includes('@')) {
      problems.push({
        code: 'self-reference-with-ref',
        message: `Self reference \`${value}\` must not carry an \`@ref\`; a \`$/\` reference always resolves to the running commit.`,
      });
    }

    return { kind: 'self', action: value, ref: null, version: null, problems };
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

    // GitHub repository names are case-insensitive, so `Actions/checkout` and
    // `actions/checkout` run the same upstream code and must share a pin.
    const key = reference.action.toLowerCase();
    const group = byAction.get(key) ?? [];
    group.push(reference);
    byAction.set(key, group);
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
