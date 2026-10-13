// Cloudflare Pages Function: /api/ideas/* -> the console worker's own D1.
//
// The IDEAS screen is the port of the old console's /product view: the weekly
// product proposals, their PRD excerpt, their mockup shots and the idea chat.
// That data arrives as cockpit beats (bin/run-product.sh -> bin/beat.sh ->
// POST /api/beat; bin/push-proposal-assets.sh -> POST /api/proposal-asset) and
// the console worker stores it in harness-console-db: `proposals`,
// `proposal_assets`, `proposal_chats`.
//
// WHY D1 AND NOT A PROXY. The coord function next door forwards to a worker
// because harness-jobs exposes a JSON API. The console worker does not: its
// /product view is server-rendered HTML and there is no read endpoint for
// proposals (probed: every /api/dash/* name for it answers 404, while a real
// route answers 403 off-cookie). Scraping that HTML would be a data source
// nobody could change safely, and the worker is not ours to extend from here,
// so this reads the rows the worker already stores — the same beats, one hop
// earlier. Reads only: every statement in this file is a SELECT.
//
// AUTHORISATION IS DELEGATED, ON PURPOSE — same rule as functions/api/coord/.
// The `dash` cookie is minted and validated by the console worker; this
// function does not learn its shape. The incoming cookie is presented to the
// console worker's own authed endpoint and only a 200 buys the read, so there
// is one definition of "signed in" and rotating DASH_SECRET revokes this in
// the same moment. (The helper is inlined rather than shared with coord: that
// file is on another branch's critical path, and a copied 20 lines is cheaper
// than a merge conflict in the jobs proxy.)
//
// Binding this needs (Pages project -> Settings -> Bindings -> D1):
//   CONSOLE_DB -> harness-console-db
// Without it every call answers 503 saying that, rather than 401ing as though
// the operator were signed out.

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
    // The console being unreachable is NOT a grant. It fails closed.
    ok = false;
  }
  seen.set(cookie, { ok, at: now });
  return ok;
}

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
  });

// A project name and a slug become the two halves of a pkey. They arrive from
// the URL, so they are untrusted: refuse anything outside the character set the
// harness itself mints (bin/run-product.sh slugs, fleet.conf project names)
// rather than sanitising it into something that still queries.
const SAFE = /^[A-Za-z0-9._-]+$/;
const pkeyFor = (project, slug) => `prop:${project}:${slug}`;

// The columns the list needs. `detail` (the PRD excerpt, ~7KB a row) is left
// out on purpose — 200 proposals of it is a megabyte nobody scrolled to.
const LIST_COLUMNS = `p.pkey, p.project, p.slug, p.title, p.summary,
  p.impact, p.effort, p.confidence, p.score, p.status, p.rev,
  p.department, p.role, p.process, p.aaa, p.dus, p.dus_why,
  p.mockup_url, p.ticket_key, p.ticket_url, p.created_at, p.updated_at,
  CASE WHEN p.detail IS NULL OR p.detail = '' THEN 0 ELSE 1 END AS has_prd,
  (SELECT COUNT(*) FROM proposal_assets a WHERE a.pkey = p.pkey) AS shots,
  (SELECT COUNT(*) FROM proposal_chats c WHERE c.pkey = p.pkey) AS chat_turns`;

async function listProposals(db, url) {
  const where = [];
  const binds = [];
  const project = url.searchParams.get('project');
  const status = url.searchParams.get('status');
  if (project) { where.push('p.project = ?'); binds.push(project); }
  if (status) { where.push('p.status = ?'); binds.push(status); }
  const limitRaw = Number(url.searchParams.get('limit') || 500);
  const limit = Number.isFinite(limitRaw) ? Math.min(Math.max(Math.trunc(limitRaw), 1), 1000) : 500;

  const sql = `SELECT ${LIST_COLUMNS} FROM proposals p
    ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
    ORDER BY p.updated_at DESC LIMIT ?`;
  const { results } = await db.prepare(sql).bind(...binds, limit).all();
  return json({
    proposals: results || [],
    // The list is capped, so say when the cap is what ended it rather than
    // letting a truncated set read as the whole set.
    truncated: (results || []).length === limit,
    generated_at: new Date().toISOString()
  });
}

