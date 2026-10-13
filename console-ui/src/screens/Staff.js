// BH-5567 (BH-5556.10): /staff, the staff roster (Archie plus the seven mill
// agents) with open findings and a kill switch per agent, and its drill-down:
// /staff/:agent (the agent's open findings) and /staff/finding/:id (one
// finding, out to its source and its ticket). The kill switch writes the
// staff-kill-<agent> or staff-kill-all flag through the Flags screen's own
// PUT and DELETE, in an in-app modal with a required reason. The modal closes
// only on a 2xx; the KILL column shows the flags read-back, never the intent.
// Each *Screen owns its reads and writes; each *View is a pure function of
// props so the tests render it server-side.
import { useRef, useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { Modal } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Age, Legend } from '../ui/primitives.js';
import { minutesSince, safeHttpsUrl } from '../lib/format.js';
import { configHref } from '../lib/config.js';
import { clearFormState } from '../lib/flags.js';
import {
  rosterRows, findingRows, killFlagName, killSetBody, killClearQuery, killState, displayName, na,
  KILL_ALL, ARCHIE, ARCHIE_KILL_FLAG
} from '../lib/staff.js';

const loadRoster = () => api.staffRoster();
const loadKillFlags = () => api.coordFlagsAll({ prefix: 'staff-kill-' });
const errText = (e) => (e && e.message ? e.message : String(e));
const NOT_BUILT = 'The staff heartbeat (BH-5561) reads these flags. It is not built yet, so a set flag stops nothing today.';

export function StaffScreen() {
  const roster = useApi(loadRoster, [], { intervalMs: 60000 });
  const flags = useApi(loadKillFlags, [], { intervalMs: 60000 });
  const [edit, setEdit] = useState(null);
  const [pending, setPending] = useState(false);
  const [serverError, setServerError] = useState(null);
  const [note, setNote] = useState(null);
  const nonce = useRef(0);
  // A second click can land before the render that shows SAVING….
  const inFlight = useRef(false);

  // kind is 'kill' (set the flag) or 'resume' (clear it).
  const open = (kind, name, who) => {
    nonce.current += 1;
    setServerError(null);
    setEdit({ kind, name, who, nonce: nonce.current, draft: { reason: '' } });
  };

  const onConfirm = async () => {
    if (inFlight.current || !edit) return;
    const { kind, name, draft } = edit;
    const st = clearFormState(draft);
    if (st.blocked) { setServerError(st.hint); return; }
    const write = kind === 'kill' ? killSetBody(name, draft.reason) : killClearQuery(name, draft.reason);
    if (write === null) { setServerError(`refused: ${name} is not a staff kill flag`); return; }
    inFlight.current = true;
    setPending(true);
    setServerError(null);
    try {
      if (kind === 'kill') await api.setCoordFlagRow(write);
      else await api.clearCoordFlag(write);
      setNote(`${name} ${kind === 'kill' ? 'set' : 'cleared'} on fleet`);
      setEdit(null);
      flags.reload();
    } catch (e) {
      setServerError(`refused: ${errText(e)}`);
    } finally {
      inFlight.current = false;
      setPending(false);
    }
  };

  const dialog = edit ? html`
    <${Modal} key=${edit.nonce}
      title=${`${edit.kind === 'kill' ? 'KILL' : 'RESUME'} ${edit.who}`}
      confirmLabel=${pending ? 'SAVING…' : edit.kind === 'kill' ? 'KILL' : 'RESUME'}
      tone=${edit.kind === 'kill' ? 'danger' : 'warn'}
      confirmBlocked=${true}
      body=${({ setBlocked }) => html`<${KillForm} edit=${edit} serverError=${serverError} onBlocked=${setBlocked}/>`}
      onConfirm=${onConfirm}
      onCancel=${() => { if (!inFlight.current) setEdit(null); }}/>` : null;

  return html`<${StaffView} roster=${roster} flags=${flags} onKill=${open} busy=${pending} note=${note} dialog=${dialog}/>`;
}

