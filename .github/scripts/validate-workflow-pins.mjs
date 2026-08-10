import { readFile, readdir } from 'node:fs/promises';
import { join, relative, sep } from 'node:path';

import { evaluateRepository, summarizeReferences } from './lib/workflow-pins.mjs';

const DEFINITION_PATTERN = /\.ya?ml$/;

function isDefinitionPath(relativePath) {
  const segments = relativePath.split(sep);

  if (segments[0] === 'workflows' && segments.length === 2) {
    return DEFINITION_PATTERN.test(segments[1]);
  }

  if (segments[0] === 'actions' && segments.length >= 2) {
    return /^action\.ya?ml$/.test(segments[segments.length - 1]);
  }

  return false;
}

async function collectDefinitionFiles(root) {
  let entries;

  try {
    entries = await readdir(root, { recursive: true, withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return [];
    }

    throw error;
  }

  const files = [];

  for (const entry of entries) {
    if (!entry.isFile()) {
      continue;
    }

    const absolutePath = join(entry.parentPath ?? entry.path, entry.name);
    const relativePath = relative(root, absolutePath);

    if (!isDefinitionPath(relativePath)) {
      continue;
    }

    files.push({
      path: join(root, relativePath).split(sep).join('/'),
      source: await readFile(absolutePath, 'utf8'),
    });
  }

  return files;
}

async function main() {
  const root = process.env.WORKFLOW_PINS_ROOT ?? '.github';
  const files = await collectDefinitionFiles(root);
  const { references, findings, ok } = evaluateRepository(files, { root });

  const summary = [
    `Scanned ${files.length} definition file(s) under ${root}`,
    `Checked ${references.length} \`uses:\` reference(s) (${summarizeReferences(references) || 'none'})`,
  ];

  if (!ok) {
    for (const finding of findings) {
      console.error(`::error file=${finding.path},line=${finding.line}::${finding.message}`);
    }

    console.log(summary.join('\n'));
    console.log(`Immutable-reference policy failed with ${findings.length} finding(s).`);
    process.exitCode = 1;
    return;
  }

  console.log(summary.join('\n'));
  console.log('Every `uses:` reference is immutable and carries an upstream version comment.');
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exitCode = 1;
});
