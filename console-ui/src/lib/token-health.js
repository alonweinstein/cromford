// ACCOUNT & TOKEN HEALTH (BH-2516.3 / BH-2647): the pure half of the panel.
// Rows come from GET /api/account-leases/health on the jobs worker, whose
// response shape is the JSDoc on that route. The worker owns the red rule
// (`expiring`); nothing here reads a clock, it only formats.

const KIND_LABEL = { oauth: 'OAuth', gh_app: 'GH App' };

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);

function hm(sec) {
  const m = Math.round(Math.abs(sec) / 60);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

// `in 3h 10m`, `expired 20m ago`, `—` when the expiry is unknown.
export function expiresText(sec) {
  const s = num(sec);
  if (s === null) return '—';
  return s < 0 ? `expired ${hm(s)} ago` : `in ${hm(s)}`;
}

export function healthRows(data) {
  if (!data || typeof data !== 'object' || !Array.isArray(data.accounts)) return [];
  return data.accounts.map((a) => {
    const leases = Array.isArray(a.leases) ? a.leases : [];
    const expiresInS = num(a.expires_in_s);
    return {
      kind: a.kind,
      kindLabel: KIND_LABEL[a.kind] || a.kind,
      subject: a.subject,
      box: a.box || null,
      leases,
      leaseCount: num(a.live_leases) ?? leases.length,
      expiresInS,
      expiresText: expiresText(expiresInS),
      red: a.expiring === true,
      lastOkAt: a.last_ok_at || null,
      // Absent is unknown, not zero: a lease-only account has no report.
      failCount: num(a.fail_count),
      lastError: a.last_error || null,
      noReport: a.reported === false,
    };
  });
}

export function warnNote(data) {
  const h = data ? num(data.warn_h) : null;
  if (h === null) return null;
  return `Red = under ${h} h to expiry (${data.warn_h_source === 'settings' ? 'set in settings' : 'default'})`;
}

export function truncatedNote(data) {
  const t = data && data.truncated;
  return !!t && typeof t === 'object' && Object.values(t).some((v) => v === true);
}