async function oneProposal(db, project, slug) {
  const pkey = pkeyFor(project, slug);
  const proposal = await db
    .prepare(`SELECT ${LIST_COLUMNS}, p.detail, p.notes FROM proposals p WHERE p.pkey = ?`)
    .bind(pkey)
    .first();
  if (!proposal) return json({ error: 'no such proposal' }, 404);

  // The screenshots are ~250KB of base64 each; the list of what EXISTS travels
  // in the JSON, the bytes come from /api/ideas/asset/... as a real image.
  const assets = await db
    .prepare('SELECT kind, updated_at, length(b64) AS b64_len FROM proposal_assets WHERE pkey = ? ORDER BY kind')
    .bind(pkey)
    .all();
  const chat = await db
    .prepare('SELECT id, role, body, origin, idea_updated, created_at FROM proposal_chats WHERE pkey = ? ORDER BY id ASC')
    .bind(pkey)
    .all();

  return json({
    proposal,
    assets: assets.results || [],
    chat: chat.results || [],
    generated_at: new Date().toISOString()
  });
}

// base64 -> bytes, in chunks: atob on a 370KB string is fine, but building the
// byte array one push at a time is not, and neither is a 370KB argument list to
// String.fromCharCode.apply.
function bytesFromB64(b64) {
  const bin = atob(b64.replace(/\s+/g, ''));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function asset(db, project, slug, kind) {
  if (kind !== 'desktop' && kind !== 'mobile') return json({ error: 'kind must be desktop or mobile' }, 400);
  const row = await db
    .prepare('SELECT b64, updated_at FROM proposal_assets WHERE pkey = ? AND kind = ?')
    .bind(pkeyFor(project, slug), kind)
    .first();
  if (!row || !row.b64) return json({ error: 'no such asset' }, 404);
  let bytes;
  try {
    bytes = bytesFromB64(row.b64);
  } catch {
    // A row that will not decode is a broken upload, not a missing one. Say so.
    return json({ error: 'stored asset is not decodable base64' }, 502);
  }
  return new Response(bytes, {
    headers: {
      'content-type': 'image/png',
      'content-length': String(bytes.length),
      // Private: it rides a session, so it must never land in a shared cache.
      'cache-control': 'private, max-age=300',
      'last-modified': row.updated_at || ''
    }
  });
}

export async function onRequest(context) {
  const { request, env, params } = context;
  const url = new URL(request.url);

  if (!env.CONSOLE_DB) {
    return json({
      error: 'CONSOLE_DB is not bound on this Pages project — the IDEAS view has no proposals database to read (bind D1 harness-console-db as CONSOLE_DB)'
    }, 503);
  }

  const cookie = request.headers.get('cookie') || '';
  if (!(await signedIn(cookie))) {
    // The same shape src/api.js already treats as "not signed in".
    return json({ error: 'unauthorized' }, 403);
  }

  // Read-only by construction: the gate decisions (approve / kill / revise)
  // still belong to the old console, which mints them as `commands` rows the
  // boxes claim. Nothing here writes, so nothing here can mint one.
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return json({ error: `method ${request.method} not allowed on /api/ideas — this view is read-only` }, 405);
  }

  const parts = (Array.isArray(params.path) ? params.path : [params.path || ''])
    .filter((s) => s !== undefined && s !== null && s !== '');

  try {
    if (parts.length === 0 || (parts.length === 1 && parts[0] === 'proposals')) {
      return await listProposals(env.CONSOLE_DB, url);
    }
    if (parts.length === 3 && parts[0] === 'proposals') {
      const [, project, slug] = parts;
      if (!SAFE.test(project) || !SAFE.test(slug)) return json({ error: 'bad project or slug' }, 400);
      return await oneProposal(env.CONSOLE_DB, project, slug);
    }
    if (parts.length === 4 && parts[0] === 'asset') {
      const [, project, slug, kind] = parts;
      if (!SAFE.test(project) || !SAFE.test(slug)) return json({ error: 'bad project or slug' }, 400);
      return await asset(env.CONSOLE_DB, project, slug, kind);
    }
    return json({ error: `no such ideas route: /api/ideas/${parts.join('/')}` }, 404);
  } catch (e) {
    // A D1 error is the database's answer, not a signed-out answer: keep them
    // distinguishable or the screen tells the operator to log in again forever.
    return json({ error: `proposals database read failed — ${e && e.message ? e.message : 'unknown error'}` }, 502);
  }
}
