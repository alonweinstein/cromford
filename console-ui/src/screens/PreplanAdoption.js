import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import {
  adoptKnobs, adoptionState, rateLabel, dayBars, underFloor, recentRows, zeroHits
} from '../lib/preplan-adoption.js';

// The PREPLAN ADOPTION section of /p/<project> (BH-2573, BH-2543.2): how many
// bought pre-plans a build actually used. Read-only. The floor, minimum and
// window are the preplan-tick knobs from the settings table, so the CADENCE CUT
// tag shows exactly when the box's rule would hold.

const kv = (label, value) => html`
  <div class="kv" key=${label}>
    <span class="kv__label">${label}</span>
    <span class="kv__val">${value}</span>
  </div>`;

const n = (v) => (v === null || v === undefined || v === '' ? '—' : String(v));

// Chart geometry, in viewBox units. One series, a fixed 0-100% axis.
const PAD_L = 34;
const PAD_T = 8;
const PAD_B = 18;
const PW = 320;
const PH = 100;
const VB_W = PAD_L + PW + 6;
const VB_H = PAD_T + PH + PAD_B;
const BASE = PAD_T + PH;

// Rounded at the data end, square at the baseline.
function barPath(x, w, h) {
  const top = BASE - h;
  const r = Math.min(4, w / 2, h);
  return `M${x},${BASE}V${top + r}Q${x},${top} ${x + r},${top}H${x + w - r}Q${x + w},${top} ${x + w},${top + r}V${BASE}Z`;
}

function AdoptChart({ days, windowDays }) {
  const bars = dayBars(days, { width: PW, height: PH });
  const yAxis = [[1, '100%'], [0.5, '50%'], [0, '0%']];
  return html`
    <div style="overflow-x:auto;max-width:100%">
      <svg role="img" aria-label=${`daily pre-plan adopt rate, ${windowDays} days`}
        viewBox=${`0 0 ${VB_W} ${VB_H}`} width="100%" style="min-width:320px;display:block">
        ${yAxis.map(([f, label]) => {
          const y = BASE - f * PH;
          return html`<g key=${label}>
            <line class=${f === 0.5 ? 'adopt-ref' : 'adopt-grid'} x1=${PAD_L} x2=${PAD_L + PW} y1=${y} y2=${y}
              stroke=${f === 0.5 ? 'var(--faint)' : 'var(--line)'} stroke-width="1"
              stroke-dasharray=${f === 0.5 ? '4 3' : null}/>
            <text x=${PAD_L - 6} y=${y + 3} text-anchor="end" font-size="10" fill="var(--faint)">${label}</text>
          </g>`;
        })}
        ${bars.map((b, i) => {
          const d = days[i];
          const x = PAD_L + b.x;
          const slotX = PAD_L + (PW / bars.length) * i;
          if (b.gap) {
            return html`<g key=${b.day}>
              <title>${b.day}: no bought pre-plans</title>
              <rect class="adopt-hit" x=${slotX} y=${PAD_T} width=${PW / bars.length} height=${PH} fill="transparent"/>
              <line class="adopt-gap" x1=${x} x2=${x + b.w} y1=${BASE - 1} y2=${BASE - 1}
                stroke="var(--faint)" stroke-width="2" stroke-dasharray="2 2"/>
            </g>`;
          }
          const adopted = Number(d.adopted) || 0;
          const bought = adopted + (Number(d.stale) || 0);
          return html`<g key=${b.day}>
            <title>${b.day}: ${rateLabel(d.rate)} (${adopted}/${bought})</title>
            <rect class="adopt-hit" x=${slotX} y=${PAD_T} width=${PW / bars.length} height=${PH} fill="transparent"/>
            <path class="adopt-bar" d=${barPath(x, b.w, Math.max(b.h, 1.5))} fill="var(--green)"/>
          </g>`;
        })}
        ${bars.length
          ? html`
            <text x=${PAD_L + bars[0].x} y=${VB_H - 4} font-size="10" fill="var(--faint)">${bars[0].label}</text>
            ${bars.length > 1
              ? html`<text x=${PAD_L + bars[bars.length - 1].x + bars[bars.length - 1].w} y=${VB_H - 4}
                  text-anchor="end" font-size="10" fill="var(--faint)">${bars[bars.length - 1].label}</text>`
              : null}`
          : null}
      </svg>
    </div>`;
}

