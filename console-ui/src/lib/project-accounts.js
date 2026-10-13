// Which Claude account each fleet project bills (BH-1657). The assignment is a
// settings row `account.<project>` whose value is an account LABEL (the name of
// a token file under accounts.d on each box), never a token. `shared` is the
// explicit unpin: the worker refuses an empty value and has no DELETE.
//
// Pure helpers, so the rows, the label rule and the write path are tested
// without a browser; src/screens/ProjectAccounts.js renders them.

import { ACTOR } from './settings.js';

export const ACCOUNT_KEY_PREFIX = 'account.';
export const SHARED = 'shared';
// The worker's rule (worker/jobs/src/routes/settings.js), mirrored so the
// operator sees the refusal before anything is sent.
const LABEL_RE = /^[A-Za-z0-9][A-Za-z0-9:._@-]{0,63}$/;

// checkAccountLabel(raw) -> { ok: true, value } | { ok: false, message }.
// The message never repeats the value: a pasted token must not be echoed.
export function checkAccountLabel(raw) {
  const value = String(raw === null || raw === undefined ? '' : raw).trim();
  if (!value) return { ok: false, message: `type an account label, or ${SHARED} to unpin` };
  if (value === SHARED) return { ok: true, value };
  if (/^sk-/i.test(value)) {
    return { ok: false, message: 'that looks like a token — an account is set by its label, and the token stays on the box' };
  }
  if (!LABEL_RE.test(value) || value.includes('..')) {
    return { ok: false, message: 'a label is letters, digits and : . _ @ - (at most 64), with no ..' };
  }
  return { ok: true, value };
}

// accountRows(settingsRows, projects) -> one row per project, from the union of
// the fleet's projects and the account.* rows (a pin on a project that left the
// fleet still shows, so it can be seen and cleared). label is null for the
// shared pool, whether no row exists or the row says `shared`.
export function accountRows(settingsRows, projects) {
  const list = Array.isArray(settingsRows) ? settingsRows
    : (settingsRows && Array.isArray(settingsRows.settings) ? settingsRows.settings : []);
  const byProject = new Map();
  for (const r of list) {
    if (!r || typeof r.key !== 'string' || !r.key.startsWith(ACCOUNT_KEY_PREFIX)) continue;
    byProject.set(r.key.slice(ACCOUNT_KEY_PREFIX.length), r);
  }
  const names = new Set([...(Array.isArray(projects) ? projects : []), ...byProject.keys()]);
  return [...names].filter(Boolean).sort().map((project) => {
    const r = byProject.get(project) || null;
    const v = r && typeof r.value === 'string' ? r.value : null;
    return {
      project,
      label: v && v !== SHARED ? v : null,
      actor: r ? r.actor || null : null,
      updated_at: r ? r.updated_at || null : null,
      href: `/settings?project=${encodeURIComponent(project)}`,
    };
  });
}

// The write path: validate, confirm in the in-app modal, PUT, refresh. Every
// outcome is a status to render (cancelled, invalid, failed, written).
export function makeAccountSetter({ confirm, writeSetting, refresh, onNote }) {
  const note = (ok, text) => { if (onNote) onNote({ ok, text }); };
  return {
    async set(row, raw) {
      const v = checkAccountLabel(raw);
      if (!v.ok) { note(false, v.message); return { status: 'invalid', message: v.message }; }
      const unpin = v.value === SHARED;
      const ok = await confirm({
        title: unpin ? 'UNPIN THIS PROJECT?' : 'PIN THIS PROJECT?',
        body: unpin
          ? `${row.project} goes back to the shared pool: its Claude calls are routed across the shared accounts again.`
          : `${row.project} will bill account ${v.value}. Every box runs its Claude calls on that account's token and never falls back to the shared accounts; a box without the token skips Claude for it.`,
        confirmLabel: unpin ? 'UNPIN' : 'PIN',
      });
      if (!ok) return { status: 'cancelled' };
      try {
        await writeSetting({ key: `${ACCOUNT_KEY_PREFIX}${row.project}`, value: v.value, actor: ACTOR });
      } catch (e) {
        const message = `${row.project} account refused — ${e && e.message ? e.message : e}`;
        note(false, message);
        return { status: 'failed', message };
      }
      if (refresh) refresh();
      note(true, unpin ? `${row.project} is back on the shared pool.` : `${row.project} now bills ${v.value}.`);
      return { status: 'written' };
    },
  };
}
