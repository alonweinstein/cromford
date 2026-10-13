import { backupBadge } from './backups.js';

// BH-1945 (BH-1909.3) — what the HUB screen reads out of GET /api/hub/recovery
// and what it sends to POST /api/hub/promote. The shapes are the BH-1942
// contract in worker/jobs/src/routes/hub-recovery.js; nothing here imports
// preact, so every rule the screen shows is testable on its own.

export const STANDBY_NONE = 'Standby: none recorded (#401)';

const parseTs = (v) => {
  if (typeof v !== 'string' || v === '') return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
};

// leaseView(lease, now) -> null | { holder, epoch, expiresAt, remainingS, expired }
// remainingS is null when expires_at does not parse: an unknown expiry is not
// "0 seconds left", which would paint a live lease EXPIRED (D11).
export function leaseView(lease, now) {
  if (!lease || typeof lease !== 'object') return null;
  const exp = parseTs(lease.expires_at);
  const remainingS = exp === null ? null : Math.max(0, Math.floor((exp - now) / 1000));
  return {
    holder: lease.holder ?? null,
    epoch: lease.epoch ?? null,
    expiresAt: lease.expires_at ?? null,
    remainingS,
    expired: lease.live === false || remainingS === 0
  };
}

// roleView(recovery, now) -> { active, expiredHolder, standby, standbyNote }
// The contract says standby is a string[]; null, missing and [] all mean the
// same thing today (#401 records none), and all three say so.
export function roleView(recovery, now) {
  const role = (recovery && recovery.role) || {};
  const lease = leaseView(recovery && recovery.lease, now);
  const standby = Array.isArray(role.standby) ? role.standby : [];
  return {
    active: role.active ?? null,
    expiredHolder: lease && lease.expired ? lease.holder : null,
    standby,
    standbyNote: standby.length ? null : STANDBY_NONE
  };
}

// backupEntry(row, now) -> the { state, backup_age_min } shape backupBadge
// reads. The box_status columns are TEXT: backup_off 'off', backup_unconfigured
// 'unconfigured', backup_ts '' = never stamped. An empty stamp is "missing"
// only for a box that has reported at all; a box that never reported is
// silence, and silence is `unknown`, not NO BACKUP. So is a stamp that does
// not parse.
export function backupEntry(row, now) {
  if (!row || typeof row !== 'object') return { state: 'unknown' };
  if (row.backup_off) return { state: 'off' };
  if (row.backup_unconfigured) return { state: 'unconfigured' };
  const ts = parseTs(row.backup_ts);
  if (ts !== null) return { state: 'ok', backup_age_min: Math.max(0, Math.floor((now - ts) / 60000)) };
  if ((row.backup_ts === '' || row.backup_ts === null || row.backup_ts === undefined) && row.backup_reported_at) {
    return { state: 'missing' };
  }
  return { state: 'unknown' };
}

// backupRows(recovery, now) -> [{ box, state, badge, ageMin, reportedAt, reportedMin }]
// `badge` is backupBadge's own answer, so a pill here reads exactly like the
// Fleet tile's. The stale threshold is the payload's when it carries one;
// backupBadge type-checks it and falls back to its documented default.
export function backupRows(recovery, now) {
  const list = recovery && Array.isArray(recovery.backups) ? recovery.backups : [];
  const staleMin = recovery ? recovery.backup_stale_min : undefined;
  return list.map((row) => {
    const entry = backupEntry(row, now);
    const reported = parseTs(row && row.backup_reported_at);
    return {
      box: row && row.box,
      state: entry.state,
      badge: backupBadge(entry, staleMin),
      ageMin: entry.state === 'ok' ? entry.backup_age_min : null,
      reportedAt: (row && row.backup_reported_at) || null,
      reportedMin: reported === null ? null : Math.max(0, Math.floor((now - reported) / 60000))
    };
  });
}

// The boxes a promote may name: every box that reported, minus the holder.
export function promoteTargets(recovery) {
  const holder = recovery && recovery.lease ? recovery.lease.holder : null;
  const list = recovery && Array.isArray(recovery.backups) ? recovery.backups : [];
  const boxes = list.map((r) => r && r.box).filter((b) => typeof b === 'string' && b && b !== holder);
  return [...new Set(boxes)];
}