// The reason lives in the form's own state and is written through to the
// draft, so a poll re-rendering the page never resets what is typed (D39).
export function KillForm({ edit, serverError, onBlocked }) {
  const [reason, setReason] = useState(edit.draft.reason);
  const onInput = (v) => {
    edit.draft.reason = v;
    setReason(v);
    onBlocked(clearFormState(edit.draft).blocked);
  };
  const { hint } = clearFormState({ reason });
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span style="color:var(--faint);overflow-wrap:anywhere">
        ${edit.kind === 'kill' ? 'Sets' : 'Clears'} the fleet flag <b>${edit.name}</b>. ${NOT_BUILT}
      </span>
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <input class="knob__input" style="width:100%" type="text" aria-label="reason" value=${reason}
          placeholder="why (required)" onInput=${(e) => onInput(e.target.value)}/>
      </label>
      ${hint ? html`<span style="color:var(--faint)">${hint}</span>` : null}
      ${serverError ? html`<span role="alert" style="color:var(--red);overflow-wrap:anywhere">${serverError}</span>` : null}
    </div>`;
}

const naCell = (v, title) => html`<span class=${v === null || v === undefined ? 'na' : ''} title=${title || ''}>${na(v)}</span>`;
const KILL_LABEL = { on: 'ON', off: 'off', unknown: 'unknown' };
const btn = (label, disabled, onClick) => html`
  <button type="button" class="btn btn--sm" style="min-height:44px" disabled=${disabled} onClick=${onClick}>${label}</button>`;

export function rosterColumns({ flagsData, sources, onKill, busy }) {
  const stateOf = (r) => {
    const name = r.name === ARCHIE ? null : killFlagName(r.name);
    return name ? killState(flagsData, name) : null;
  };
  return [
    {
      key: 'name', label: 'AGENT',
      cell: (r) => html`<${Link} to=${`/staff/${encodeURIComponent(r.name)}`} class="cell-name">${r.display}<//>
        <span class="na" style="display:block;font-size:var(--fs-xs)">${r.name}</span>`
    },
    { key: 'role', label: 'ROLE', cell: (r) => naCell(r.role) },
    { key: 'accountable', label: 'ACCOUNTABLE', cell: (r) => naCell(r.accountable) },
    { key: 'autonomy', label: 'AUTONOMY', cell: (r) => naCell(r.autonomy) },
    { key: 'cap', label: 'CAP', cell: (r) => naCell(r.cap) },
    { key: 'status', label: 'STATUS', cell: (r) => naCell(r.status) },
    {
      key: 'open_findings', label: 'OPEN FINDINGS', align: 'right',
      cell: (r) => html`<${Link} to=${`/staff/${encodeURIComponent(r.name)}`}>${na(r.open_findings)}<//>`
    },
    { key: 'precision', label: 'PRECISION', cell: (r) => naCell(r.precision, sources.precision) },
    { key: 'spend_usd', label: 'SPEND', unit: '$', cell: (r) => naCell(r.spend_usd, sources.spend) },
    {
      key: 'kill', label: 'KILL', sort: (r) => (r.name === ARCHIE ? ARCHIE_KILL_FLAG : stateOf(r)),
      cell: (r) => {
        if (r.name === ARCHIE) return html`<${Link} to=${configHref('flag', ARCHIE_KILL_FLAG)}>${ARCHIE_KILL_FLAG}<//>`;
        const s = stateOf(r);
        return s ? html`<span class=${s === 'unknown' ? 'na' : ''}>${KILL_LABEL[s]}</span>` : naCell(null);
      }
    },
    {
      key: 'action', label: 'ACTION', sort: null,
      cell: (r) => {
        const name = r.name === ARCHIE ? null : killFlagName(r.name);
        if (!name) return null;
        const s = stateOf(r);
        return s === 'on'
          ? btn('RESUME…', busy, () => onKill('resume', name, r.display))
          : btn('KILL…', busy || s === 'unknown', () => onKill('kill', name, r.display));
      }
    }
  ];
}

const LEGEND = [
  { term: 'KILL', text: 'ON means the staff-kill flag for that agent is set; unknown means the flags read failed' },
  { term: 'OPEN FINDINGS', text: 'findings the agent claimed that are not merged, rejected, noise or closed' },
  { term: 'PRECISION', text: 'n/a until BH-5563 records outcomes' },
  { term: 'SPEND', text: 'n/a until BH-5561 records spend per agent' },
  { term: 'ARCHIE', text: 'the Overlooker; lane-off-archie stops it, and STOP ALL STAFF does not' }
];

