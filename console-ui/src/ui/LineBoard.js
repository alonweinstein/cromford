// The line board and its log (BH-4990), shared by /jobs and /now (BH-4992):
// every ticket in flight, one row each with its eight stations, cost and age,
// and the newest rows as a timestamped log. Each ticket key links to /t/<KEY>.
// Stage codes read as words (stageLabel); the raw code stays in the title.

import { html, Link } from '../router.js';
import { ProjectLink } from './primitives.js';
import { StationTrack } from './line.js';
import { UsdCell } from './UsdCell.js';
import { ageLabel } from '../lib/jobs.js';
import { lineTickets, lineLog, ticketPath } from '../lib/line.js';
import { stageLabel } from '../lib/stages.js';

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

// rows: decorated jobRows() rows.
export function LineBoard({ rows }) {
  const line = lineTickets(rows);
  const log = lineLog(rows);
  return html`
    <div class="board">
      ${line.length ? html`
        <ol class="board__list">
          ${line.map((t) => html`
            <li class="ticketrow" key=${`${t.project}/${t.key}`}>
              <div class="ticketrow__id">
                <${Link} to=${ticketPath(t.key)} class="tk">${t.key}<//>
                ${t.project ? html`<span class="ticketrow__sep">·</span><${ProjectLink} project=${t.project} class="ticketrow__project"/>` : null}
                <span class="ticketrow__meta" title=${t.lane}>${t.kind || 'job'}${t.stage ? ` · ${stageLabel(t.stage)}` : ''}${t.box ? ` · ${t.box}` : ''}</span>
                ${t.at === null ? html`<span class="ticketrow__meta" title=${`${t.kind || '?'}/${t.stage || '?'}`}>stage not mapped: ${stageLabel(t.stage) || 'none'}</span>` : null}
              </div>
              <div class="track-scroll">
                <${StationTrack} at=${t.at} state=${t.state} times=${t.times} label=${t.key} compact=${true}/>
              </div>
              <div class="ticketrow__side">
                <${UsdCell} value=${t.cost}/>
                <span class="ticketrow__age">${ageLabel(t.age_s)}</span>
              </div>
            </li>`)}
        </ol>`
        : html`<div class="board__empty">Nothing is on the line right now. ${plural(rows.length, 'row', 'rows')} read.</div>`}
      <aside class="log" aria-label="log">
        <h3 class="log__title">Log</h3>
        ${log.length ? html`
          <ol class="log__list">
            ${log.map((l) => html`
              <li class=${`log__row log__row--${l.tone}`} key=${l.id}>
                <${Link} to=${`/jobs/${encodeURIComponent(l.id)}`} class="log__ts" title="open this job">${l.ts}<//>
                <span class="log__stage" title=${l.stage || undefined}>${stageLabel(l.stage) || '-'}</span>
                ${l.key ? html`<${Link} to=${ticketPath(l.key)} class="tk">${l.key}<//>` : html`<span class="na">no ticket</span>`}
                <span class="log__text">${l.text}</span>
              </li>`)}
          </ol>`
          : html`<div class="board__empty">No rows yet.</div>`}
      </aside>
    </div>`;
}
