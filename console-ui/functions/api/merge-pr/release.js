// Cloudflare Pages Function: POST /api/merge-pr/release {id} frees one merge_pr
// command key after a "head moved" refusal (BH-4917).
//
// The console worker hands an existing row under <project>:<ticket>:merge_pr
// back to every later merge_pr, so a terminal head-moved refusal stuck on the
// old head. #4439 renamed it only here in Pages, for a console click carrying
// verdict_sha; a merge_pr from the MCP tool, Telegram or a box command never
// comes through the proxy. The hub poller executes all of them, so after it
// acks `refused: head moved…` it calls this endpoint with the command id
// (bin/lib/merge-pr-release.sh). The write goes through the console's own
// CONSOLE_DB binding, so the hub needs no D1 access (BH-3905 took it away).
//
// Machine-to-machine: the caller presents `Bearer <HARNESS_SECRET>`, the same
// secret the boxes use for the console worker. No dash cookie buys this.
//
// Env this needs (Pages project -> Settings):
//   HARNESS_SECRET  — same value as the boxes' env/global.env
//   CONSOLE_DB      — D1 harness-console-db (already bound for cockpit/ideas)
// Either missing answers 503 naming it, never a silent 200.
//
// Answers: 200 {released: n} (n 0 = nothing to free), 400 bad id or body,
// 401 wrong secret, 405 not a POST, 500 the UPDATE failed.

import { releaseHeadMovedRefusal } from '../../_lib/merge-pr-rekey.js';

const json = (status, body) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function sameSecret(sent, want) {
  if (typeof sent !== 'string' || sent.length !== want.length) return false;
  let d = 0;
  for (let i = 0; i < want.length; i++) d |= sent.charCodeAt(i) ^ want.charCodeAt(i);
  return d === 0;
}

export async function onRequest(context) {
  const { request, env } = context;
  if (request.method !== 'POST') return json(405, { error: `method ${request.method} not allowed` });
  const secret = typeof (env && env.HARNESS_SECRET) === 'string' ? env.HARNESS_SECRET.trim() : '';
  if (!secret) {
    return json(503, { error: 'HARNESS_SECRET is not set on this Pages project — the hub cannot release a merge_pr key' });
  }
  const auth = (request.headers.get('authorization') || '').trim();
  if (!auth.startsWith('Bearer ') || !sameSecret(auth.slice(7).trim(), secret)) {
    return json(401, { error: 'unauthorized' });
  }
  if (!env.CONSOLE_DB) {
    return json(503, { error: 'CONSOLE_DB is not bound on this Pages project — bind D1 harness-console-db as CONSOLE_DB' });
  }
  let body = null;
  try { body = JSON.parse(await request.text()); } catch { body = null; }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return json(400, { error: 'body must be a JSON object {id}' });
  const r = await releaseHeadMovedRefusal(env.CONSOLE_DB, body.id);
  if (r.skipped === 'bad-id') return json(400, { error: 'id must be a positive whole number' });
  if (r.skipped) return json(500, { error: `release failed (${r.skipped})` });
  return json(200, { released: r.released });
}
