// BH-2518.4: the console's half of a box/machine op. The console only ever
// REQUESTS a command (POST /api/coord/box-commands); the box's own box-ops lane
// runs it later. So nothing here may say an op is done, and nothing may be
// guessed: a blank reason, an unknown type or a Fly target we cannot name is
// refused, never filled in.

export const BOX_COMMAND_TYPES = ['backup_now', 'harness_sync', 'cli_update', 'fly_machine_stop', 'fly_machine_destroy'];
export const FLY_TYPES = ['fly_machine_stop', 'fly_machine_destroy'];

export const COMMAND_LABELS = {
  backup_now: 'BACKUP NOW',
  harness_sync: 'SYNC',
  cli_update: 'CLI UPDATE',
  fly_machine_stop: 'STOP',
  fly_machine_destroy: 'DESTROY'
};

const STATUS_RANK = { requested: 0, claimed: 1, fail: 2, ok: 3 };

const blank = (v) => typeof v !== 'string' || !v.trim();

// The exact POST body, or { error } when any part of it would be a guess.
export function boxCommandFor(type, { box, reason, project, app, machineId } = {}) {
  if (!BOX_COMMAND_TYPES.includes(type)) return { error: `unknown type ${type}` };
  if (blank(reason)) return { error: 'reason required' };
  if (FLY_TYPES.includes(type)) {
    for (const [field, v] of [['project', project], ['app', app], ['machineId', machineId]]) {
      if (blank(v)) return { error: `${field} required` };
    }
    return { box: 'hub', type, target: machineId.trim(), project: project.trim(), app: app.trim(), reason: reason.trim(), confirm: true };
  }
  if (blank(box)) return { error: 'box required' };
  return { box: box.trim(), type, target: '', project: '', app: '', reason: reason.trim(), confirm: true };
}

// The Fly app a machine lives in: its own, else the project's only app. With
// no app and zero or several candidates it is unknown (null), never picked.
export function flyAppFor(machine, apps) {
  if (machine && typeof machine.app === 'string' && machine.app.trim()) return machine.app;
  return Array.isArray(apps) && apps.length === 1 ? apps[0] : null;
}

export function flyStopText(r, app) {
  const job = r && r.job ? (r.job.key || r.job.ticket_id) : null;
  return `Stop machine ${r.id} in ${app}?` + (job ? ` It is building ${job}. Stopping it kills that build.` : '');
}

export function flyDestroyText(r, app) {
  return `Destroy machine ${r.id} in ${app}? This cannot be undone. The machine and its disk are deleted.`;
}

// What the banner says after a 2xx. It is a request rung, so "queued".
export function boxCommandResultText(res, box) {
  return res && res.deduped === true ? `already queued (#${res.id})` : `queued for ${box}`;
}

// Confirm first, then build the body, then post. `ask(form)` resolves true
// only on CONFIRM and writes the typed reason into form.reason. Returns null
// on cancel (nothing sent) or { ok, text } for the banner.
export async function requestBoxCommand(type, ctx, { ask, post }) {
  const label = COMMAND_LABELS[type] || type;
  const form = { reason: '' };
  const confirmed = await ask(form);
  if (!confirmed) return null;
  const cmd = boxCommandFor(type, { ...ctx, reason: form.reason });
  if (cmd.error) return { ok: false, text: `${label} refused: ${cmd.error}` };
  try {
    const res = await post(cmd);
    return { ok: true, text: boxCommandResultText(res, cmd.box) };
  } catch (e) {
    return { ok: false, text: `${label} failed: ${e && e.message ? e.message : String(e)}` };
  }
}

// GET /api/coord/box-commands -> table rows. An unreadable payload throws so
// the screen shows an error, never "no box commands yet".
export function shapeBoxCommands(payload, now = Date.now()) {
  if (!payload || typeof payload !== 'object' || !Array.isArray(payload.commands)) {
    throw new Error('box commands: unreadable payload');
  }
  const rows = payload.commands.map((c) => {
    const t = typeof c.requested_at === 'string' ? Date.parse(c.requested_at) : NaN;
    return {
      ...c,
      ageMin: Number.isFinite(t) ? Math.max(0, Math.floor((now - t) / 60000)) : null,
      statusRank: Object.prototype.hasOwnProperty.call(STATUS_RANK, c.status) ? STATUS_RANK[c.status] : 4
    };
  });
  return { rows, truncated: payload.truncated === true, asOf: payload.as_of || null };
}
