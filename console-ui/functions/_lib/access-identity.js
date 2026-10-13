// Who is making this console write (BH-2515). Not a route: Pages only routes
// files that export onRequest*, and this one never does.
//
// Cloudflare Access, when it sits in front of the console host, adds two
// headers to every request it lets through: Cf-Access-Authenticated-User-Email
// and Cf-Access-Jwt-Assertion, a JWT it signs for the application. The email
// header alone proves nothing: on a hostname Access does not cover (the
// *.pages.dev one) anyone can send it. So the email is trusted only when the
// assertion verifies RS256 against the team's published certs, is for this
// application's AUD, was issued by this team, has not expired, and its email
// claim is the header's email. Anything short of that records 'console'.
//
// Env (Pages project -> Settings -> Environment variables), both required:
//   CF_ACCESS_TEAM_DOMAIN — e.g. <team>.cloudflareaccess.com
//   CF_ACCESS_AUD         — the Access application's AUD tag
// Either one unset means Access is off for this console: every write records
// 'console', and the top bar says so.
//
// resolveIdentity never refuses anything. The `dash` cookie is still the gate;
// identity only decides the name a write carries.

export const FALLBACK_ACTOR = 'console';
// The jobs worker's alert routes accept only this charset for an actor (a
// colon is a 400), so a verified email outside it cannot be recorded as-is.
// Lower-case because the email is normalised once, here.
export const ACTOR_RE = /^[a-z0-9._@-]{1,96}$/;

const CERTS_TTL_MS = 10 * 60 * 1000;
const CERTS_TIMEOUT_MS = 3000;
const REFETCH_MIN_MS = 60 * 1000;
const SKEW_S = 60;

// A cache of a public document, best-effort per isolate. `tried` is the last
// fetch attempt, good or bad, so a bad certs host or an unknown kid is asked
// again at most once a minute. A fetch is abandoned after CERTS_TIMEOUT_MS
// (BH-2612), so a hanging certs host costs one write 3 s, not the runtime's
// subrequest timeout.
let certs = { team: null, keys: null, at: 0, tried: 0 };
export function _resetCertsCache() { certs = { team: null, keys: null, at: 0, tried: 0 }; }

const norm = (s) => (typeof s === 'string' ? s.trim().toLowerCase() : '');
const teamOf = (v) => norm(v).replace(/^https?:\/\//, '').replace(/\/+$/, '');

function b64uBytes(s) {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}
const b64uJson = (s) => JSON.parse(new TextDecoder().decode(b64uBytes(s)));

async function fetchKeys(team, now) {
  certs = { team, keys: certs.team === team ? certs.keys : null, at: certs.team === team ? certs.at : 0, tried: now };
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), CERTS_TIMEOUT_MS);
  try {
    const res = await fetch(`https://${team}/cdn-cgi/access/certs`, { signal: ac.signal });
    if (!res.ok) return null;
    const doc = await res.json();
    if (!doc || !Array.isArray(doc.keys)) return null;
    certs = { team, keys: doc.keys, at: now, tried: now };
    return doc.keys;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function keyFor(team, kid, now) {
  const fresh = certs.team === team && certs.keys && now - certs.at < CERTS_TTL_MS;
  let keys = fresh ? certs.keys : null;
  const canFetch = certs.team !== team || now - certs.tried >= REFETCH_MIN_MS;
  if (!keys && canFetch) keys = await fetchKeys(team, now);
  let jwk = keys && keys.find((k) => k && k.kid === kid);
  if (!jwk && keys && fresh && canFetch) {
    // A rotated key: the cached set predates it.
    keys = await fetchKeys(team, now);
    jwk = keys && keys.find((k) => k && k.kid === kid);
  }
  return jwk || null;
}

// The verified email claim, or null. Every failure is null: a bad token, an
// unreachable or slow (over 3 s) certs host and a wrong audience all record
// 'console'.
async function verifiedEmail(token, team, aud, now) {
  try {
    const parts = token.split('.');
    if (parts.length !== 3 || !parts[2]) return null;
    const header = b64uJson(parts[0]);
    const claims = b64uJson(parts[1]);
    if (!header || header.alg !== 'RS256' || typeof header.kid !== 'string') return null;
    const jwk = await keyFor(team, header.kid, now);
    if (!jwk || jwk.kty !== 'RSA') return null;
    const key = await crypto.subtle.importKey('jwk', { kty: 'RSA', n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
    const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64uBytes(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
    if (!ok || !claims || typeof claims !== 'object') return null;
    const auds = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (!auds.includes(aud)) return null;
    if (claims.iss !== `https://${team}`) return null;
    const t = now / 1000;
    if (typeof claims.exp !== 'number' || claims.exp + SKEW_S <= t) return null;
    if (claims.nbf != null && (typeof claims.nbf !== 'number' || claims.nbf - SKEW_S > t)) return null;
    return norm(claims.email) || null;
  } catch {
    return null;
  }
}

// -> { actor, access, email }. access is 'on' (verified email is the actor),
// 'off' (Access env unset), 'unverified' (env set, this request proves no one)
// or 'unrecordable' (verified, but the worker cannot store that actor).
export async function resolveIdentity(request, env, now = Date.now()) {
  const team = teamOf(env && env.CF_ACCESS_TEAM_DOMAIN);
  const aud = typeof (env && env.CF_ACCESS_AUD) === 'string' ? env.CF_ACCESS_AUD.trim() : '';
  if (!team || !aud) return { actor: FALLBACK_ACTOR, access: 'off', email: null };
  const unverified = { actor: FALLBACK_ACTOR, access: 'unverified', email: null };
  const header = norm(request.headers.get('cf-access-authenticated-user-email'));
  const token = (request.headers.get('cf-access-jwt-assertion') || '').trim();
  if (!header || !token) return unverified;
  const email = await verifiedEmail(token, team, aud, now);
  if (!email || email !== header) return unverified;
  if (!ACTOR_RE.test(email)) return { actor: FALLBACK_ACTOR, access: 'unrecordable', email };
  return { actor: email, access: 'on', email };
}
