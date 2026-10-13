// Cloudflare Pages Function: /api/outcomes/* -> the harness-jobs worker's
// metrics + review-gate tables.
//
// The OUTCOMES screen asks one question the rest of Mission Control does not:
// did the work HOLD? Its answer is spread over five tables in harness-jobs —
// outcome_metrics (what came back), ledgers kind=merge (what we landed),
// pr_costs (what each landing cost), burn_days (what the fleet burns), and
// review_gate (which repos the steering rule has parked). The screen needs all
// five at once to say anything true, so this function fans out ONCE and hands
// back one payload rather than making the browser open five same-origin polls
// that can each land in a different second.
//
// GET-ONLY, AND THAT IS THE POINT. The coord proxy next door forwards a PUT for
// the pause flags because the console legitimately toggles them. Nothing on the
// outcomes screen writes: a dashboard that could flip its own gate would be a
// second, unreviewed merge path. Every other method is 405 here, so that
// property is enforced by the runtime and not by the UI's good manners.
//
// AUTHORISATION IS DELEGATED, ON PURPOSE — same rule as functions/api/coord/
// and functions/api/ideas/. The `dash` cookie is minted and validated by the
// console worker and this function does not learn its shape; the incoming
// cookie is presented to the console worker's own authed endpoint and only a
// 200 buys the read. One definition of "signed in", and rotating DASH_SECRET
// revokes this in the same moment. The helper is inlined rather than shared
// with coord for the reason that file already gives: a copied 20 lines is
// cheaper than a merge conflict in the jobs proxy.
//
// Env this needs (Pages project -> Settings -> Environment variables):
//   HARNESS_SECRET  — same value as the boxes' env/global.env
// Without it every call answers 503 with that in the body, rather than 401ing
// as though the operator were signed out.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const AUTH_PROBE = '/api/dash/fleet';

const seen = new Map();
const TTL_MS = 60000;

async function signedIn(cookie) {
  if (!cookie) return false;
  const now = Date.now();
  const hit = seen.get(cookie);
  if (hit && now - hit.at < TTL_MS) return hit.ok;
  let ok = false;
  try {
    const res = await fetch(CONSOLE + AUTH_PROBE, { headers: { cookie }, redirect: 'manual' });
    ok = res.status === 200;
  } catch {
    // The console being unreachable is NOT a grant. It fails closed: an
    // operator sees "could not verify the session", never someone else's data.
    ok = false;
  }
  seen.set(cookie, { ok, at: now });
  return ok;
}

// The five reads, and the key each one's rows arrive under. Limits are stated
// here rather than passed in: this is a fleet-wide dashboard on a 60s refresh,
// not a pagination surface, and a caller-supplied limit would be one more thing
// that can quietly ask for 100x the payload.
const READS = [
  ['outcomes', '/api/metrics/outcomes?limit=500', 'outcomes'],
  ['merges', '/api/ledger?kind=merge&limit=500', 'ledgers'],
  ['pr_costs', '/api/metrics/pr-costs?limit=500', 'pr_costs'],
  ['burn_days', '/api/metrics/burn?days=90', 'burn_days'],
  ['gates', '/api/review-gate', 'gates']
];

export async function onRequest(context) {
  const { request, env } = context;

  if (!env.HARNESS_SECRET) {
    return new Response(JSON.stringify({
      error: 'HARNESS_SECRET is not set on this Pages project — the outcomes view cannot authenticate to harness-jobs'
    }), { status: 503, headers: { 'content-type': 'application/json' } });
  }

  const cookie = request.headers.get('cookie') || '';
  if (!(await signedIn(cookie))) {
    // The same shape src/api.js already treats as "not signed in".
    return new Response(JSON.stringify({ error: 'unauthorized' }), {
      status: 403, headers: { 'content-type': 'application/json' }
    });
  }

  if (request.method !== 'GET') {
    return new Response(JSON.stringify({ error: `method ${request.method} not allowed — the outcomes view is read-only` }), {
      status: 405, headers: { 'content-type': 'application/json' }
    });
  }

  const headers = { authorization: `Bearer ${env.HARNESS_SECRET}` };
  const one = async ([key, path, field]) => {
    try {
      const res = await fetch(JOBS + path, { headers });
      if (!res.ok) return { key, rows: [], extra: null, why: `http ${res.status}` };
      const body = await res.json();
      return {
        key,
        rows: Array.isArray(body[field]) ? body[field] : [],
        // The review-gate read carries its thresholds in the same response on
        // purpose (see the worker's handler): a rate rendered beside a
        // threshold it was never judged against is the one way this screen
        // could lie, so the two never travel separately.
        extra: key === 'gates' && Array.isArray(body.thresholds) ? body.thresholds : null,
        why: null
      };
    } catch {
      return { key, rows: [], extra: null, why: 'unreachable' };
    }
  };

  const settled = await Promise.all(READS.map(one));

  // PARTIAL FAILURE IS NAMED, NEVER SWALLOWED. A screen that renders an empty
  // revert-rate column because one upstream read 500'd would read as "nothing
  // came back", which is the opposite of what happened. Every failed read lands
  // in `degraded` and the screen says so above the table.
  const out = { as_of: new Date().toISOString(), degraded: [] };
  for (const s of settled) {
    out[s.key] = s.rows;
    if (s.key === 'gates') out.thresholds = s.extra || [];
    if (s.why) out.degraded.push(`${s.key}: ${s.why}`);
  }

  // Everything failing is not a degraded view, it is no view.
  if (out.degraded.length === READS.length) {
    return new Response(JSON.stringify({ error: 'harness-jobs unreachable' }), {
      status: 502, headers: { 'content-type': 'application/json' }
    });
  }

  return new Response(JSON.stringify(out), {
    status: 200,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
  });
}
