// The one comparator behind every table in the console. Every table gets
// click-to-sort headers, so every table shares this ordering — including the
// rule that a missing value is *unknown*, not *smallest*, and therefore sinks
// to the bottom whichever way the arrow points.

const MISSING = Symbol('missing');

function normalise(v) {
  if (v === null || v === undefined || v === '') return MISSING;
  if (typeof v === 'number') return Number.isFinite(v) ? v : MISSING;
  if (typeof v === 'boolean') return v ? 1 : 0;
  if (typeof v === 'string') {
    const t = v.trim();
    if (t === '') return MISSING;
    // D1 hands plenty of counts back as strings; "9" must not beat "10".
    if (/^-?\d+(\.\d+)?$/.test(t)) return Number(t);
    return t.toLowerCase();
  }
  return String(v).toLowerCase();
}

export function compareValues(a, b) {
  const x = normalise(a);
  const y = normalise(b);
  if (x === MISSING && y === MISSING) return 0;
  if (x === MISSING) return 1;
  if (y === MISSING) return -1;
  if (typeof x === 'number' && typeof y === 'number') return x < y ? -1 : x > y ? 1 : 0;
  return String(x) < String(y) ? -1 : String(x) > String(y) ? 1 : 0;
}

export function sortRows(rows, accessor, direction = 'asc') {
  const flip = direction === 'desc' ? -1 : 1;
  return rows
    .map((row, i) => ({ row, i }))
    .sort((a, b) => {
      const va = accessor(a.row);
      const vb = accessor(b.row);
      const missingA = normalise(va) === MISSING;
      const missingB = normalise(vb) === MISSING;
      // Missing sinks in both directions, so it is compared before the flip.
      if (missingA || missingB) {
        if (missingA && missingB) return a.i - b.i;
        return missingA ? 1 : -1;
      }
      const c = compareValues(va, vb);
      return c !== 0 ? c * flip : a.i - b.i;
    })
    .map((w) => w.row);
}

export function nextDirection(clickedKey, activeKey, activeDirection) {
  if (clickedKey !== activeKey) return 'asc';
  return activeDirection === 'asc' ? 'desc' : 'asc';
}

export const ariaSort = (columnKey, activeKey, direction) =>
  columnKey !== activeKey ? 'none' : direction === 'asc' ? 'ascending' : 'descending';
