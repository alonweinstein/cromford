// harness-jobs — the suite ledger's pure half (BH-5354.0 / BH-5366).
//
// A suite result is recorded once per input fingerprint, and a green one is
// reused while its inputs do not move. Everything that decides WHETHER a green
// may be reused lives here, so routes/suite-results.js is validation, SQL and
// nothing else:
//   * mergeStatus — FAIL IS STICKY. Once a fingerprint went red it is never
//     reused again; the route applies the same rule inside the upsert itself,
//     so a concurrent ok can never un-fail a row.
//   * readReuseKnobs — the two settings rows. A bad value turns reuse OFF with
//     a reason; it never falls back to the default (D11), and a settings read
//     that throws is off too, so the lookup route never 500s on a knob.
//   * credentialClass — who is asking decides the row's class. The bearer is a
//     builder; the x-suite-ledger-token is CI. An unset secret refuses, the
//     same rule bearerOk keeps.
import { bearerOk } from "./http.js";

// The code fallback for catalog/lanes.d/_lib.suite-reuse.json's two knobs, used
// only when no settings row exists; test/suite-results-schema.bh-5366.test.js
// pins these equal to the registry defaults.
export const REUSE_DEFAULTS = { reuse: "on", max_age_h: 72 };
// The settings keys are the registry's env names, lowercased under the lib id
// (the lib.<id>.<env> rule every lib knob follows).
const KNOB_ENV = { reuse: "SUITE_REUSE", max_age_h: "SUITE_REUSE_MAX_AGE_H" };
const knobKey = (env) => `lib.suite-reuse.${env.toLowerCase()}`;

export const MAX_ITEMS = 1500;
const SUITE_RE = /^tests\/[A-Za-z0-9._/-]{1,200}$/;
const FP_RE = /^[0-9a-f]{64}$/;
const STATUSES = new Set(["ok", "fail", "skipped"]);
const REPO_RE = /^[A-Za-z0-9._/-]{1,100}$/;
const CTX_RE = /^[A-Za-z0-9._:/-]{1,64}$/;
const RUN_RE = /^[A-Za-z0-9._:/-]{1,128}$/;
const SHA_RE = /^[0-9a-f]{40}$/;

export function mergeStatus(a, b) {
  if (a === "fail" || b === "fail") return "fail";
  if (a === "ok" || b === "ok") return "ok";
  return "skipped";
}

const isInt = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;

// Returns null when every item is good, else the first bad item's index and
// field. One bad item rejects the whole request: nothing is clamped or dropped.
export function validateItems(items, { withStatus = false } = {}) {
  if (!Array.isArray(items)) return "items must be an array";
  if (items.length > MAX_ITEMS) return `too many items (${items.length} > ${MAX_ITEMS})`;
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    if (!it || typeof it !== "object") return `items[${i}] must be an object`;
    if (typeof it.suite !== "string" || !SUITE_RE.test(it.suite)) return `items[${i}].suite must match ${SUITE_RE}`;
    if (typeof it.fingerprint !== "string" || !FP_RE.test(it.fingerprint)) return `items[${i}].fingerprint must be 64 lowercase hex`;
    if (!withStatus) continue;
    if (!STATUSES.has(it.status)) return `items[${i}].status must be ok, fail or skipped`;
    if (!isInt(it.duration_s, 0, 86400)) return `items[${i}].duration_s must be an integer 0..86400`;
  }
  return null;
}

// The top-level fields every route shares. `need` names the ones this route
// requires; head_sha is always optional and always checked when present.
export function validateHead(body, need) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return "body must be a JSON object";
  const rules = { repo: REPO_RE, ctx: CTX_RE, run_id: RUN_RE, run_key: RUN_RE };
  for (const f of need) {
    if (typeof body[f] !== "string" || !rules[f].test(body[f])) return `${f} must match ${rules[f]}`;
  }
  if (body.head_sha !== undefined && body.head_sha !== null && !(typeof body.head_sha === "string" && SHA_RE.test(body.head_sha))) {
    return "head_sha must be 40 lowercase hex";
  }
  return null;
}

export async function readReuseKnobs(db) {
  const out = { ...REUSE_DEFAULTS };
  let rows;
  try {
    rows = (await db.prepare("SELECT key, value FROM settings WHERE key IN (?1, ?2)")
      .bind(knobKey(KNOB_ENV.reuse), knobKey(KNOB_ENV.max_age_h)).all()).results || [];
  } catch {
    return { ...out, reuse: "off", reason: "settings unavailable" };
  }
  const val = (env) => rows.find((r) => r.key === knobKey(env))?.value;
  const age = val(KNOB_ENV.max_age_h);
  if (age !== undefined) {
    const n = /^[0-9]+$/.test(String(age)) ? Number(age) : NaN;
    if (!isInt(n, 1, 720)) return { ...out, reuse: "off", reason: "bad suite_reuse_max_age_h" };
    out.max_age_h = n;
  }
  const reuse = val(KNOB_ENV.reuse);
  if (reuse !== undefined) {
    if (reuse !== "on" && reuse !== "off") return { ...out, reuse: "off", reason: "bad suite_reuse" };
    out.reuse = reuse;
  }
  return out;
}

export function credentialClass(req, env) {
  if (bearerOk(req, env)) return "builder";
  const secret = String(env.SUITE_LEDGER_TOKEN || "").trim();
  const got = (req.headers.get("x-suite-ledger-token") || "").trim();
  return secret && got === secret ? "ci" : null;
}
