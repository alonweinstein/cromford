import { useState, useMemo } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { laneHref } from '../lib/settings.js';
import { agoFromMinutes, minutesSince } from '../lib/format.js';
import {
  autohaltTrips, autohaltState, callGuardRows, resetFormState, makeResetAction, GUARD_LIMIT
} from '../lib/cost-breaker.js';

// BH-2331: what the cost breaker will do, which projects it has held, and
// the pre-call guard's keys with an audited RESET. The section owns the three
// reads and the reset; the view is a pure function of props so the tests
// render it server-side (same split as AccountUsage).
export function CostBreakerSection() {
  const settings = useApi(() => api.settings(), [], { intervalMs: 60000 });
  // BH-4153: only paused-* can be a trip. The unfiltered list is capped at 500
  // and lanedown-* rows sort ahead of paused-*, so a long lane outage would
  // push a trip off it and this card would say nothing is paused.
  const flags = useApi(() => api.coordFlagsAll({ prefix: 'paused-' }), [], { intervalMs: 60000 });
  const guard = useApi(() => api.callGuard(24), [], { intervalMs: 60000 });
  const [dialog, confirm] = useConfirm();
  const [pending, setPending] = useState(null);
  const [msg, setMsg] = useState(null);

  const onReset = useMemo(() => makeResetAction({
    confirm,
    reset: (args) => api.resetCallGuard(args),
    reload: guard.reload,
    onMsg: setMsg,
    onPending: setPending,
    renderForm: (row, form, setBlocked) => html`<${ResetForm} row=${row} value=${form} onBlocked=${setBlocked}/>`
  }), [confirm, guard.reload]);

  return html`
    <${CostBreakerView} settings=${settings} flags=${flags} guard=${guard}
      onReset=${onReset} pending=${pending} msg=${msg}/>
    ${dialog}`;
}

