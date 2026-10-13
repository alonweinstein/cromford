import { useState } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { agoFromMinutes } from '../lib/format.js';

// BH-2329.3: a red main on /p/<project>, and the audited CLEAR that unfreezes
// merges for that sha. The rows come from the jobs worker (pause_flags joined
// to main_red); the CLEAR is recorded there with its reason. Nothing is kept
// here: a clear is the worker's answer, never a local flag.

// The GET answer is `{main_red: [...], truncated}`; a bare array or `rows` is
// read the same way so a shape change renders nothing rather than throwing.
export function mainRedRows(data) {
  if (Array.isArray(data)) return data;
  return (data && (data.main_red || data.rows)) || [];
}

// A freeze belongs to this project by its detail row's project, or by the
// flag name the detector would give it. A pr-pair freeze is slug-named with no
// project, so it matches neither and is not bannered.
export function mainRedForProject(rows, project) {
  return rows.filter((r) => r && (r.project === project || r.name === 'main-red-' + project));
}

// The worker 400s a blank reason, so the dialog opens blocked.
export function clearFormState(form) {
  if (!String((form && form.reason) ?? '').trim()) {
    return { blocked: true, hint: 'A reason is required: it is recorded on the clear.' };
  }
  return { blocked: false, hint: null };
}

// The CLEAR dialog's body. Like PauseForm, every keystroke is written through
// to `value` (what onClear reads on confirm) and reported to the dialog.
export function ClearForm({ row, value, onBlocked }) {
  const [f, setF] = useState(value);
  const onInput = (e) => {
    value.reason = e.target.value;
    setF({ ...value });
    if (onBlocked) onBlocked(clearFormState(value).blocked);
  };
  const { hint } = clearFormState(f);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>Clear the main-red freeze <b style="overflow-wrap:anywhere">${row.slug || row.name}</b>${row.sha ? html` on <b>${String(row.sha).slice(0, 8)}</b>` : null}?</span>
      <span>Merges unfreeze for this sha. If main goes red on a new sha the freeze comes back.</span>
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <textarea class="knob__input" style="width:100%" rows="3" value=${f.reason} onInput=${onInput}
          placeholder="why main is safe to merge into" required aria-required="true"></textarea>
      </label>
      ${hint ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${hint}</span>` : null}
    </div>`;
}

// The one call CLEAR's confirm makes. Any thrown error (400, 409, 5xx,
// network) is a failure carrying the worker's text; only a resolve is ok.
export async function runClear(row, form) {
  try {
    await api.clearMainRed({ name: row.name, reason: String(form.reason).trim(), sha: row.sha || undefined });
    return { ok: true, text: 'cleared' };
  } catch (e) {
    return { ok: false, text: e.message };
  }
}

function sinceMinutes(iso, now) {
  const t = iso ? Date.parse(iso) : NaN;
  return Number.isNaN(t) ? null : Math.max(0, Math.round((now - t) / 60000));
}

const wrap = 'overflow-wrap:anywhere';

function RedRow({ row, now, onClear }) {
  const sha8 = row.sha ? String(row.sha).slice(0, 8) : null;
  const detail = row.workflow || row.sha;
  const age = sinceMinutes(row.since, now);
  return html`
    <div class="banner" role="alert">
      <span style=${wrap}>MAIN IS RED — <b>${row.slug || row.name}</b></span>
      ${detail ? html`
        <span style=${wrap}>
          ${row.workflow ? `${row.workflow} failed` : 'red'}${row.job ? ` (job: ${row.job})` : ''}${sha8 ? ' on ' : ''}${sha8
            ? (row.slug
              ? html`<a href=${`https://github.com/${row.slug}/commit/${row.sha}`} target="_blank" rel="noopener">${sha8}</a>`
              : sha8)
            : null}
        </span>` : html`
        <span style=${wrap}>${row.reason || ''}${row.actor ? ` · by ${row.actor}` : ''}</span>`}
      ${age !== null ? html`<span>since ${agoFromMinutes(age)}</span>` : null}
      ${row.run_url ? html`<a href=${row.run_url} target="_blank" rel="noopener">RUN</a>` : null}
      <button class="btn btn--warn" type="button" style="margin-left:auto" onClick=${() => onClear(row)}>CLEAR</button>
    </div>`;
}

// One load state, drawn. A failed read says only that it failed: the last rows
// are not shown as current, and nothing here ever says main is green.
export function MainRedBannerView({ state, project, onClear, msg, now = Date.now() }) {
  if (state.error) {
    return html`<span class="muted" style="font-size:var(--fs-xs);color:var(--faint)">main-red status unavailable</span>`;
  }
  const rows = state.data ? mainRedForProject(mainRedRows(state.data), project) : [];
  if (!rows.length && !msg) return null;
  return html`
    ${rows.map((row) => html`<${RedRow} key=${row.name} row=${row} now=${now} onClear=${onClear} />`)}
    ${msg ? html`<span class=${msg.ok ? '' : 'knob__note knob__note--bad'} style="max-width:none" role="status">${msg.text}</span>` : null}`;
}

export function MainRedBanner({ project, confirm }) {
  const state = useApi(() => api.mainRed(), [], { intervalMs: 30000 });
  const [msg, setMsg] = useState(null);
  const onClear = async (row) => {
    const form = { reason: '' };
    const ok = await confirm({
      title: 'CLEAR MAIN-RED', confirmLabel: 'CLEAR', tone: 'warn', confirmBlocked: true,
      body: ({ setBlocked }) => html`<${ClearForm} row=${row} value=${form} onBlocked=${setBlocked} />`
    });
    if (!ok) return;
    const gate = clearFormState(form);
    if (gate.blocked) { setMsg({ ok: false, text: gate.hint }); return; }
    setMsg(await runClear(row, form));
    // A success drops the row; a 409 (not red, moved to a new sha) means what
    // is on screen is stale. Either way the next read is the truth.
    state.reload();
  };
  return html`<${MainRedBannerView} state=${state} project=${project} onClear=${onClear} msg=${msg} />`;
}