export function StaffView({ roster, flags, onKill, busy = false, note = null, dialog = null }) {
  const res = rosterRows(roster && roster.data);
  const flagsData = flags && flags.data;
  const allState = killState(flagsData, KILL_ALL);

  let body;
  if (roster && roster.loading && !res) body = html`<${Skeleton} rows=${8} height=${20}/>`;
  else if (res === null) {
    body = html`<${ErrorBox} error=${(roster && roster.error) || new Error('the roster read returned no list')} onRetry=${roster && roster.reload}/>`;
  } else {
    body = html`
      ${roster && roster.error ? html`<${ErrorBox} error=${roster.error} onRetry=${roster.reload}/>` : null}
      <${SortableTable} columns=${rosterColumns({ flagsData, sources: res.sources, onKill, busy })} rows=${res.rows}
        rowKey=${(r) => r.name} defaultSort="open_findings" defaultDir="desc"
        empty=${html`<${Empty} title="no staff agents"/>`}/>`;
  }

  return html`
    <div class="page">
      ${dialog}
      <${PageHeadline} chip="Staff"
        line1=${res ? `${res.rows.length} ${res.rows.length === 1 ? 'agent' : 'agents'} on the roster.` : roster && roster.loading ? 'Reading the roster.' : 'The roster read failed.'}
        line2="Archie and the mill staff, with their open findings."/>
      ${note ? html`<div class="banner banner--warn" role="status"
        style="margin-bottom:10px;border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)">
        <span style="overflow-wrap:anywhere">${note}</span></div>` : null}
      <${Section} title="ROSTER" note=${html`every staff agent; the flags page is <${Link} to="/flags">/flags<//>`}>
        <div style="display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;margin-bottom:8px">
          <span style="color:var(--faint);overflow-wrap:anywhere;flex:1 1 30ch">${NOT_BUILT}</span>
          <span>${`${KILL_ALL}: ${KILL_LABEL[allState]}`}</span>
          ${allState === 'on'
            ? btn('RESUME ALL STAFF…', busy, () => onKill && onKill('resume', KILL_ALL, 'ALL STAFF'))
            : btn('STOP ALL STAFF…', busy || allState === 'unknown', () => onKill && onKill('kill', KILL_ALL, 'ALL STAFF'))}
        </div>
        ${flags && flags.error ? html`<${ErrorBox} error=${flags.error} onRetry=${flags.reload}/>` : null}
        ${body}
        <${Legend} items=${LEGEND}/>
      <//>
    </div>`;
}

// ---------------------------------------------------------------- /staff/:agent

export function StaffAgentScreen({ agent }) {
  const roster = useApi(loadRoster, []);
  const findings = useApi(() => api.staffFindings(agent), [agent], { intervalMs: 60000 });
  return html`<${StaffAgentView} agent=${agent} roster=${roster} findings=${findings}/>`;
}

const age = (iso) => (iso
  ? html`<span title=${iso}><${Age} min=${minutesSince(iso)} warnAt=${Infinity}/></span>`
  : naCell(null));
const extLink = (url, label) => {
  const href = safeHttpsUrl(url);
  return href
    ? html`<a href=${href} target="_blank" rel="noopener" style="overflow-wrap:anywhere">${label || href}</a>`
    : html`<span style="overflow-wrap:anywhere">${na(url)}</span>`;
};
const ticketLabel = (url) => {
  const tail = String(url || '').split('/').filter(Boolean).pop();
  return /^\d+$/.test(tail || '') ? `#${tail}` : 'ticket';
};
const findingHref = (id) => `/staff/finding/${encodeURIComponent(id)}`;

const FINDING_COLUMNS = [
  { key: 'id', label: 'ID', align: 'right', cell: (f) => html`<${Link} to=${findingHref(f.id)}>${f.id}<//>` },
  { key: 'title', label: 'TITLE', flex: true, cell: (f) => html`<${Link} to=${findingHref(f.id)} class="cell-name">${f.title}<//>` },
  { key: 'status', label: 'STATUS', cell: (f) => naCell(f.status) },
  { key: 'source_url', label: 'SOURCE', cell: (f) => extLink(f.source_url, f.source_kind) },
  { key: 'observed_at', label: 'OBSERVED', cell: (f) => age(f.observed_at) },
  { key: 'claimed_at', label: 'CLAIMED', cell: (f) => age(f.claimed_at) },
  {
    key: 'ticket_url', label: 'TICKET',
    cell: (f) => (f.ticket_url ? extLink(f.ticket_url, ticketLabel(f.ticket_url)) : html`<span class="na">none yet</span>`)
  }
];