// The modal body. The reason input is the first field, so the Modal puts focus
// there on open and keeps it there (D39).
export function ResetForm({ row, value, onBlocked }) {
  const [reason, setReason] = useState(value.reason);
  const { hint } = resetFormState(reason);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <input class="knob__input" style="width:100%" type="text" value=${reason}
          placeholder="why this work may be paid for again"
          onInput=${(e) => {
            value.reason = e.target.value;
            setReason(e.target.value);
            if (onBlocked) onBlocked(resetFormState(e.target.value).blocked);
          }}/>
      </label>
      <span>
        Reset the call guard for <b>${row.project}</b> / <b>${row.stage}</b>? Its paid calls stop counting,
        so the next call for this fingerprint is allowed again. The worker records the reset with your reason.
      </span>
      <span style="overflow-wrap:anywhere;color:var(--faint)">fp ${row.fp}</span>
      ${hint ? html`<span style="color:var(--faint)">${hint}</span>` : null}
    </div>`;
}

const projectCell = (p) => html`<${Link} to=${`/p/${encodeURIComponent(p)}`} class="cell-name">${p}<//>`;
// Relative, with the timestamp itself on hover: a trip can be days old, and a
// bare clock time would not say which day.
const when = (iso) => (iso ? html`<span title=${iso}>${agoFromMinutes(minutesSince(iso))}</span>` : '—');

const tripColumns = [
  { key: 'project', label: 'PROJECT', cell: (r) => projectCell(r.project) },
  // BH-5526: HOLD stops new builds only; PAUSE is a breaker row from before
  // that change, which stopped triage and in-flight lanes too.
  {
    key: 'kind', label: 'KIND', sort: (r) => r.kind,
    cell: (r) => html`<span class=${r.kind === 'hold' ? 'tag tag--warn' : 'tag tag--bad'}>${r.kind === 'hold' ? 'HOLD' : 'PAUSE'}</span>`
  },
  { key: 'reason', label: 'WHY', cell: (r) => r.reason },
  { key: 'since', label: 'SINCE', cell: (r) => when(r.since) },
  { key: 'actor', label: 'ACTOR', cell: (r) => r.actor || '—' },
];

export function CostBreakerView({ settings, flags, guard, onReset, pending, msg }) {
  const state = autohaltState(settings && settings.data);
  const trips = autohaltTrips(flags && flags.data);
  const g = callGuardRows(guard && guard.data);

  const guardColumns = [
    { key: 'project', label: 'PROJECT', cell: (r) => projectCell(r.project) },
    { key: 'stage', label: 'STAGE', cell: (r) => r.stage },
    {
      key: 'fp', label: 'FINGERPRINT',
      cell: (r) => html`<span class="mono" style="overflow-wrap:anywhere">${r.fp}</span>`
    },
    { key: 'paid', label: 'PAID', align: 'right', cell: (r) => (r.paid === null ? '—' : r.paid) },
    {
      key: 'refused', label: 'REFUSED', align: 'right',
      cell: (r) => html`${r.refused === null ? '—' : r.refused}
        ${r.capHit ? html` <span class="tag tag--warn" title="the guard refused a call at its ceiling since the last reset">CAP HIT</span>` : null}
        ${r.resetAt ? html` <span style="color:var(--faint)">reset ${when(r.resetAt)}</span>` : null}`
    },
    { key: 'lastAt', label: 'LAST', cell: (r) => when(r.lastAt) },
    {
      key: 'reset', label: 'RESET', sort: null,
      cell: (r) => html`<button type="button" class="btn btn--sm btn--danger"
        disabled=${pending === r.key} onClick=${() => onReset(r)}>RESET</button>`
    },
  ];

  const autohaltLine = () => {
    const label = state.on === null ? 'UNKNOWN' : state.on ? 'ON' : 'OFF';
    const tag = state.on === null ? 'tag tag--warn' : state.on ? 'tag tag--green' : 'tag tag--bad';
    // BH-2397: the hub's published value, when there is one, is what the
    // breaker does; it already accounts for the env and the hub's flag file.
    const hub = state.source === 'hub';
    const source = hub
      ? (state.on === null ? 'the hub published a value this page cannot read'
        : html`hub, ${state.why}, as of ${when(state.asOf)}`)
      : state.on === null
        ? `the settings read failed${settings && settings.error ? ` (${settings.error.message || settings.error})` : ''}`
        : `the hub has not published its effective value; ${state.source === 'settings'
          ? `settings row ${state.raw}` : 'no usable settings row, registry default'}, which an env override or the hub flag file can overrule`;
    return html`
      <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:6px">
        <span class="section__note">AUTOHALT</span>
        <span class=${tag}>${label}</span>
        <span style="color:var(--faint)">${source}</span>
        <${Link} to=${laneHref('pipeline-health')}>change in Settings<//>
      </div>
      ${state.note ? html`<div class="footnote"><span style="color:var(--faint)">${state.note}</span></div>` : null}
      ${hub ? html`<div style="margin-bottom:12px"></div>` : html`<div class="footnote" style="margin-bottom:12px"><span style="color:var(--faint)">
        This is the settings row only. The hub-local kill switch flags/cost-autohalt-off is a file on the hub and is not visible from here.
      </span></div>`}`;
  };

  const tripsBody = () => {
    if (flags && flags.loading && !flags.data) return html`<${Skeleton} rows=${2} height=${20}/>`;
    if (trips.unreadable) {
      return html`<${ErrorBox} error=${(flags && flags.error) || new Error('the pause flags read returned no list')}
        onRetry=${flags && flags.reload}/>`;
    }
    return html`<${SortableTable} columns=${tripColumns} rows=${trips.trips} rowKey=${(r) => `${r.kind}:${r.project}`}
      defaultSort="since" defaultDir="desc"
      empty=${html`<${Empty} title="no project is paused by the breaker"
        note="Only spend-hold-<project> rows (and older paused-<project> rows) whose reason pipeline-health wrote are listed here."/>`}/>`;
  };

  const guardBody = () => {
    if (guard && guard.loading && !guard.data) return html`<${Skeleton} rows=${3} height=${20}/>`;
    if (g.unreadable) {
      return html`<${ErrorBox} error=${(guard && guard.error) || new Error('the call-guard read returned no rows list')}
        onRetry=${guard && guard.reload}/>`;
    }
    return html`
      ${g.capped ? html`<div class="footnote" style="margin-bottom:8px"><span style="color:var(--faint)">
        Showing the first ${GUARD_LIMIT} keys, the most the worker returns. There may be more.
      </span></div>` : null}
      <${SortableTable} wide columns=${guardColumns} rows=${g.rows} rowKey=${(r) => r.key}
        defaultSort="refused" defaultDir="desc"
        empty=${html`<${Empty} title="no guarded calls in the last 24h"/>`}/>`;
  };

  return html`
    <${Section} title="COST BREAKER" note="pipeline-health autohalt and the pre-call guard">
      ${autohaltLine()}
      ${msg ? html`<div class=${msg.ok ? 'banner banner--warn' : 'banner'} role="status"
        style=${msg.ok ? 'margin-bottom:10px;border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : 'margin-bottom:10px'}>
        <span>${msg.text}</span></div>` : null}
      <div class="section__note" style="margin-bottom:6px">TRIPS</div>
      ${tripsBody()}
      <div class="section__note" style="margin:14px 0 6px">CALL GUARD · 24H</div>
      ${guardBody()}
    <//>`;
}
