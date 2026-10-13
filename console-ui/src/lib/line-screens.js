// The line on Now, Fleet and Kanban (BH-4992, wave 3 of BH-4947). Pure: no DOM,
// no fetch. Each headline is a state sentence, a dim second line and a lede,
// drawn from the counts the screen already reads and nothing else; a count
// that was not read makes the headline say so, never a guessed 0.

import { healthFromAge, minutesFromPingText } from './format.js';
import { stationOf } from './line.js';

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const known = (...xs) => xs.every((x) => x !== null && x !== undefined && Number.isFinite(Number(x)));

// /now: what is in flight, what waits on a person, how the last ticks went.
export function nowHeadline({ inFlight, needs, boards, ticks, failing }) {
  if (!known(inFlight)) return { line1: 'Reading the line.', line2: 'The jobs read has not answered.', lede: '' };
  const line2 = [];
  if (known(needs)) line2.push(`${needs} need a person.`);
  if (known(ticks, failing) && ticks > 0) line2.push(`${failing} of the last ${plural(ticks, 'tick', 'ticks')} failed.`);
  return {
    line1: `${plural(Number(inFlight), 'ticket', 'tickets')} on the line.`,
    line2: line2.join(' ') || 'No tick read yet.',
    lede: known(boards) ? `Across ${plural(Number(boards), 'board', 'boards')}.` : ''
  };
}

// A box's health in words, by the same thresholds the tiles use.
const WORD = { ok: 'answering', warn: 'overdue', dead: 'silent', unknown: 'never pinged' };
export function boxHealth(ping) {
  const min = minutesFromPingText(ping);
  return { health: healthFromAge(min), min };
}
const ageWord = (ping, min) => (min === null ? 'never' : String(ping).trim().split(/\s+/)[0]);

// /: how many boxes answer, and which do not, by name.
export function fleetHeadline({ boxes, building, queueDepth, openAlerts }) {
  if (!boxes || typeof boxes !== 'object') return { line1: 'Reading the fleet.', line2: 'The machines read has not answered.', lede: '', counts: null };
  const names = Object.keys(boxes).sort();
  const c = { ok: 0, warn: 0, dead: 0, unknown: 0 };
  const down = [];
  for (const n of names) {
    const { health, min } = boxHealth(boxes[n]);
    c[health] += 1;
    if (health !== 'ok') down.push(`${n} (${ageWord(boxes[n], min)})`);
  }
  const line2 = [c.warn ? `${c.warn} overdue.` : 'None overdue.', c.dead ? `${c.dead} silent.` : 'None silent.'];
  if (c.unknown) line2.push(`${c.unknown} never pinged.`);
  const work = [];
  if (known(building)) work.push(`${building} building`);
  if (known(queueDepth)) work.push(`${queueDepth} waiting for a machine`);
  if (known(openAlerts)) work.push(plural(Number(openAlerts), 'open alert', 'open alerts'));
  return {
    line1: `${plural(names.length, 'box', 'boxes')}. ${c.ok === names.length && names.length ? 'All answering.' : `${c.ok} answering.`}`,
    line2: line2.join(' '),
    lede: `${down.length ? `Not answering: ${down.join(', ')}. ` : ''}${work.length ? `${work.join(', ')}.` : ''}`.trim(),
    counts: c
  };
}

// /kanban: the pipeline columns are stations of the line. Failed is off it.
export const KANBAN_STATION = Object.freeze({ queued: 1, building: 2, review: 3, merge_queue: 4, merged_deployed: 5, dead_failed: null });

// A card's station: the later of its own stage and its column, so a card never
// sits behind its column (a merge-queue card still at a review stage is at
// Merge). A failed card is off the line. A stage the line does not know takes
// its column's station.
export function cardStation(card, column) {
  const col = KANBAN_STATION[column] ?? null;
  if (column === 'dead_failed') return null;
  const own = stationOf({ kind: 'build', stage: card && card.stage });
  if (own === null) return col;
  return col === null ? own : Math.max(own, col);
}

// Each count reads as a number, or says it was not read; never a guessed 0.
export function kanbanHeadline(counts) {
  if (!counts || typeof counts !== 'object') return { line1: 'Reading the pipeline.', line2: '', lede: '' };
  const part = (k, words, name) => (known(counts[k]) ? `${Number(counts[k])} ${words}.` : `${name} count not read.`);
  return {
    line1: `${part('building', 'building', 'Building')} ${part('review', 'in review', 'Review')} ${part('merge_queue', 'in the merge queue', 'Merge queue')}`,
    line2: `${part('merged_deployed', 'shipped', 'Shipped')} ${part('dead_failed', 'failed', 'Failed')}`,
    lede: part('queued', 'queued to build', 'Queued')
  };
}
