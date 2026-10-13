import { useCallback, useEffect, useRef, useState } from 'preact/hooks';
import { html } from '../../router.js';
import { api } from '../../api.js';
import { useConfirm } from '../../ui/Modal.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { Empty, ErrorBox } from '../../ui/primitives.js';
import { agoFromMinutes, minutesSince } from '../../lib/format.js';
import {
  historyView, lastVerifyByBox, submitVerify, confirmOpts, STANDBY_VERIFY_LIMIT
} from '../../lib/standby-verify.js';

// Standby verify for the HUB screen (BH-2519 / BH-2642). The standby panel
// slice mounts these; the signatures below are the contract both slices import.
//
// The history load is request-versioned: each GET takes a sequence number and
// only the newest one may land, so a slow answer from an earlier reloadKey never
// overwrites a newer one. A failed refresh keeps the last good runs and sets
// error beside them, so a load failure never reads as "never verified".

const NA = html`<span class="na">—</span>`;
const orNa = (v) => (v === null || v === undefined || v === '' ? NA : v);
const TONE = { ok: 'tag tag--green', warn: 'tag tag--warn', bad: 'tag tag--bad' };
const PILL = { ok: 'tag tag--green', fail: 'tag tag--bad', requested: 'tag tag--warn', claimed: 'tag tag--warn' };
const DETAIL = ['id', 'box', 'of_hub', 'status', 'verdict_detail', 'sha256', 'snapshot_ts',
  'requested_by', 'requested_at', 'claimed_at', 'finished_at'];

// { runs, lastByBox, truncated, error, reload } for the verify history.
export function useStandbyVerifyRuns(reloadKey) {
  const [state, setState] = useState({ runs: [], truncated: false, error: null });
  const [nonce, setNonce] = useState(0);
  const seq = useRef(0);

  useEffect(() => {
    const mine = ++seq.current;
    api.standbyVerifyRuns()
      .then((payload) => {
        if (mine !== seq.current) return;
        const v = historyView(payload);
        setState({ runs: v.runs, truncated: v.truncated, error: null });
      })
      .catch((error) => {
        if (mine === seq.current) setState((s) => ({ ...s, error }));
      });
    // An unmount or a newer load retires this one.
    return () => { seq.current++; };
  }, [reloadKey, nonce]);

  const reload = useCallback(() => setNonce((n) => n + 1), []);
  return { runs: state.runs, lastByBox: lastVerifyByBox(state.runs), truncated: state.truncated, error: state.error, reload };
}

function ageOf(run) {
  const a = agoFromMinutes(minutesSince(run.finished_at || run.requested_at));
  return a === 'now' || a === 'never' ? a : `${a} ago`;
}

// The LAST VERIFY pill plus the VERIFY button for one standby row.
export function StandbyVerifyCell({ row, last, onQueued }) {
  const [dialog, ask] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState(null);
  // The ref guards two clicks that land before the disabled render does.
  const inFlight = useRef(false);

  const onVerify = async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    try {
      const out = await submitVerify(() => ask(confirmOpts(row.box, row.of_hub)), api, row.box);
      if (out) {
        setOutcome(out);
        // Any answer, failure included, reloads the history so the pill shows the server.
        if (onQueued) onQueued();
      }
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  return html`<span style="display:inline-flex;flex-wrap:wrap;gap:6px;align-items:center">
    ${last
      ? html`<span class=${PILL[last.status] || 'tag'}>${last.status}</span>
          <span class="section__note">${ageOf(last)}</span>`
      : html`<span class="na">never verified</span>`}
    <button type="button" class="btn btn--warn" disabled=${busy} onClick=${onVerify}>VERIFY</button>
    ${outcome ? html`<span class=${TONE[outcome.tone]} role="status">${outcome.text}</span>` : null}
    ${dialog}
  </span>`;
}

function RunDetail({ run }) {
  return html`
    <dl class="standby-verify__detail"
      style="display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 12px;margin:10px 0 0;font-size:var(--fs-xs)">
      ${DETAIL.map((k) => html`
        <dt key=${`t-${k}`} style="color:var(--muted)">${k}</dt>
        <dd key=${`d-${k}`} style="margin:0;min-width:0;overflow-wrap:anywhere;word-break:break-all">${orNa(run[k])}</dd>`)}
    </dl>`;
}

// One box's verify history inside the expanded standby row. `truncated` is an
// optional extra prop beside the contract's four.
export function StandbyVerifyDetail({ box, runs, error, onRetry }) {
  const { truncated } = arguments[0];
  const [openId, setOpenId] = useState(null);
  const mine = (Array.isArray(runs) ? runs : []).filter((r) => r.box === box);

  if (!mine.length) {
    return error ? html`<${ErrorBox} error=${error} onRetry=${onRetry} />` : html`<${Empty} title="Never verified" />`;
  }

  const columns = [
    { key: 'status', label: 'STATUS', cell: (r) => html`
      <button type="button" class="cell-name" aria-expanded=${openId === r.id ? 'true' : 'false'}
        style="background:none;border:0;padding:0;font:inherit;cursor:pointer;text-align:left"
        onClick=${() => setOpenId((cur) => (cur === r.id ? null : r.id))}>${r.status}</button>` },
    { key: 'requested_by', label: 'REQUESTED BY', cell: (r) => orNa(r.requested_by) },
    { key: 'requested_at', label: 'REQUESTED', cell: (r) => orNa(r.requested_at) },
    { key: 'finished_at', label: 'FINISHED', cell: (r) => orNa(r.finished_at) },
  ];
  const open = openId !== null ? mine.find((r) => r.id === openId) : null;

  return html`<div>
    <${SortableTable} columns=${columns} rows=${mine} rowKey=${(r) => r.id}
      defaultSort="requested_at" defaultDir="desc" />
    ${truncated === true
      ? html`<p class="section__note" style="margin:6px 0 0">showing the last ${STANDBY_VERIFY_LIMIT} runs across all standbys</p>`
      : null}
    ${open ? html`<${RunDetail} run=${open} />` : null}
    ${error
      ? html`<p class="section__note" style="margin:6px 0 0">refresh failed: ${error.message}; showing the last answer
          ${onRetry ? html` <button type="button" class="btn btn--sm" onClick=${onRetry}>RETRY</button>` : null}</p>`
      : null}
  </div>`;
}
