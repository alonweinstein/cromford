import { useState } from 'preact/hooks';
import { html, Link } from '../../router.js';
import { api } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { useConfirm } from '../../ui/Modal.js';
import { PauseReasonForm } from '../../ui/PauseForms.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../../ui/primitives.js';
import { panelState } from '../../lib/restore-lab.js';
import { planView, planRows, laneHref, requestApply, runsView, confirmCopy, SEED_RUNS_LIMIT } from '../../lib/registry-seed.js';

// The SEED REGISTRY panel of the HUB screen (BH-2521, slice BH-2677): what the
// registry seed would insert, update and prune, an APPLY behind the in-app
// dialog, and the recent applies. It talks to the worker only through api.js.
//
// Both reads load once on mount and on REFRESH; there is no polling. A plan
// without plan_fp (the worker before BH-2521's worker slice deploys) is a load
// error, not "Nothing to apply".

const NA = html`<span class="na">—</span>`;
const orNa = (v) => (v === null || v === undefined || v === '' ? NA : v);
const num = (v) => (typeof v === 'number' ? v : NA);
const TONE = { ok: 'tag tag--green', warn: 'tag tag--warn', bad: 'tag tag--bad' };
const note = (text) => html`<p class="section__note" style="margin:6px 0 0">${text}</p>`;
const refreshNote = (error) => note(`refresh failed: ${error.message}; showing the last answer`);

function KeyCell({ k }) {
  const href = laneHref(k);
  const style = 'overflow-wrap:anywhere';
  return href ? html`<${Link} to=${href} class="cell-name" style=${style}>${k}<//>` : html`<span style=${style}>${k}</span>`;
}

const PLAN_COLUMNS = [
  { key: 'key', label: 'KEY', cell: (r) => html`<${KeyCell} k=${r.key} />` },
  { key: 'action', label: 'ACTION', cell: (r) => r.action },
  { key: 'from', label: 'FROM', cell: (r) => orNa(r.from) },
  { key: 'to', label: 'TO', cell: (r) => orNa(r.to) },
];

// A run's stored detail: the failed apply's error, the keys behind the CHANGED
// and PRUNED counts (lane keys link to their settings view), plan_fp and the
// finish time. A list the worker did not send is unknown, not empty.
function KeyList({ keys }) {
  if (!Array.isArray(keys)) return NA;
  if (!keys.length) return 'none';
  return html`<ul style="margin:0;padding-left:16px">${keys.map((k) => html`<li key=${k}><${KeyCell} k=${k} /></li>`)}</ul>`;
}

function RunDetail({ run }) {
  const rows = [
    ['error', orNa(run.error)],
    ['changed_keys', html`<${KeyList} keys=${run.changed_keys} />`],
    ['pruned_keys', html`<${KeyList} keys=${run.pruned_keys} />`],
    ['plan_fp', orNa(run.plan_fp)],
    ['finished_at', orNa(run.finished_at)],
  ];
  return html`
    <dl class="seed-registry__detail"
      style="display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 12px;margin:10px 0 0;font-size:var(--fs-xs)">
      <dt style="color:var(--muted)">run</dt><dd style="margin:0">#${run.id}</dd>
      ${rows.map(([k, v]) => html`
        <dt key=${`t-${k}`} style="color:var(--muted)">${k}</dt>
        <dd key=${`d-${k}`} style="margin:0;min-width:0;overflow-wrap:anywhere;word-break:break-all">${v}</dd>`)}
    </dl>`;
}

// STATUS sorts the displayed value, not the raw status. WHEN opens the run's
// detail.
const runColumns = (openId, onToggle) => [
  { key: 'started_at', label: 'WHEN', cell: (r) => html`
    <button type="button" class="cell-name" aria-expanded=${openId === r.id ? 'true' : 'false'}
      style="background:none;border:0;padding:0;font:inherit;cursor:pointer;text-align:left"
      onClick=${() => onToggle(r.id)}>${orNa(r.started_at)}</button>` },
  { key: 'actor', label: 'ACTOR', cell: (r) => orNa(r.actor) },
  { key: 'display', label: 'STATUS', cell: (r) => r.display },
  { key: 'changed', label: 'CHANGED', cell: (r) => orNa(r.changed) },
  { key: 'pruned', label: 'PRUNED', cell: (r) => orNa(r.pruned) },
];

