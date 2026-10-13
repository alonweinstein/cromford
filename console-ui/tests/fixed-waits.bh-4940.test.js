import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { waitFor } from './helpers/wait-for.js';

// BH-4940: B9 waited a fixed 150 ms for a mounted route to render, and a loaded
// hub box missed it, which refused the Pages deploy. A test waits on the
// condition it asserts (./helpers/wait-for.js) or settles by turns
// (./helpers/settle.js), never on a wall-clock render barrier. A fixed wait
// that is not a render barrier (an observation window, a test of flush itself)
// carries `// fixed-wait: ok <reason>` on its line.

const DIR = fileURLToPath(new URL('./', import.meta.url));
const SELF = fileURLToPath(import.meta.url);
const SKIP = new Set(['helpers', 'node_modules']);

const FIXED_TIMER = /setTimeout\(\s*[A-Za-z_$][\w$]*\s*,\s*[1-9][\d_]*\s*\)/;
const FIXED_FLUSH = /\bawait\s+flush\(\s*[1-9]/;
const ALLOWED = /\/\/ fixed-wait: ok \S/;

function fixedWaits(src) {
  return src.split('\n').flatMap((line, i) =>
    (FIXED_TIMER.test(line) || FIXED_FLUSH.test(line)) && !ALLOWED.test(line) ? [i + 1] : []);
}

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return SKIP.has(e.name) ? [] : walk(p);
    return /\.m?js$/.test(e.name) && p !== SELF ? [p] : [];
  });
}

test('W1 no unannotated fixed-ms wait in console-ui/tests', () => {
  const files = walk(DIR).sort();
  const names = files.map((f) => relative(DIR, f));
  assert.ok(files.length > 100, `expected more than 100 test files, scanned ${files.length}`);
  assert.ok(names.includes('building-now.bh-3569.test.js'), 'the B9 suite was not scanned');
  const hits = files.flatMap((f) => fixedWaits(readFileSync(f, 'utf8')).map((n) => `${relative(DIR, f)}:${n}`));
  assert.deepEqual(hits, [], 'fixed-ms waits (wait on the condition with ./helpers/wait-for.js, '
    + 'or annotate `// fixed-wait: ok <reason>`): ' + hits.join(', '));
});

test('W2 the scanner flags fixed waits and passes the rest', () => {
  // Built by concatenation so this file never matches its own scan.
  const st = 'set' + 'Timeout(';
  assert.deepEqual(fixedWaits('await new Promise((r) => ' + st + 'r, 150));'), [1]);
  assert.deepEqual(fixedWaits('const a = 1;\nawait new Promise((resolve) => ' + st + 'resolve, 20));'), [2]);
  assert.deepEqual(fixedWaits('await ' + 'flush(100);'), [1]);
  assert.deepEqual(fixedWaits('await new Promise((r) => ' + st + 'r, 0));'), []);
  assert.deepEqual(fixedWaits(st + '() => busyWait(120), 1);'), []);
  assert.deepEqual(fixedWaits('await ' + 'flush();'), []);
  assert.deepEqual(fixedWaits('await new Promise((r) => ' + st + 'r, 300)); // fixed-wait: ok an observation window'), []);
  assert.deepEqual(fixedWaits('await new Promise((r) => ' + st + 'r, 300)); // fixed-wait: ok '), [1]);
});

test('W3 waitFor returns once the condition holds and names what never appeared', async () => {
  let n = 0;
  await waitFor(() => ++n === 3, 'the third poll');
  assert.equal(n, 3);
  await assert.rejects(waitFor(() => false, 'the count element', () => 'render: empty', 2), {
    message: 'waitFor: the count element never appeared within 2 polls of 10 ms. render: empty'
  });
});
