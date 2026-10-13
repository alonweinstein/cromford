import { useState } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox, Age } from '../ui/primitives.js';
import { minutesSince } from '../lib/format.js';
import {
  routingState, haltDisabledReason, changeCells, haltAction, haltFormState, currentHalt, ROUTING_CHANGES_LIMIT
} from '../lib/routing.js';

// The ROUTING section of /p/<project> (BH-2328): the routing row, a HALT
// toggle that flips only `halted` on it, and the row's change log. Three
// separate reads, so one failing degrades one pane rather than the section.

const kv = (label, value) => html`
  <div class="kv" key=${label}>
    <span class="kv__label">${label}</span>
    <span class="kv__val">${value}</span>
  </div>`;

const ROWS_ON = { true: 'on', false: 'off', null: 'unknown' };

function CurrentRow({ state, onRetry }) {
  if (state.kind === 'loading') return html`<${Skeleton} rows=${3} height=${18}/>`;
  if (state.kind === 'error') return html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>`;
  const rowsOn = kv('ROWS DRIVE ROUTING', ROWS_ON[String(state.rowsOn)]);
  if (state.kind === 'none') {
    return html`
      <div class="panel panel__pad" style="display:flex;flex-direction:column;gap:2px">
        ${kv('ROUTING ROW', 'no routing row')}
        ${rowsOn}
      </div>`;
  }
  const r = state.row;
  const halted = Number(r.halted) === 1;
  return html`
    <div class="panel panel__pad" style="display:flex;flex-direction:column;gap:2px">
      ${kv('BUILDER', r.builder || '—')}
      ${kv('POOL APP', r.pool_app || '—')}
      ${kv('HALTED', halted ? html`<span class="tag tag--warn">HALTED</span>` : 'no')}
      ${kv('UPDATED', html`<${Age} min=${minutesSince(r.updated_at)} warnAt=${Infinity}/>`)}
      ${rowsOn}
    </div>`;
}

function ChangeLog({ project, changes, onRetry }) {
  if (changes.error && !changes.data) return html`<${ErrorBox} error=${changes.error} onRetry=${onRetry}/>`;
  if (!changes.data) return html`<${Skeleton} rows=${3} height=${18}/>`;
  const list = Array.isArray(changes.data.changes) ? changes.data.changes : [];
  const rows = list.map((c) => ({ id: c.id, ...changeCells(c) }));
  const columns = [
    { key: 'at', label: 'AT', cell: (c) => html`<span style="white-space:nowrap">${String(c.at || '—').slice(0, 16).replace('T', ' ')}</span>` },
    { key: 'actor', label: 'ACTOR', cell: (c) => c.actor },
    { key: 'reason', label: 'REASON', flex: true, cell: (c) => html`<span class="cell-wrap">${c.reason}</span>` },
    { key: 'builder', label: 'BUILDER', cell: (c) => c.builder },
    { key: 'pool_app', label: 'POOL APP', cell: (c) => c.pool_app },
    { key: 'halted', label: 'HALTED', cell: (c) => c.halted }
  ];
  return html`
    <${SortableTable} columns=${columns} rows=${rows} rowKey=${(c) => c.id} wide
      defaultSort="at" defaultDir="desc"
      empty=${html`<${Empty} title=${`no routing changes recorded for ${project}`}/>`}/>
    ${changes.data.truncated
      ? html`<p class="section__note" style="margin:6px 0 0">newest ${ROUTING_CHANGES_LIMIT} shown; older changes exist</p>`
      : null}`;
}

// The halt being lifted: who set it, when, and why, so an UNHALT is never a
// blind click over a halt someone set on purpose.
function HaltWas({ halt }) {
  if (!halt.found) return html`<span style="color:var(--faint)">Why it was halted is unknown: ${halt.why}.</span>`;
  return html`<span>Halted by <b>${halt.actor || '—'}</b>${halt.at ? ` at ${String(halt.at).slice(0, 16).replace('T', ' ')}` : ''}: ${halt.reason || '(no reason recorded)'}</span>`;
}

// Written through on every keystroke into the per-click object the toggle
// reads on confirm, so typing never re-renders the page (PauseForm's pattern).
// onBlocked is the Modal's setBlocked: an UNHALT's confirm stays disabled
// until the reason is non-blank.
function HaltConfirmBody({ project, target, value, halt, onBlocked }) {
  const [reason, setReason] = useState(value.reason);
  const { hint } = haltFormState(target, reason);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>
        ${target
          ? html`Halt new pool spawns for <b>${project}</b>? Builds already running keep going. Each box picks this up at its next routing sync. A harness deploy clears it unless a pool-halt .keep file holds the halt.`
          : html`Resume pool spawns for <b>${project}</b>? Each box picks this up at its next routing sync.`}
      </span>
      ${target ? null : html`<${HaltWas} halt=${halt}/>`}
      <label class="knob" style="width:100%">
        <span class="knob__label">${target ? 'REASON (OPTIONAL)' : 'REASON (REQUIRED)'}</span>
        <input class="knob__input" style="width:100%" type="text" aria-label="reason for this routing change"
          value=${reason}
          placeholder=${target ? 'HALT from Mission Control' : 'why this halt can be lifted'}
          onInput=${(e) => {
            value.reason = e.target.value;
            setReason(e.target.value);
            if (onBlocked) onBlocked(haltFormState(target, e.target.value).blocked);
          }} />
      </label>
      ${hint ? html`<span style="color:var(--faint)">${hint}</span>` : null}
    </div>`;
}

