// The QA session (cromford #5909): browser QA of a console PREVIEW signs
// in with a read-only `dashqa` cookie that the hub mints from the console
// worker (POST /api/qa/session, Bearer HARNESS_SECRET), never with the
// operator's login link. The worker accepts `dashqa` for GET and HEAD only.
//
// The Pages Functions that WRITE on their own bindings (the coordination view's
// PUT/POST to the jobs worker under this project's HARNESS_SECRET, and the
// board-command fallback into CONSOLE_DB) authenticate with a GET probe to the
// worker, which a QA session passes. So each of them asks qaOnly() first and
// refuses a write from a QA session before it does anything.

// qaOnly <cookie header> — true when the request carries a `dashqa` cookie and
// no operator `dash` cookie.
export function qaOnly(cookie) {
  const c = String(cookie || '');
  return /(?:^|;\s*)dashqa=/.test(c) && !/(?:^|;\s*)dash=/.test(c);
}

// readOnlyRefusal <request> — a 403 Response for any write that carries a
// `dashqa` cookie, or null. Any, not only a QA-only one: unreviewed preview JS
// can set `dash=x` beside the HttpOnly dashqa, and that must not unlock a write.
export function readOnlyRefusal(request) {
  const m = String(request.method || 'GET').toUpperCase();
  if (m === 'GET' || m === 'HEAD') return null;
  if (!/(?:^|;\s*)dashqa=/.test(String(request.headers.get('cookie') || ''))) return null;
  return new Response(JSON.stringify({ error: 'a QA session is read-only' }), {
    status: 403, headers: { 'content-type': 'application/json' }
  });
}