export function SeedRegistryView({ plan, planError, runs, runsError, busy, outcome, onApply, onRefresh, openId = null, onToggle = () => {} }) {
  const rows = plan ? planRows(plan) : [];
  const planState = panelState({ view: plan && { rows }, error: planError });
  const runsState = panelState({ view: runs, error: runsError });
  const blocked = !plan || plan.pending === 0 || busy;
  const p = plan || {};
  const open = runs && openId !== null ? runs.rows.find((r) => r.id === openId) : null;
  const count = (a) => (Array.isArray(a) ? a.length : NA);

  return html`<${Section} title="SEED REGISTRY">
    <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:10px">
      <span class="section__note">${count(p.insert)} insert · ${count(p.update)} update · ${count(p.prune)} prune · ${num(p.operator_owned)} operator-owned · ${num(p.unchanged)} unchanged</span>
      <button type="button" class="btn btn--sm" onClick=${onRefresh}>REFRESH</button>
      <button type="button" class="btn btn--warn" disabled=${blocked} onClick=${onApply}>APPLY</button>
      ${outcome ? html`<span class=${TONE[outcome.tone]} role="status" style="overflow-wrap:anywhere">${outcome.text}</span>` : null}
    </div>
    ${planState === 'loading' ? html`<${Skeleton} rows=${3} />` : null}
    ${planState === 'error' ? html`<${ErrorBox} error=${planError} onRetry=${onRefresh} />` : null}
    ${planState === 'empty' ? html`<${Empty} title="Nothing to apply" />` : null}
    ${planState === 'rows' ? html`<${SortableTable} columns=${PLAN_COLUMNS} rows=${rows} rowKey=${(r) => r.action + r.key} defaultSort="key" />` : null}
    ${planError && plan ? refreshNote(planError) : null}

    <h3 class="section__title" style="display:block;margin:16px 0 8px">RECENT APPLIES</h3>
    ${runsState === 'loading' ? html`<${Skeleton} rows=${2} />` : null}
    ${runsState === 'error' ? html`<${ErrorBox} error=${runsError} onRetry=${onRefresh} />` : null}
    ${runsState === 'empty' ? html`<${Empty} title="No applies yet" />` : null}
    ${runsState === 'rows' ? html`
      <${SortableTable} columns=${runColumns(openId, onToggle)} rows=${runs.rows} rowKey=${(r) => r.id} defaultSort="started_at" defaultDir="desc" />
      ${runs.truncated ? note(`showing the last ${SEED_RUNS_LIMIT} applies`) : null}
      ${open ? html`<${RunDetail} run=${open} />` : null}` : null}
    ${runsError && runs ? refreshNote(runsError) : null}
  <//>`;
}

// A payload that fails its view is a load error, same as a rejected fetch.
function viewOf(data, error, toView) {
  if (!data) return [null, error];
  try { return [toView(data), error]; } catch (e) { return [null, e]; }
}

export function SeedRegistryPanel() {
  const planApi = useApi(() => api.seedPlan(), []);
  const runsApi = useApi(() => api.seedRuns(), []);
  const [dialog, ask] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState(null);
  const [openId, setOpenId] = useState(null);

  const [plan, planError] = viewOf(planApi.data, planApi.error, planView);
  const [runs, runsError] = viewOf(runsApi.data, runsApi.error, (d) => runsView(d));
  const reload = () => { planApi.reload(); runsApi.reload(); };

  const onApply = async () => {
    if (busy || !plan || plan.pending === 0) return;
    // busy disables APPLY while the dialog and the POST are in flight, so a
    // double click cannot send two applies.
    setBusy(true);
    try {
      // BH-2995: the dialog carries a required REASON; APPLY stays disabled
      // until it is filled.
      const renderForm = (form, setBlocked) =>
        html`<${PauseReasonForm} text=${confirmCopy(plan)} value=${form} onBlocked=${setBlocked} />`;
      const out = await requestApply({ apiObj: api, plan, confirm: ask, reload, renderForm });
      if (out) setOutcome(out);
    } finally {
      setBusy(false);
    }
  };

  return html`<div>
    <${SeedRegistryView} plan=${plan} planError=${planError} runs=${runs} runsError=${runsError}
      busy=${busy} outcome=${outcome} onApply=${onApply} onRefresh=${reload}
      openId=${openId} onToggle=${(id) => setOpenId((cur) => (cur === id ? null : id))} />
    ${dialog}
  </div>`;
}
