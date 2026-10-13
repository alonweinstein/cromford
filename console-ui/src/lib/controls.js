// The console CONTROLS lib (BH-2513): the editable config kinds as field
// shapes, the PUT body one edit sends, and the route of each kind's screen.
// Shapes only: no thresholds, defaults or option lists live here. The worker
// routes (worker/jobs/src/routes/*.js) own every value and validate every PUT.
// Labels, meanings and explainers are display copy (BH-3558.1): they say what
// a field is, never what it should be set to.

import { plainLabel } from './labels.js';

/**
 * One editable config kind.
 * @typedef {Object} ControlKind
 * @property {string} kind        the console slug: the screen lives at /controls/<kind>
 * @property {string} title
 * @property {string} path        GET path listing the rows
 * @property {string} putPath     PUT path writing one row
 * @property {string} listKey     key of the rows array in the GET response
 * @property {string[]} keyFields fields identifying a row
 * @property {Object<string, string>} [keySelect] key field -> key of the GET
 *   response array holding that field's options (rendered as a select)
 * @property {{name: string, type: 'int'|'num'|'text'|'select', options?: string[]}[]} editFields
 * @property {Object<string, {label?: string, meaning?: string, display?: 'percent'|'yesno'|'seconds'|'cap'}>} fieldInfo
 *   key or edit field -> its display copy. Kept apart from the shapes, which
 *   stay {name, type} (controls.bh-2620 C1), and from keyFields, which
 *   controlBody and the PUT read as plain names.
 * @property {string} explainer   what the kind controls, in plain sentences
 * @property {string} auditKind   the config_changes kind its edits are logged under
 * @property {boolean} [showsCeilings] the page also shows the hub's BUILD CEILINGS
 * @property {(r: Object) => string} rowKey    stable, unambiguous row identity
 * @property {(r: Object) => string} rowName   key values for display
 * @property {(r: Object) => string} auditName the row's config_changes name (keys joined by /)
 */

function describe(d) {
  const keys = d.keyFields;
  return Object.freeze({
    ...d,
    putPath: d.putPath || d.path,
    rowKey: (r) => JSON.stringify(keys.map((f) => r[f] ?? null)),
    rowName: (r) => keys.map((f) => String(r[f] ?? '')).join(' / '),
    // The worker logs every edit under this name (routes/rules.js
    // `${scope}/${selector}/${kind}`, the other three their single key).
    auditName: (r) => keys.map((f) => String(r[f] ?? '')).join('/'),
  });
}

const f = (name, type) => ({ name, type });

/** @type {ControlKind[]} */
export const CONTROL_KINDS = Object.freeze([
  describe({
    kind: 'review-gate', title: 'Review gate thresholds', auditKind: 'review_gate_threshold',
    path: '/api/review-gate', putPath: '/api/review-gate/thresholds', listKey: 'thresholds',
    explainer: 'Over the last window, once a scope has at least the minimum merges, review tightens when the failure rate passes the tighten rate and relaxes again below the clear rate.',
    keyFields: ['scope'],
    editFields: [f('window_days', 'int'), f('min_merges', 'int'), f('tighten_rate', 'num'), f('clear_rate', 'num'), f('note', 'text')],
    fieldInfo: {
      scope: { label: 'scope', meaning: 'the repo or tier this threshold applies to' },
      window_days: { label: 'window', meaning: 'how many days of merges count' },
      min_merges: { label: 'minimum merges', meaning: 'fewer merges than this in the window and the gate never moves' },
      tighten_rate: { label: 'tighten rate', meaning: 'failure rate at which review tightens', display: 'percent' },
      clear_rate: { label: 'clear rate', meaning: 'failure rate below which it relaxes again', display: 'percent' },
      note: { label: 'note' },
    },
  }),
  describe({
    kind: 'rules', title: 'Concurrency rules', auditKind: 'concurrency_rule', showsCeilings: true,
    path: '/api/rules', listKey: 'rules',
    explainer: 'Most claims allowed at once for this selector. ticket/*/* = one claim per ticket, fleet-wide. This does not cap how many tickets build at once.',
    keyFields: ['scope', 'selector', 'kind'], keySelect: { scope: 'scopes' },
    editFields: [f('max_concurrent', 'int'), f('note', 'text')],
    fieldInfo: {
      scope: { label: 'scope', meaning: 'what one claim is counted against: repo, box or ticket' },
      selector: { label: 'selector', meaning: 'which repo, box or ticket; * means every one' },
      kind: { label: 'job kind', meaning: 'build, triage, fix and so on; * means all' },
      max_concurrent: { label: 'most at once', meaning: 'claims allowed at the same time; 0 blocks every claim', display: 'cap' },
      note: { label: 'note' },
    },
  }),
  describe({
    kind: 'retry-policies', title: 'Retry policies', auditKind: 'retry_policy',
    path: '/api/retry-policies', listKey: 'policies',
    explainer: 'How many times a lane\'s failed job is tried again, how long to wait between tries, and whether it may escalate to a person when tries run out.',
    keyFields: ['lane'],
    editFields: [f('max_attempts', 'int'), f('backoff_seconds', 'int'), f('escalate_allowed', 'int'), f('note', 'text')],
    fieldInfo: {
      lane: { label: 'lane', meaning: 'the lane whose failed jobs this policy retries' },
      max_attempts: { label: 'most tries', meaning: 'tries before the job is given up on' },
      backoff_seconds: { label: 'wait between tries', meaning: 'seconds between one try and the next', display: 'seconds' },
      escalate_allowed: { label: 'may escalate', meaning: 'whether a person is asked once tries run out (1 yes, 0 no)', display: 'yesno' },
      note: { label: 'note' },
    },
  }),
  describe({
    kind: 'contracts', title: 'Phase contracts', auditKind: 'phase_contract',
    path: '/api/contracts', listKey: 'contracts',
    explainer: 'What each pipeline phase must leave behind before the next phase starts, and the pattern its artifact must match.',
    keyFields: ['phase'],
    editFields: [f('artifact_kind', 'text'), f('pattern', 'text'), f('note', 'text')],
    fieldInfo: {
      phase: { label: 'phase', meaning: 'the pipeline phase this contract checks' },
      artifact_kind: { label: 'artifact', meaning: 'what the phase must leave behind' },
      pattern: { label: 'pattern', meaning: 'what that artifact must match' },
      note: { label: 'note' },
    },
  }),
  // BH-4082: the project registry. routes/projects.js validates every column,
  // because a later slice writes these rows into fleet.conf.
  describe({
    kind: 'projects', title: 'Projects', auditKind: 'project',
    path: '/api/projects', listKey: 'projects',
    explainer: 'The projects the harness watches: one row per project, the same columns as fleet.conf. Editing a row here does not change fleet.conf on the boxes yet.',
    keyFields: ['project'],
    editFields: [f('repo', 'text'), f('prod_url', 'text'), f('board_api_prefix', 'text'), f('cron_offset', 'int'),
      f('box', 'text'), f('tailnet_ip', 'text'), f('note', 'text')],
    fieldInfo: {
      project: { label: 'project', meaning: 'the harness-wide name, lowercase letters, digits and dashes' },
      repo: { label: 'GitHub repo', meaning: 'the repo builds open pull requests on, as owner/name' },
      prod_url: { label: 'production URL', meaning: 'where the app is served, starting https://; blank or - for none' },
      board_api_prefix: { label: 'board API path', meaning: 'where the app serves its product board API, starting /; blank or - for none' },
      cron_offset: { label: 'triage minute', meaning: 'triage runs at this minute past each ten, 0 to 9' },
      box: { label: 'box', meaning: 'the machine that watches this project; local means the hub itself' },
      tailnet_ip: { label: 'box address', meaning: 'the tailnet IPv4 address of that machine; blank if unknown' },
      note: { label: 'note' },
    },
  }),
]);

