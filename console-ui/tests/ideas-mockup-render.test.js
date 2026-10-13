import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { MockupCell } from '../src/screens/Ideas.js';

// The predicate being right is not the same as the cell being clickable. This
// renders the real cell and reads the HTML back, so "you can get to the mockup
// from the list" is something that was observed rather than assumed.

const cell = (row) => render(h(MockupCell, { row }));

test('a posted proposal offers the live mockup on the client board, in a new tab', () => {
  const out = cell({
    project: 'project-3', slug: 'roster',
    mockup_url: 'https://os.project-3.example/board/mockups/9', shots: 2
  });
  assert.ok(out.includes('href="https://os.project-3.example/board/mockups/9"'), out);
  assert.ok(out.includes('target="_blank"'), out);
  assert.ok(out.includes('rel="noopener noreferrer"'), out);
  // and the shots are still one click away, on the idea's own page
  assert.ok(out.includes('href="/ideas/project-3/roster#mockup"'), out);
  assert.ok(out.includes('2 SHOTS'), out);
});

test('a drafted proposal with no board link still opens its shots on the idea page', () => {
  const out = cell({ project: 'project-4', slug: 'gate', shots: 1 });
  assert.ok(out.includes('href="/ideas/project-4/gate#mockup"'), out);
  assert.ok(/1 SHOT[^S]/.test(out), out);
  assert.ok(!out.includes('target="_blank"'), out);
});

test('a mockup_url that is not https is never rendered as a link', () => {
  const out = cell({ project: 'project-4', slug: 'x', mockup_url: 'javascript:alert(1)', shots: 0 });
  assert.ok(!out.includes('javascript:'), out);
  assert.ok(!/<a\s/.test(out), out);
});

test('no mockup renders the honest empty state, and says which kind of empty', () => {
  const out = cell({ project: 'project-4', slug: 'idea-only', shots: 0 });
  assert.ok(!/<a\s/.test(out), out);
  assert.ok(out.includes('—'), out);
  assert.ok(/title="[^"]*drafting stage[^"]*"/.test(out), out);
});
