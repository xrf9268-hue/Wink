import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const infoPlist = await readFile(
  new URL('../../../Sources/Wink/Resources/Info.plist', import.meta.url),
  'utf8',
);
const ciWorkflow = await readFile(new URL('../../workflows/ci.yml', import.meta.url), 'utf8');

test('Info.plist declares the supported macOS 15 minimum system version', () => {
  assert.match(
    infoPlist,
    /<key>LSMinimumSystemVersion<\/key>\s*<string>15\.0<\/string>/,
  );
});

test('CI verifies the packaged app minimum system version', () => {
  assert.match(ciWorkflow, /Print :LSMinimumSystemVersion/);
  assert.match(ciWorkflow, /= "\$MACOS_MINIMUM_SYSTEM_VERSION"/);
});