// A key or edit field's copy, or {} when it has none.
function info(desc, name) {
  return (desc.fieldInfo && desc.fieldInfo[name]) || {};
}

/** How the field's value is displayed ('percent', 'yesno', ...), or ''. */
export function fieldDisplay(desc, name) {
  return info(desc, name).display || '';
}

/** The field's plain label; an unlabelled field still never renders SNAKE_CASE. */
export function fieldLabel(desc, name) {
  return info(desc, name).label || plainLabel(name);
}

/** One sentence on what the field means, or '' when it needs none. */
export function fieldMeaning(desc, name) {
  return info(desc, name).meaning || '';
}

/**
 * A stored value as a person reads it. null/undefined/'' is null, so the
 * caller draws its own "nothing here" mark; a value the display cannot read
 * is shown as stored, never as NaN.
 */
export function displayValue(desc, name, v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  switch (info(desc, name).display) {
    case 'percent': return Number.isFinite(n) ? `${+(n * 100).toFixed(1)}%` : String(v);
    case 'yesno': return Number.isFinite(n) ? (n ? 'yes' : 'no') : String(v);
    case 'seconds': return `${v} s`;
    // checkRules (worker lib/core.js) admits a claim only while peers < max,
    // so a 0 refuses every claim in scope; "no limit" is no row at all.
    case 'cap': return n === 0 ? '0 (blocks every claim)' : String(v);
    default: return String(v);
  }
}

const blank = (v) => String(v ?? '').trim() === '';

/**
 * The PUT body for `desc` from the edited `draft` and the operator's `reason`:
 * `{body}`, or `{error}` and no body when the reason or a key field is blank or
 * an int/num field is blank or not a number. Blank is never read as 0. Ranges
 * are the worker's to check.
 */
export function controlBody(desc, draft, reason) {
  const why = String(reason ?? '').trim();
  if (!why) return { error: 'reason required' };
  const body = {};
  for (const k of desc.keyFields || []) {
    if (blank(draft[k])) return { error: k + ' required' };
    body[k] = String(draft[k]).trim();
  }
  for (const { name, type } of desc.editFields || []) {
    const v = draft[name];
    if (type === 'int' || type === 'num') {
      if (blank(v)) return { error: name + ' required' };
      const n = Number(v);
      if (type === 'int' && !Number.isInteger(n)) return { error: name + ' must be a whole number' };
      if (type === 'num' && !Number.isFinite(n)) return { error: name + ' must be a number' };
      body[name] = n;
    } else {
      body[name] = String(v ?? '');
    }
  }
  body.reason = why;
  return { body };
}

/** The console route of one kind's screen: /controls/<kind>. */
export function controlHref(kind) {
  return '/controls/' + encodeURIComponent(kind);
}
