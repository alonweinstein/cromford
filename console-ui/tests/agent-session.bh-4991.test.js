// BH-4991 (BH-4947 wave 2): the agent session panel on the ticket page.
//
// The feed is the stage's transcript (bin/transcript-render.sh's text: `[ts]
// USER`, `[ts] ASSISTANT (model)`, `  → Tool: arg`, `  ← result`) parsed into
// turns. The live marker shows only while the stage runs. "Step in" is a live
// composer (BH-5839): its send path is driven in steer-composer.bh-5839.test.js.
// (File name per the scope update: console-ui runs tests/*.test.js only.)

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/t/BH-4991', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { render } = await import('preact-render-to-string');
const { parseTranscript, sessionLive } = await import('../src/lib/ticket-detail.js');
const { AgentSession } = await import('../src/ui/AgentSession.js');

const visible = (html) => html.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&gt;/g, '>').replace(/\s+/g, ' ');

const BODY = [
  '# transcript: session abc · claude-opus-5-5',
  '',
  '[20:01:02] USER',
  'Build BH-4991.',
  '',
  '[20:01:10] ASSISTANT (claude-opus-5-5)',
  'Reading the stub first.',
  '  → Bash: sed -n 1,40p console-ui/src/screens/Ticket.js',
  '  ← // /t/<KEY> (BH-4990): one ticket\'s jobs.',
  '',
  '[20:01:20] ASSISTANT (claude-opus-5-5)',
  '  · [thinking]',
  'The stub lists jobs. Replacing it.',
  `  → Read: ${'console-ui/src/lib/'.repeat(12)}line.js`
].join('\n');

test('A1 the transcript parses into agent, tool, result and prompt turns, in order', () => {
  const turns = parseTranscript(BODY);
  assert.deepEqual(turns.map((t) => t.who), ['human', 'agent', 'tool', 'result', 'agent', 'tool']);
  assert.equal(turns[0].at, '20:01:02');
  assert.equal(turns[1].text, 'Reading the stub first.');
  assert.equal(turns[2].text, 'Bash: sed -n 1,40p console-ui/src/screens/Ticket.js');
  assert.equal(turns[4].text, 'The stub lists jobs. Replacing it.', 'a thinking marker is not a turn');
  assert.deepEqual(parseTranscript(''), []);
  assert.deepEqual(parseTranscript(null), []);
});

test('A2 the feed renders the turns in order; a long tool line is folded, a short one is not', () => {
  const out = render(h(AgentSession, { live: false, stage: 'Review', feed: parseTranscript(BODY) }));
  const v = visible(out);
  assert.ok(v.indexOf('Build BH-4991.') < v.indexOf('Reading the stub first.'));
  assert.ok(v.indexOf('Reading the stub first.') < v.indexOf('The stub lists jobs.'));
  assert.match(out, /<details class="turn__fold"><summary>Read: console-ui\/src\/lib\//);
  assert.match(out, /class="turn turn--tool"[^>]*>[\s\S]*?<code>Bash: sed -n 1,40p/);
  const empty = render(h(AgentSession, { live: false, stage: 'Plan', feed: [] }));
  assert.match(visible(empty), /No session text yet\./, 'an empty feed says why, never a blank box');
});

test('A3 the live marker shows only while the stage runs', () => {
  assert.equal(sessionLive({ status: 'running' }, [{ id: 1, finished_at: null }]), true);
  assert.equal(sessionLive({ status: 'running' }, [{ id: 1, finished_at: '2026-10-09T20:00:00Z' }]), false, 'no open phase');
  assert.equal(sessionLive({ status: 'done' }, [{ id: 1, finished_at: null }]), false, 'the job is not running');
  const on = render(h(AgentSession, { live: true, stage: 'Review', feed: [] }));
  assert.match(on, /class="agent__live"/);
  assert.match(visible(on), /working/);
  const off = render(h(AgentSession, { live: false, stage: 'Review', feed: [] }));
  assert.doesNotMatch(off, /class="agent__live"/);
  assert.doesNotMatch(visible(off), /working/);
  assert.match(visible(off), /idle/);
});

test('A4 "Step in" is a live composer: one enabled text box, three modes and one SEND button, never "coming soon"', () => {
  const job = { id: 'build-cromford-BH-4991-1', kind: 'build', status: 'running' };
  const out = render(h(AgentSession, { live: true, stage: 'Review', feed: [], project: 'cromford', ticket: 'BH-4991', job, notes: [] }));
  assert.doesNotMatch(visible(out), /coming soon/i);
  const boxes = out.match(/<textarea\b[^>]*>/g) || [];
  assert.equal(boxes.length, 1, 'one text box');
  assert.doesNotMatch(boxes[0], /\bdisabled\b/, 'the text box is enabled');
  const radios = out.match(/<input\b[^>]*type="radio"[^>]*>/g) || [];
  assert.equal(radios.length, 3, 'three modes');
  for (const r of radios) assert.doesNotMatch(r, /\bdisabled\b/, `a running build enables every mode: ${r}`);
  const buttons = out.match(/<button\b[^>]*>[\s\S]*?<\/button>/g) || [];
  assert.equal(buttons.length, 1, 'one button');
  assert.match(visible(buttons[0]), /^\s*SEND\s*$/);
});

test('A5 no native dialogs on the ticket page', () => {
  for (const f of ['../src/ui/AgentSession.js', '../src/screens/Ticket.js']) {
    const src = readFileSync(new URL(f, import.meta.url), 'utf8');
    assert.doesNotMatch(src, /\b(window|globalThis|self)\.(alert|confirm|prompt)\b/, `${f} calls a native dialog`);
    assert.doesNotMatch(src, /(^|[^.\w])(alert|prompt|confirm)\s*\(/m, `${f} calls a native dialog`);
  }
});
