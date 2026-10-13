import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { Section, Stat, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { agoFromMinutes, fmtDuration, whenLabel } from '../lib/format.js';
import { plainLabel } from '../lib/labels.js';
import { rcLabel } from '../lib/cockpit.js';

export function RunScreen({ id }) {
  const r = useApi(() => api.run(id), [id]);

  if (r.loading && !r.data) return html`<div class="page"><${PageHeadline} chip="Run" line1=${`run #${id}`} line2="Reading the run."/><${Skeleton} rows=${6} height=${22}/></div>`;
  if (r.error && !r.data) {
    return html`<div class="page">
      <${Link} to="/" class="crumb">← FLEET<//>
      <${ErrorBox} error=${r.error} onRetry=${r.reload}/>
    </div>`;
  }

  return html`<${RunView} run=${r.data.run} nowMs=${Date.now()}/>`;
}

// The run page as a pure function of the row, so a test can render it (BH-3569).
// A run can be days old, so its stamps carry a date past 24h, not a bare clock.
export function RunView({ run, nowMs = Date.now() }) {
  const project = run.project;

  return html`
    <div class="page">
      <${PageHeadline} chip="Run" line1=${`run #${run.id}`}
        line2=${`${rcLabel(run.rc)}. ${plainLabel(run.kind)} on ${project}.`}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to=${`/p/${encodeURIComponent(project)}`} class="crumb">← ${project}<//>
        <span class="crumb-sep">/</span>
        <span class=${Number(run.rc) === 0 ? 'tag tag--green' : 'tag tag--dead'} title=${`rc=${run.rc ?? ''}`}>${rcLabel(run.rc)}</span>
        <span style="font-size:var(--fs-sm);color:var(--faint)">${plainLabel(run.kind)} · started ${whenLabel(run.started_at, nowMs)}</span>
      </div>

      <div class="stats">
        <${Stat} label="KIND" value=${plainLabel(run.kind) || '—'} tone="sm"/>
        <${Stat} label="EXIT CODE" value=${run.rc ?? '—'} tone=${Number(run.rc) === 0 ? 'green' : 'amber'}/>
        <${Stat} label="DURATION" value=${fmtDuration(run.duration_s)} tone="sm"/>
        <${Stat} label="AGE" value=${agoFromMinutes(run.age_min)} tone="sm"/>
        <${Stat} label="FINISHED" value=${run.finished_at ? whenLabel(run.finished_at, nowMs) : '—'} tone="sm"/>
      </div>

      <${Section} title="SUMMARY">
        <div class="panel panel__pad" style="font-size:var(--fs-sm);line-height:1.7;color:var(--soft);word-break:break-word">
          ${run.summary || html`<span class="na">this run beat no summary line</span>`}
        </div>
      <//>

      <${Section} title="SESSION TAIL" note="the last ~7KB of session output, stored with the run">
        ${run.detail
          ? html`<pre class="term">${run.detail}
<span class="term__end">─ ─ ─ end of stored session tail ─ ─ ─</span></pre>`
          : html`<${Empty} title="no session output stored"
              note="This run predates the run drill-down column, or it beat no detail. The live log tail on the project screen fetches fresh from the box instead.">
              <${Link} to=${`/p/${encodeURIComponent(project)}`} class="btn btn--sm">FETCH A LIVE TAIL<//>
            <//>`}
      <//>
    </div>`;
}
