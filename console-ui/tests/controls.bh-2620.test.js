import test from 'node:test';
import assert from 'node:assert/strict';
import { CONTROL_KINDS, controlBody, controlHref } from '../src/lib/controls.js';

const byKind = (k) => CONTROL_KINDS.find((d) => d.kind === k);

// The five kinds (BH-4082 added projects), their GET/PUT paths, list keys and identifying fields, as
// the worker routes in worker/jobs/src/routes/*.js answer and read them.
const SHAPES = {
  'review-gate': { path: '/api/review-gate', putPath: '/api/review-gate/thresholds', listKey: 'thresholds', keyFields: ['scope'],
    editFields: [['window_days', 'int'], ['min_merges', 'int'], ['tighten_rate', 'num'], ['clear_rate', 'num'], ['note', 'text']] },
  rules: { path: '/api/rules', putPath: '/api/rules', listKey: 'rules', keyFields: ['scope', 'selector', 'kind'],
    editFields: [['max_concurrent', 'int'], ['note', 'text']] },
  'retry-policies': { path: '/api/retry-policies', putPath: '/api/retry-policies', listKey: 'policies', keyFields: ['lane'],
    editFields: [['max_attempts', 'int'], ['backoff_seconds', 'int'], ['escalate_allowed', 'int'], ['note', 'text']] },
  contracts: { path: '/api/contracts', putPath: '/api/contracts', listKey: 'contracts', keyFields: ['phase'],
    editFields: [['artifact_kind', 'text'], ['pattern', 'text'], ['note', 'text']] },
  projects: { path: '/api/projects', putPath: '/api/projects', listKey: 'projects', keyFields: ['project'],
    editFields: [['repo', 'text'], ['prod_url', 'text'], ['board_api_prefix', 'text'], ['cron_offset', 'int'],
      ['box', 'text'], ['tailnet_ip', 'text'], ['note', 'text']] },
};

test('C1 five kinds, in order, with path, listKey and keyFields', () => {
  assert.deepEqual(CONTROL_KINDS.map((d) => d.kind), ['review-gate', 'rules', 'retry-policies', 'contracts', 'projects']);
  for (const [kind, s] of Object.entries(SHAPES)) {
    const d = byKind(kind);
    assert.equal(d.path, s.path, kind);
    assert.equal(d.listKey, s.listKey, kind);
    assert.deepEqual(d.keyFields, s.keyFields, kind);
    assert.equal(typeof d.title, 'string');
    assert.ok(d.title.length > 0, kind + ' title');
  }
});

test('C1 putPath: review-gate writes to /thresholds, every other kind to its path', () => {
  assert.equal(byKind('review-gate').putPath, '/api/review-gate/thresholds');
  for (const d of CONTROL_KINDS.filter((x) => x.kind !== 'review-gate')) assert.equal(d.putPath, d.path, d.kind);
});

test('C1 editFields names and types', () => {
  for (const [kind, s] of Object.entries(SHAPES)) {
    assert.deepEqual(byKind(kind).editFields.map((f) => [f.name, f.type]), s.editFields, kind);
  }
});

test('C1 rules scope is a select fed by the response scopes', () => {
  assert.deepEqual(byKind('rules').keySelect, { scope: 'scopes' });
  for (const d of CONTROL_KINDS.filter((x) => x.kind !== 'rules')) assert.equal(d.keySelect, undefined, d.kind);
});

test('C1 no defaults: edit fields are shapes only', () => {
  let n = 0;
  for (const d of CONTROL_KINDS) {
    for (const f of d.editFields) { n++; assert.deepEqual(Object.keys(f).sort(), ['name', 'type'], d.kind + '.' + f.name); }
  }
  assert.equal(n, 21);
});

test('C1 href', () => {
  assert.equal(controlHref('rules'), '/controls/rules');
  assert.deepEqual(CONTROL_KINDS.map((d) => controlHref(d.kind)),
    ['/controls/review-gate', '/controls/rules', '/controls/retry-policies', '/controls/contracts', '/controls/projects']);
});

