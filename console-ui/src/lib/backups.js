import { agoFromMinutes } from './format.js';

// BH-399 — how the Fleet screen reads `backups.<box>` out of the hub's
// fleet_status snapshot.
//
// A backup that stopped is the quietest failure in the fleet: nothing errors,
// nothing is late, and the only symptom is the day you need it (#388 is the
// hub's own wipe). So the age gets a place on the box tile — and the states
// that are NOT a problem have to be visibly different from the one that is, or
// the field gets ignored inside a week.
//
// `state` is the hub's closed vocabulary: ok | off | unconfigured | missing |
// unknown. `backup_age_min` exists only when an age is knowable, so a
// fabricated 0 can never render as "backed up just now".

// bin/state-backup.sh runs 5,20,35,50 — 30 minutes is two missed cycles. The
// same number is bin/lib/backup-freshness.sh's BF_DEFAULT_STALE_MIN, and it is
// the FALLBACK here, not the rule: the hub pushes `backup_stale_min` beside the
// ages (bin/fleet-status-push.sh), so raising the operator knob moves the pill
// and the page together. The console cannot reach the knob store itself, and a
// threshold compiled into the bundle would mean a box with no page at 40m
// wearing a red STALE pill at 31m.
export const BACKUP_STALE_MIN = 30;

const UNKNOWN = { text: 'backup —', tone: 'unknown', stale: false, known: false, badge: null,
  title: 'the hub pushed no backup reading for this box' };

// backupBadge(entry, staleMin) -> { text, tone, stale, known, badge, title }
// `badge` is the pill's own words, because "STALE" on a box that has NEVER
// backed up would be the wrong word for the worse problem.
// Never throws, and never invents: anything it does not recognise is `unknown`,
// because silence from the hub is not evidence that a backup is missing.
export function backupBadge(entry, staleMin = BACKUP_STALE_MIN) {
  if (!entry || typeof entry !== 'object') return UNKNOWN;
  // TYPE-CHECKED, NOT COERCED. Number(null) and Number('') are both 0, so a
  // threshold an old hub did not push would become a limit of 0 and mark EVERY
  // box stale — the same "healthy value for the number we alert on" trap as a
  // fabricated age, inverted. A real 0 from the knob is honoured.
  const limit = typeof staleMin === 'number' && Number.isFinite(staleMin) && staleMin >= 0
    ? staleMin : BACKUP_STALE_MIN;
  switch (entry.state) {
    case 'ok': {
      const n = Number(entry.backup_age_min);
      // state ok with no number is not a reading. Rendering it as "now" would
      // be the one lie this whole field exists to prevent.
      if (entry.backup_age_min === null || entry.backup_age_min === undefined || !Number.isFinite(n)) return UNKNOWN;
      const stale = n > limit;
      return {
        text: `backup ${agoFromMinutes(n)}`,
        tone: stale ? 'warn' : 'ok',
        stale,
        known: true,
        badge: stale ? 'STALE' : null,
        title: `last verified off-box copy ${n}m ago (stale past ${limit}m)`
      };
    }
    case 'missing':
      return { text: 'backup never', tone: 'dead', stale: true, known: true, badge: 'NO BACKUP',
        title: 'bin/state-backup.sh has never completed a verified upload from this box' };
    case 'unconfigured':
      // A handoff, not a fault: bin/state-backup.sh says so once per UTC day.
      return { text: 'backup not configured', tone: 'warn', stale: false, known: true, badge: null,
        title: 'the BACKUP_* keys are not set on this box yet' };
    case 'off':
      return { text: 'backup off', tone: 'unknown', stale: false, known: true, badge: null,
        title: 'switched off deliberately (flags/state-backup-off or STATE_BACKUP=0)' };
    default:
      return UNKNOWN;
  }
}
