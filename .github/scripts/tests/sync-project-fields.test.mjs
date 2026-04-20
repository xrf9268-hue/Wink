import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('sync-project-fields does not use stale projectTitle logging references', async () => {
  const source = await readFile(
    new URL('../sync-project-fields.mjs', import.meta.url),
    'utf8',
  );

  assert.equal(
    source.includes('Added issue #${issueNumber} to project "${projectTitle}".'),
    false,
    'sync-project-fields.mjs still uses stale add-item projectTitle logging',
  );
  assert.equal(
    source.includes('Project sync complete for "${projectTitle}" with ${updates} field update(s).'),
    false,
    'sync-project-fields.mjs still uses stale completion projectTitle logging',
  );
});