test('C1 rowKey/rowName', () => {
  const rules = byKind('rules');
  const r = { scope: 'project', selector: 'x', kind: '*', max_concurrent: 2 };
  assert.equal(rules.rowKey(r), '["project","x","*"]');
  assert.equal(rules.rowName(r), 'project / x / *');
  assert.notEqual(rules.rowKey({ scope: 'a / b', selector: 'c', kind: '*' }), rules.rowKey({ scope: 'a', selector: 'b / c', kind: '*' }));
  assert.equal(byKind('retry-policies').rowName({ lane: 'build' }), 'build');
});

test('C2 coerces int and num fields and carries the trimmed reason', () => {
  const out = controlBody(byKind('review-gate'),
    { scope: '*', window_days: '5', min_merges: '3', tighten_rate: '0.3', clear_rate: '0.1', note: 'n' }, '  tune  ');
  assert.equal('error' in out, false);
  assert.deepEqual(out.body, { scope: '*', window_days: 5, min_merges: 3, tighten_rate: 0.3, clear_rate: 0.1, note: 'n', reason: 'tune' });
});

test('C2 numbers read back from a row stay numbers', () => {
  const out = controlBody(byKind('retry-policies'),
    { lane: 'build', max_attempts: 3, backoff_seconds: 0, escalate_allowed: 1, note: null }, 'r');
  assert.deepEqual(out, { body: { lane: 'build', max_attempts: 3, backoff_seconds: 0, escalate_allowed: 1, note: '', reason: 'r' } });
});

test('C2 text fields pass through and missing text is blank', () => {
  assert.deepEqual(controlBody(byKind('contracts'), { phase: 'build', artifact_kind: 'pr' }, ' r '),
    { body: { phase: 'build', artifact_kind: 'pr', pattern: '', note: '', reason: 'r' } });
});

test('C3 blank reason: error, no body', () => {
  const draft = { phase: 'build', artifact_kind: 'pr' };
  assert.ok(controlBody(byKind('contracts'), draft, 'r').body, 'same draft with a reason builds a body');
  for (const reason of ['', '  ', undefined, null]) {
    const out = controlBody(byKind('contracts'), draft, reason);
    assert.equal(typeof out.error, 'string', JSON.stringify(reason));
    assert.equal('body' in out, false, JSON.stringify(reason));
  }
});

test('C3 blank key field: error naming it, no body', () => {
  const out = controlBody(byKind('rules'), { scope: 'project', selector: '  ', kind: '*', max_concurrent: '2' }, 'r');
  assert.match(out.error, /selector/);
  assert.equal('body' in out, false);
  const missing = controlBody(byKind('retry-policies'), { max_attempts: '3', backoff_seconds: '1', escalate_allowed: '0' }, 'r');
  assert.match(missing.error, /lane/);
  assert.equal('body' in missing, false);
});

test('C3 non-numeric or blank int/num: error, no body (blank never becomes 0)', () => {
  const base = { scope: '*', window_days: '5', min_merges: '3', tighten_rate: '0.3', clear_rate: '0.1', note: '' };
  const cases = [
    ['window_days', 'abc'], ['window_days', '5.5'], ['min_merges', ''], ['min_merges', '  '],
    ['tighten_rate', 'x'], ['clear_rate', ''], ['clear_rate', 'Infinity'], ['window_days', 'NaN'],
  ];
  for (const [f, v] of cases) {
    const out = controlBody(byKind('review-gate'), { ...base, [f]: v }, 'r');
    assert.match(out.error || '', new RegExp(f), f + '=' + JSON.stringify(v));
    assert.equal('body' in out, false, f + '=' + JSON.stringify(v));
  }
});

test('controlBody tolerates a descriptor without field arrays', () => {
  assert.deepEqual(controlBody({}, {}, 'r'), { body: { reason: 'r' } });
});
