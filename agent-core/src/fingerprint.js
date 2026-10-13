// SPDX-License-Identifier: Apache-2.0
// fingerprint: a stable dedup key for an item. Query strings, fragments,
// userinfo and secret-named keys never reach the key.
//
// The key is a contract: every stored claim is keyed by it. A change to the
// canonical form below re-keys every claim, so it needs a migration note.
import { sha256 } from './sha256.js';

const SECRET_KEY = /^(token|access_token|auth|authorization|sig|signature|secret|password|key|api_key|expires|x-amz-.*)$/i;

export function canonicalUrl(s) {
  const t = String(s).trim();
  let u;
  try { u = new URL(t); } catch { return t; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return t;
  let path = u.pathname;
  if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
  return `${u.protocol}//${u.host.toLowerCase()}${path}`;
}

function isPlainObject(v) {
  if (v === null || typeof v !== 'object') return false;
  const proto = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
}

function canonical(v) {
  if (typeof v === 'string') return JSON.stringify(canonicalUrl(v));
  if (typeof v === 'boolean') return JSON.stringify(v);
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) throw new TypeError('fingerprint: non-finite number');
    return JSON.stringify(v);
  }
  if (v === null) return 'null';
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (isPlainObject(v)) {
    const keys = Object.keys(v).filter((k) => !SECRET_KEY.test(k)).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`;
  }
  throw new TypeError(`fingerprint: cannot key a value of type ${typeof v}`);
}

export function fingerprint(item) {
  if (item === null || item === undefined) throw new TypeError('fingerprint: item is absent');
  if (typeof item === 'string') return sha256(canonicalUrl(item));
  return sha256(canonical(item));
}
