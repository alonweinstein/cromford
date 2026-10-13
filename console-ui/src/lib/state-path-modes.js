// BH-5000 (BH-4951.1): which store each coordination path decides from, for
// the STATE PATHS panel on /settings. The table describes what the code does
// when a path's flag or knob is on; it is not a business parameter. The live
// state comes from the pause_flags rows and the settings rows.
//
//   file    the box's own file is the store (flag/knob off, or no row)
//   rows    the DB rows are read first, the file kept as fallback
//   shadow  the file is still read first and the row is a twin
//   unread  the read failed, so the mode is not known from here

import { rowsOnlyState } from './merge-queue.js';

const path = (name, kind, onMode, lane, note) => Object.freeze({ name, kind, onMode, lane, note });

// In the order #5000 flips them.
export const STATE_PATHS = Object.freeze([
  path('pr-state-rows', 'flag', 'rows', 'merge-conductor',
    'held pages and attempts read rows first, the tsv kept as fallback (bin/lib/mc/locks.sh, log.sh)'),
  path('no-twin-ledgers', 'flag', 'shadow', 'review-autopilot, lander and kin',
    'the file is read first and the row is its twin (bin/lib/ledger-twin.sh)'),
  path('build_queue_rows_only', 'setting', 'rows', 'build queue', ''),
  path('merge_queue_rows_only', 'setting', 'rows', 'merge queue', ''),
  path('deploy_queue_rows', 'setting', 'rows', 'deploy queue', ''),
  path('ready_queue_rows', 'setting', 'rows', 'ready queue', ''),
  path('alerts-db', 'flag', 'rows', 'alerts',
    "the row is the primary (bin/lib/alert-state.sh). A box whose ALERTS_DB_ENABLED=0 stays on file; that env isn't visible here"),
  path('closeout_aged_table', 'setting', 'rows', 'closeout', '')
]);

export const STATE_PATH_KNOBS = STATE_PATHS.filter((p) => p.kind === 'setting').map((p) => p.name);

const errText = (r) => String(r && r.error ? r.error.message || r.error : 'no answer');

// flagsRes: useApi's answer for api.coordFlags(). settingRes: { <knob>: useApi
// answer for api.coordSetting(knob) }. Returns { rows, failed }, failed naming
// each read that did not answer ('flags' or a knob).
export function pathModes(flagsRes, settingRes) {
  const failed = [];
  const flags = flagsRes && !flagsRes.error && flagsRes.data && Array.isArray(flagsRes.data.flags) ? flagsRes.data.flags : null;
  if (!flags) failed.push('flags');
  const rows = STATE_PATHS.map((p) => {
    if (p.kind === 'flag') {
      if (!flags) return { ...p, mode: 'unread', source: `read failed: ${errText(flagsRes)}`, updated_at: null };
      const f = flags.find((x) => x.name === p.name);
      if (!f) return { ...p, mode: 'file', source: 'no row', updated_at: null };
      const active = Number(f.active);
      if (f.active === null || f.active === '' || (active !== 0 && active !== 1)) {
        return { ...p, mode: 'unread', source: `row active=${f.active} unreadable`, updated_at: f.updated_at || null };
      }
      return { ...p, mode: active === 1 ? p.onMode : 'file', source: `row active=${active}`, updated_at: f.updated_at || null };
    }
    const res = settingRes ? settingRes[p.name] : null;
    const state = rowsOnlyState(res);
    if (state === 'unread') {
      failed.push(p.name);
      return { ...p, mode: 'unread', source: `read failed: ${errText(res)}`, updated_at: null };
    }
    const s = res.data.setting;
    if (!s) return { ...p, mode: 'file', source: 'no row (box env decides)', updated_at: null };
    return { ...p, mode: state === 'on' ? p.onMode : 'file', source: `setting=${s.value}`, updated_at: s.updated_at || null };
  });
  return { rows, failed };
}