function RecentTable({ recent, truncated }) {
  const rows = recentRows(recent);
  const jobLink = (r, text) => (r.job_id
    ? html`<${Link} to=${`/jobs/${encodeURIComponent(r.job_id)}`}>${text}<//>`
    : text);
  const columns = [
    { key: 'at', label: 'AT', cell: (r) => jobLink(r, html`<span style="white-space:nowrap">${String(r.at || '—').slice(0, 16).replace('T', ' ')}</span>`) },
    { key: 'ticket', label: 'TICKET', cell: (r) => jobLink(r, n(r.ticket)) },
    { key: 'verdict', label: 'VERDICT', cell: (r) => n(r.verdict) },
    { key: 'detail', label: 'DETAIL', flex: true, cell: (r) => html`<span class="cell-wrap">${n(r.detail)}</span>` }
  ];
  return html`
    <${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.id} wide
      defaultSort="at" defaultDir="desc"
      empty=${html`<${Empty} title="no pre-plan events listed"/>`}/>
    ${truncated
      ? html`<p class="section__note" style="margin:6px 0 0">newest 50 shown; older events exist</p>`
      : null}`;
}

export function PreplanAdoptionView({ state, knobs, project, onRetry }) {
  if (state.kind === 'loading') return html`<${Skeleton} rows=${3} height=${18}/>`;
  if (state.kind === 'error') return html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>`;
  const windowDays = state.windowDays || knobs.windowDays;
  if (state.kind === 'empty') {
    return html`<${Empty} title=${`no pre-plan events for ${project} in the last ${windowDays} days`}
      note="a rate needs at least one bought pre-plan, so there is no rate to show"/>`;
  }
  const s = state.stats;
  const cut = underFloor(s, knobs.floorPct, knobs.minSamples);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <div class="panel panel__pad" style="display:flex;flex-direction:column;gap:2px">
        ${kv(`${windowDays}D RATE`, html`${rateLabel(s.rate)}${cut
          ? html` <span class="tag tag--warn"
              title=${`under the adopt floor: under ${knobs.floorPct}% adopted with at least ${knobs.minSamples} bought`}>CADENCE CUT</span>`
          : null}`)}
        ${kv('HIT RATE', html`${rateLabel(s.hit_rate)}${zeroHits(s)
          ? html` <span class="tag tag--warn"
              title=${`${s.builds} builds in ${windowDays} days and none used a pre-plan`}>0% HIT</span>`
          : null}`)}
        ${kv('BUILDS', n(s.builds))}
        ${kv('BOUGHT', n(s.bought))}
        ${kv('ADOPTED', n(s.adopted))}
        ${kv('STALE', n(s.stale))}
        ${kv('MISS', n(s.miss))}
      </div>
      ${knobs.unreadable
        ? html`<span class="section__note">floor from defaults: settings unreadable</span>`
        : null}
      <${AdoptChart} days=${state.days} windowDays=${windowDays}/>
      <${RecentTable} recent=${state.recent} truncated=${state.truncated}/>
    </div>`;
}

// The adoption read waits for the settings read to settle (loaded or failed),
// so the window it asks the route for is the knob's.
function AdoptionRead({ project, knobs }) {
  const res = useApi(() => api.preplanAdoption(project, knobs.windowDays), [project, knobs.windowDays]);
  return html`<${PreplanAdoptionView} state=${adoptionState(res, project)} knobs=${knobs}
    project=${project} onRetry=${res.reload}/>`;
}

export function PreplanAdoption({ project }) {
  const settings = useApi(() => api.settings(), []);
  if (!settings.data && !settings.error) return html`<${Skeleton} rows=${3} height=${18}/>`;
  const knobs = adoptKnobs(settings.data, project);
  return html`<${AdoptionRead} project=${project} knobs=${knobs}/>`;
}