export function RoutingView({ project, state, changes, busy, msg, onHalt, onRetryRow, onRetryChanges, onDismiss }) {
  const halted = state.kind === 'row' && Number(state.row.halted) === 1;
  const why = haltDisabledReason(state);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <${CurrentRow} state=${state} onRetry=${onRetryRow}/>
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
        <button class=${halted ? 'toggle' : 'toggle toggle--off'} aria-label="HALT"
          aria-pressed=${halted ? 'true' : 'false'} disabled=${busy || why !== null} onClick=${onHalt}>
          HALT
          <span class="toggle__track"><span class="toggle__knob"></span></span>
        </button>
        ${why ? html`<span class="section__note">${why}</span>` : null}
      </div>
      ${msg ? html`
        <div class="banner" role="status"
          style=${msg.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${msg.text}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${onDismiss}>DISMISS</button>
        </div>` : null}
      <${ChangeLog} project=${project} changes=${changes} onRetry=${onRetryChanges}/>
    </div>`;
}

export function RoutingPanel({ project }) {
  const row = useApi(() => api.routing(project), [project], { intervalMs: 30000 });
  const knob = useApi(() => api.coordSetting('routing_rows'), [], { intervalMs: 30000 });
  const changes = useApi(() => api.routingChanges(project, ROUTING_CHANGES_LIMIT), [project], { intervalMs: 30000 });
  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const state = routingState(row, knob);

  const onHalt = async () => {
    if (busy || state.kind !== 'row' || haltDisabledReason(state) !== null) return;
    const target = Number(state.row.halted) !== 1;
    const label = target ? 'HALT' : 'UNHALT';
    // busy holds the toggle disabled through the dialog and the write, so a
    // double click cannot send two.
    setBusy(true);
    setMsg(null);
    try {
      const form = { reason: '' };
      const halt = currentHalt(changes);
      const ok = await confirm({
        title: label, confirmLabel: label, tone: target ? 'warn' : null,
        confirmBlocked: haltFormState(target, form.reason).blocked,
        body: ({ setBlocked }) => html`<${HaltConfirmBody} project=${project} target=${target} value=${form}
          halt=${halt} onBlocked=${setBlocked}/>`
      });
      if (!ok) return;
      setMsg(await haltAction({ apiObj: api, project, target, reason: form.reason }));
      row.reload();
      changes.reload();
    } finally {
      setBusy(false);
    }
  };

  return html`<div>
    ${dialog}
    <${RoutingView} project=${project} state=${state} changes=${changes} busy=${busy} msg=${msg}
      onHalt=${onHalt} onRetryRow=${row.reload} onRetryChanges=${changes.reload} onDismiss=${() => setMsg(null)}/>
  </div>`;
}
