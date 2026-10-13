// Cloudflare Pages Function: /login/<DASH_SECRET>.
//
// The worker answers with a 302 and the `dash` cookie. We forward the request,
// keep the Set-Cookie (so the cookie is scoped to THIS origin, which is the
// whole point of the proxy), and rewrite the Location to "/" so the operator
// lands on the SPA rather than on the worker's own HTML view.
//
// The secret only ever travels in this one request path; it is never rendered,
// stored in JS, or echoed back in any response.

const WORKER = 'https://harness-console.operator.workers.dev';

export async function onRequest(context) {
  const { request, params } = context;
  const secret = Array.isArray(params.secret) ? params.secret[0] : params.secret;

  const headers = new Headers(request.headers);
  headers.delete('host');
  headers.delete('accept-encoding');

  let upstream;
  try {
    upstream = await fetch(`${WORKER}/login/${encodeURIComponent(secret)}`, {
      method: request.method,
      headers,
      redirect: 'manual'
    });
  } catch (e) {
    return new Response('console worker unreachable', { status: 502 });
  }

  const out = new Headers(upstream.headers);
  out.delete('content-encoding');
  out.delete('content-length');

  if (upstream.status >= 300 && upstream.status < 400) {
    out.set('location', '/');
    return new Response(null, { status: 302, headers: out });
  }

  // A wrong secret gets the worker's own answer through unchanged — we do not
  // invent a friendlier one, because "it worked" must never be guessable.
  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: out
  });
}