// promoteFormState(form, targets) -> { blocked, hint }. The typed name must be
// the chosen box EXACTLY: no trim, no case fold, no prefix. The reason lands
// in the hub_lease_changes audit row, so a blank one is refused.
export function promoteFormState(form, targets) {
  const f = form || {};
  if (!f.target || !(targets || []).includes(f.target)) return { blocked: true, hint: 'Choose the box to promote.' };
  if (typeof f.reason !== 'string' || !f.reason.trim()) return { blocked: true, hint: 'A reason is required: it is recorded on the lease change.' };
  if (f.typed !== f.target) return { blocked: true, hint: `Type ${f.target} exactly to confirm.` };
  return { blocked: false, hint: null };
}

export function promoteBody(target, expectedEpoch, reason) {
  return { target, expected_epoch: expectedEpoch, actor: 'console', reason: String(reason).trim(), confirm: true };
}

// promoteOutcome(err) -> the line a failed promote shows. Matched narrowly
// (D10): only a 409 whose error is stale_epoch says the lease moved, and only
// a lease the answer actually carries is named (D26). "Nothing was changed" is
// said only for the refusals the contract makes before any write (400, 409),
// the proxy's 405 and the stub's 501; past those the write is unknown.
export function promoteOutcome(err) {
  const status = err && err.status;
  const body = err && err.body;
  const reason = (body && body.error) || (err && err.message) || 'error';
  if (status === 409 && body && body.error === 'stale_epoch') {
    const l = body.lease;
    const now = l && l.epoch !== undefined && l.epoch !== null && l.holder ? ` (now epoch ${l.epoch} held by ${l.holder})` : '';
    return `The lease moved since you loaded this page${now}. Reload and check before promoting.`;
  }
  if (status === 405) return 'The console proxy does not allow promote yet (405). Nothing was changed.';
  if (status === 501) return 'Promote is not deployed yet (501). Nothing was changed.';
  if (status === 400 || status === 409) return `Promote refused: ${reason} (http ${status}). Nothing was changed.`;
  if (typeof status === 'number') return `Promote failed: ${reason} (http ${status}). Reload to check the lease before trying again.`;
  return `Promote result unknown: ${reason}. Reload to check the lease before trying again.`;
}

// promoteResult(res) -> { ok, text } for a 2xx answer. Success is ok:true and
// nothing else; before/after are named only when the answer carries them.
export function promoteResult(res) {
  if (!res || res.ok !== true) {
    return { ok: false, text: 'Promote answered without ok:true. Reload to check the lease before trying again.' };
  }
  const b = res.before;
  const a = res.after;
  if (b && a && b.holder && a.holder) return { ok: true, text: `Promoted: ${b.holder}@${b.epoch} → ${a.holder}@${a.epoch}` };
  return { ok: true, text: 'Promoted. Reload shows the new lease.' };
}

export function loadError(err) {
  if (err && err.status === 501) return 'The hub recovery API is not deployed yet (501).';
  return String(err && err.message ? err.message : err);
}

// createLoader(fetcher, onState, clock) -> load(). Each load aborts the one
// before it and a superseded answer that lands late is dropped, so RELOAD can
// never be overwritten by the slower answer it replaced. api.hubRecovery takes
// no signal, so the abort is request versioning rather than a network cancel;
// a fetcher that does take one gets it.
export function createLoader(fetcher, onState, clock = Date.now) {
  let seq = 0;
  let ctrl = null;
  return function load() {
    if (ctrl) ctrl.abort();
    const mine = ++seq;
    const c = new AbortController();
    ctrl = c;
    onState({ loading: true });
    const live = () => mine === seq && !c.signal.aborted;
    return Promise.resolve()
      .then(() => fetcher(c.signal))
      .then(
        (data) => { if (live()) onState({ data, error: null, loading: false, fetchedAt: clock() }); },
        (error) => { if (live()) onState({ data: null, error, loading: false, fetchedAt: clock() }); }
      );
  };
}