export function StaffAgentView({ agent, roster, findings }) {
  const rr = rosterRows(roster && roster.data);
  const row = rr && rr.rows.find((a) => a.name === String(agent || '').trim().toLowerCase());
  const res = findingRows(findings && findings.data);

  let body;
  if (findings && findings.loading && !res) body = html`<${Skeleton} rows=${4} height=${20}/>`;
  else if (res === null) {
    body = html`<${ErrorBox} error=${(findings && findings.error) || new Error('the findings read returned no list')} onRetry=${findings && findings.reload}/>`;
  } else {
    body = html`
      ${findings && findings.error ? html`<${ErrorBox} error=${findings.error} onRetry=${findings.reload}/>` : null}
      ${res.truncated ? html`<p style="color:var(--faint)">the list is capped at 500: the newest 500 open findings show</p>` : null}
      <${SortableTable} wide columns=${FINDING_COLUMNS} rows=${res.rows} rowKey=${(f) => f.id} defaultSort="id" defaultDir="desc"
        empty=${html`<${Empty} title="no open findings"/>`}/>`;
  }

  const facts = row ? [['ROLE', row.role], ['ACCOUNTABLE', row.accountable], ['AUTONOMY', row.autonomy], ['CAP', row.cap], ['STATUS', row.status]] : [];
  return html`
    <div class="page">
      <${PageHeadline} chip="Staff"
        line1=${displayName(agent)}
        line2=${res ? `${res.rows.length} open ${res.rows.length === 1 ? 'finding' : 'findings'}${res.truncated ? ' (capped)' : ''}.` : 'Open findings.'}/>
      <p><${Link} to="/staff">← the roster<//></p>
      ${facts.length ? html`
        <dl class="lanekv">
          ${facts.map(([k, v]) => html`<dt key=${`t-${k}`}>${k}</dt><dd key=${`d-${k}`}>${na(v)}</dd>`)}
        </dl>` : null}
      <${Section} title="OPEN FINDINGS">${body}<//>
    </div>`;
}

// ---------------------------------------------------------- /staff/finding/:id

export function StaffFindingScreen({ id }) {
  const finding = useApi(() => api.staffFinding(id), [id]);
  return html`<${StaffFindingView} id=${id} finding=${finding}/>`;
}

const labelsText = (f) => (f.labels_invalid
  ? `${na(f.source_labels)} (not a valid label list)`
  : Array.isArray(f.source_labels) && f.source_labels.length ? f.source_labels.join(', ') : 'none');

export function StaffFindingView({ id, finding }) {
  const f = finding && finding.data && finding.data.finding;
  let body;
  if (finding && finding.loading && !f) body = html`<${Skeleton} rows=${8} height=${18}/>`;
  else if (!f) {
    body = html`<${ErrorBox} error=${(finding && finding.error) || new Error('the finding read returned no row')} onRetry=${finding && finding.reload}/>`;
  } else {
    const items = [
      ['ID', String(f.id)],
      ['AGENT', html`<${Link} to=${`/staff/${encodeURIComponent(f.agent)}`}>${displayName(f.agent)}<//>`],
      ['TITLE', f.title],
      ['STATUS', na(f.status)],
      ['TICKET', f.ticket_url ? extLink(f.ticket_url) : html`<span class="na">no ticket filed yet</span>`],
      ['SOURCE', extLink(f.source_url)],
      ['SOURCE KIND', na(f.source_kind)],
      ['LABELS', labelsText(f)],
      ['FILED BY', na(f.source_filed_by)],
      ['OBSERVED', na(f.observed_at)],
      ['CLAIMED', na(f.claimed_at)],
      ['UPDATED', na(f.updated_at)],
      ['FINGERPRINT', html`<code style="overflow-wrap:anywhere">${f.fingerprint}</code>`]
    ];
    body = html`
      <dl class="lanekv">
        ${items.map(([k, v]) => html`<dt key=${`t-${k}`}>${k}</dt><dd key=${`d-${k}`}>${v}</dd>`)}
      </dl>`;
  }
  return html`
    <div class="page">
      <${PageHeadline} chip="Staff" line1=${f ? f.title : `Finding ${id || ''}`}
        line2=${f ? `${displayName(f.agent)}, ${na(f.status)}.` : 'One staff finding.'}/>
      <p>${f ? html`<${Link} to=${`/staff/${encodeURIComponent(f.agent)}`}>← ${displayName(f.agent)}'s findings<//>` : html`<${Link} to="/staff">← the roster<//>`}</p>
      <${Section} title="FINDING">${body}<//>
    </div>`;
}
