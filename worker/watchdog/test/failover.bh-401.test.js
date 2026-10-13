// BH-401 failover (issue #1922): failoverTick driven through the real cron
// entry, worker.scheduled, with an in-memory KV and a stubbed fetch that speaks
// the jobs worker's wire shape ({lease:{holder,epoch,updated_at,...}, as_of}).
import { test, beforeEach, afterEach, mock } from "node:test";
import assert from "node:assert/strict";
import { standbyKey, failoverKey } from "../src/standby.js";
import worker from "../src/index.js";

const JOBS = "https://jobs.test";
const HOLDER = "box-hub";
const SMALL = "box-small";
const MIN = 60000;
// The one instant every test runs at: Date is pinned to it in beforeEach, so the
// worker's own clock reads and every age fixture below agree by construction.
const NOW = Date.parse("2026-09-24T12:30:00Z");

// Same surface as the Workers KV binding; records put options.
function fakeKv(seed = {}) {
  const m = new Map(Object.entries(seed));
  const puts = [];
  return {
    m, puts,
    async get(k) { return m.has(k) ? m.get(k) : null; },
    async put(k, v, opts) { puts.push({ k, v, opts }); m.set(k, v); },
    async delete(k) { m.delete(k); },
    async list({ prefix = "", cursor } = {}) {
      const names = [...m.keys()].filter((k) => k.startsWith(prefix)).sort();
      const i = cursor ? Number(cursor) : 0;
      const page = names.slice(i, i + 1);
      const done = i + 1 >= names.length;
      return { keys: page.map((name) => ({ name })), list_complete: done, ...(done ? {} : { cursor: String(i + 1) }) };
    },
  };
}

const ping = (ageMin) => JSON.stringify({ ts: NOW - ageMin * MIN });
const standby = (over = {}) => JSON.stringify({ ts: NOW - 2 * MIN, ok: true, of: HOLDER, snapshot: "20260924T120000Z", ...over });

// The W1 world: failover armed with a declared 480 s hub fence, holder silent
// 17 min, lease 11 min unrenewed, one healthy standby.
function w1Seed(over = {}) {
  return {
    "cfg:failover": "on",
    "cfg:failover_hub_fence_s": "480",
    [`ping:${HOLDER}`]: ping(17),
    [standbyKey(SMALL)]: standby(),
    [`ping:${SMALL}`]: ping(1),
    ...over,
  };
}

function leaseBody({ holder = HOLDER, epoch = 5, staleMin = 11 } = {}) {
  const asOf = NOW;
  return {
    lease: { holder, epoch, expires_at: new Date(asOf - (staleMin - 3) * MIN).toISOString(), updated_at: new Date(asOf - staleMin * MIN).toISOString(), expired: staleMin > 3, remaining_s: 0 },
    as_of: new Date(asOf).toISOString(),
  };
}

let calls;
let realFetch;
// route: { lease: () => Response|throw, promote: (req, env) => Response }
let route;

function json(status, body) {
  return new Response(body === undefined ? "" : JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

beforeEach(() => {
  mock.timers.enable({ apis: ["Date"], now: NOW });
  calls = [];
  realFetch = globalThis.fetch;
  route = {
    lease: () => json(200, leaseBody()),
    promote: (body) => {
      const lb = leaseBody();
      return json(200, { ok: true, lease: { ...lb.lease, holder: body.target, epoch: 6 }, promoted: true, as_of: lb.as_of });
    },
  };
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const call = { url: u, init, body: init.body ? JSON.parse(init.body) : undefined };
    calls.push(call);
    if (u.startsWith("https://api.telegram.org/")) return json(200, { ok: true });
    if (u === `${JOBS}/api/hub/lease`) return route.lease(call);
    if (u === `${JOBS}/api/hub/promote`) return route.promote(call.body, call);
    throw new Error(`unrouted fetch ${u}`);
  };
});
afterEach(() => { globalThis.fetch = realFetch; mock.timers.reset(); });

const envOf = (kv, over = {}) => ({ KV: kv, JOBS_URL: JOBS, HARNESS_SECRET: "s3cret", TELEGRAM_BOT_TOKEN: "tok", TELEGRAM_CHAT_ID: "1", ...over });
const promotes = () => calls.filter((c) => c.url === `${JOBS}/api/hub/promote`);
// Failover pages only: a holder silent past index.js's PING_STALE_MIN also gets
// the liveness step's own "silent for N min" page, which is not this tick's.
const tgs = () => calls.filter((c) => c.url.startsWith("https://api.telegram.org/")).map((c) => c.body.text).filter((x) => x.includes("HUB FAILOVER"));
const jobsCalls = () => calls.filter((c) => c.url.startsWith(JOBS));
const reset = () => { calls.length = 0; };

test("W1: dead holder + stale lease + one healthy standby → one promote, one page, marker promoted", async () => {
  const kv = fakeKv(w1Seed());
  let markerAtCall;
  route.promote = (body) => {
    markerAtCall = kv.m.get(failoverKey(5));
    const lb = leaseBody();
    return json(200, { ok: true, lease: { ...lb.lease, holder: body.target, epoch: 6 }, promoted: true, as_of: lb.as_of });
  };
  await worker.scheduled({}, envOf(kv));

  const leaseGet = calls.find((c) => c.url === `${JOBS}/api/hub/lease`);
  assert.equal(leaseGet.init.headers.Authorization, "Bearer s3cret");
  assert.equal(promotes().length, 1);
  const pb = promotes()[0].body;
  assert.deepEqual({ ...pb, reason: undefined }, { target: SMALL, expected_epoch: 5, actor: "watchdog", confirm: true, reason: undefined });
  assert.match(pb.reason, /box-hub ping 17 min old, lease 11 min unrenewed/);
  assert.equal(calls.some((c) => c.url === `${JOBS}/api/hub/lease/promote`), false, "never the legacy unguarded route");
  assert.equal(promotes()[0].init.method, "POST");
  assert.equal(promotes()[0].init.headers.Authorization, "Bearer s3cret");

  assert.ok(markerAtCall, "marker must exist before the promote call");
  assert.equal(JSON.parse(markerAtCall).result, "pending");

  assert.equal(tgs().length, 1);
  assert.match(tgs()[0], /HUB FAILOVER → box-small/);
  assert.match(tgs()[0], /bin\/hub-lease\.sh promote --holder box-hub/);
  assert.match(tgs()[0], /epoch 5→6/);
  assert.match(tgs()[0], /ping 17 min old, lease 11 min unrenewed/);

  const marker = JSON.parse(kv.m.get(failoverKey(5)));
  assert.equal(marker.result, "promoted");
  assert.equal(marker.from, HOLDER);
  assert.equal(marker.to, SMALL);
  const markerPuts = kv.puts.filter((p) => p.k === failoverKey(5));
  assert.equal(markerPuts.length, 2);
  for (const p of markerPuts) assert.equal(p.opts?.expirationTtl, 2592000);
});

test("W2: a second tick for the same epoch promotes nothing and pages nothing", async () => {
  const kv = fakeKv(w1Seed());
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 1);
  reset();
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 0);
  assert.equal(tgs().length, 0);
});

test("W3: holder ping fresh (2 min) + lease stale → no promote, no page", async () => {
  const kv = fakeKv(w1Seed({ [`ping:${HOLDER}`]: ping(2) }));
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 0);
  assert.equal(tgs().length, 0);
});

test("W4: holder ping stale + lease fresh (2 min) → no promote", async () => {
  const kv = fakeKv(w1Seed());
  route.lease = () => json(200, leaseBody({ staleMin: 2 }));
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 0);
  assert.equal(tgs().length, 0);
});

test("W5: lease unreadable (503 / throw / lease:null / as_of missing) → no promote", async () => {
  const variants = {
    "503": () => json(503, { error: "down" }),
    throw: () => { throw new TypeError("network"); },
    "lease null": () => json(200, { lease: null, as_of: new Date(NOW).toISOString() }),
    "as_of missing": () => { const b = leaseBody(); delete b.as_of; return json(200, b); },
  };
  for (const [name, fn] of Object.entries(variants)) {
    reset();
    const kv = fakeKv(w1Seed());
    route.lease = fn;
    await worker.scheduled({}, envOf(kv));
    assert.equal(promotes().length, 0, name);
    assert.equal(tgs().length, 0, name);
    assert.equal(kv.m.has(failoverKey(5)), false, name);
  }
});

test("W6: holder is the only standby, or holder never pinged → no promote", async () => {
  let kv = fakeKv(w1Seed({ [`ping:${SMALL}`]: ping(7) }));
  kv.m.delete(`ping:${HOLDER}`);
  route.lease = () => json(200, leaseBody({ holder: SMALL }));
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 0, "holder == small");

  reset();
  kv = fakeKv(w1Seed());
  kv.m.delete(`ping:${HOLDER}`);
  route.lease = () => json(200, leaseBody());
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 0, "holder ping absent");
  assert.equal(tgs().length, 0, "holder ping absent");
});

test("W7: not exactly one eligible standby → no promote, one damped 'not possible' page", async () => {
  const other = "box-project-4-1";
  const variants = {
    "no standby": (s) => { delete s[standbyKey(SMALL)]; },
    "two standbys": (s) => { s[standbyKey(other)] = standby(); s[`ping:${other}`] = ping(1); },
    "report 50 min old": (s) => { s[standbyKey(SMALL)] = standby({ ts: NOW - 50 * MIN }); },
    "ok false": (s) => { s[standbyKey(SMALL)] = standby({ ok: false }); },
    "of another box": (s) => { s[standbyKey(SMALL)] = standby({ of: "box-project-4-1" }); },
    "standby ping 20 min": (s) => { s[`ping:${SMALL}`] = ping(20); },
    "no ts (report_age_min null)": (s) => { const v = JSON.parse(standby()); delete v.ts; s[standbyKey(SMALL)] = JSON.stringify(v); },
  };
  for (const [name, mut] of Object.entries(variants)) {
    reset();
    const seed = w1Seed();
    mut(seed);
    const kv = fakeKv(seed);
    await worker.scheduled({}, envOf(kv));
    assert.equal(promotes().length, 0, name);
    const pages = tgs().filter((x) => x.includes("HUB FAILOVER"));
    assert.equal(pages.length, 1, name);
    assert.match(pages[0], /HUB FAILOVER not possible: .* — box-hub down 17 min/, name);
    if (name === "two standbys") assert.match(pages[0], /2 eligible standbys/);
    if (name === "no standby") assert.match(pages[0], /no eligible standby/);
    assert.equal(kv.m.has(failoverKey(5)), false, name);

    reset();
    await worker.scheduled({}, envOf(kv));
    assert.equal(tgs().filter((x) => x.includes("HUB FAILOVER")).length, 0, `${name} (repeat tick damped)`);
    assert.equal(promotes().length, 0, `${name} (repeat)`);
  }
});

test("W8: kill switch off, or JOBS_URL unset → no jobs call at all", async () => {
  let kv = fakeKv(w1Seed({ "cfg:failover": "off" }));
  await worker.scheduled({}, envOf(kv));
  assert.equal(jobsCalls().length, 0, "cfg:failover=off");

  reset();
  kv = fakeKv(w1Seed());
  const env = envOf(kv);
  delete env.JOBS_URL;
  await worker.scheduled({}, env);
  assert.equal(jobsCalls().length, 0, "JOBS_URL unset");
  assert.equal([...kv.m.keys()].some((k) => k.startsWith("failover:")), false);
  assert.equal(tgs().length, 0);
});

test("W9: promote answers 500 → one FAILED page, marker failed, no retry next tick", async () => {
  const kv = fakeKv(w1Seed());
  route.promote = () => json(500, { error: "boom" });
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 1);
  assert.equal(tgs().length, 1);
  assert.match(tgs()[0], /HUB FAILOVER → box-small FAILED \(500\)/);
  assert.match(JSON.parse(kv.m.get(failoverKey(5))).result, /^failed:500/);

  reset();
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 0);
  assert.equal(tgs().length, 0);
});

test("W9b: promote 200 naming the wrong holder is a failure, not a success", async () => {
  const kv = fakeKv(w1Seed());
  route.promote = () => { const lb = leaseBody(); return json(200, { ok: true, lease: { ...lb.lease, holder: "someone-else" }, promoted: true, as_of: lb.as_of }); };
  await worker.scheduled({}, envOf(kv));
  assert.equal(JSON.parse(kv.m.get(failoverKey(5))).result, "failed:200-mismatch");
  assert.match(tgs()[0], /FAILED \(200-mismatch\)/);
});

test("knob: a non-integer cfg:failover_ping_min warns and falls back to 16", async (t) => {
  const warn = t.mock.method(console, "warn", () => {});
  const kv = fakeKv(w1Seed({ "cfg:failover_ping_min": "abc" }));
  await worker.scheduled({}, envOf(kv));
  assert.equal(warn.mock.callCount(), 1);
  assert.match(String(warn.mock.calls[0].arguments.join(" ")), /cfg:failover_ping_min/);
  assert.equal(promotes().length, 1);
});

test("knob: a valid cfg:failover_ping_min is honored (20 min → a 17-min ping is still alive)", async (t) => {
  const warn = t.mock.method(console, "warn", () => {});
  const kv = fakeKv(w1Seed({ "cfg:failover_ping_min": "20", "cfg:failover_lease_min": "10" }));
  await worker.scheduled({}, envOf(kv));
  assert.equal(warn.mock.callCount(), 0);
  assert.equal(promotes().length, 0);
});

test("OFF by default: cfg:failover absent, or anything but \"on\" → no jobs call, no page", async () => {
  for (const v of [undefined, "", "yes", "ON", "1"]) {
    reset();
    const seed = w1Seed();
    if (v === undefined) delete seed["cfg:failover"]; else seed["cfg:failover"] = v;
    const kv = fakeKv(seed);
    await worker.scheduled({}, envOf(kv));
    assert.equal(jobsCalls().length, 0, `cfg:failover=${v}`);
    assert.equal(tgs().length, 0, `cfg:failover=${v}`);
  }
});

test("fence: armed without a hub fence that trips before the lease window → no promote, one damped page", async (t) => {
  t.mock.method(console, "warn", () => {});
  const variants = {
    unset: (s) => { delete s["cfg:failover_hub_fence_s"]; },
    junk: (s) => { s["cfg:failover_hub_fence_s"] = "abc"; },
    "zero": (s) => { s["cfg:failover_hub_fence_s"] = "0"; },
    "481 s against a 10-min lease window": (s) => { s["cfg:failover_hub_fence_s"] = "481"; },
    "BH-1000 grace (600 s) against a 10-min lease window": (s) => { s["cfg:failover_hub_fence_s"] = "600"; },
  };
  for (const [name, mut] of Object.entries(variants)) {
    reset();
    const seed = w1Seed();
    mut(seed);
    const kv = fakeKv(seed);
    await worker.scheduled({}, envOf(kv));
    assert.equal(jobsCalls().length, 0, name);
    const pages = tgs().filter((x) => x.includes("HUB FAILOVER"));
    assert.equal(pages.length, 1, name);
    assert.match(pages[0], /armed but not safe.*at most 480 s/, name);

    reset();
    await worker.scheduled({}, envOf(kv));
    assert.equal(tgs().filter((x) => x.includes("HUB FAILOVER")).length, 0, `${name} (repeat tick damped)`);
  }
});

test("fence: the bound follows cfg:failover_lease_min (15 min admits a 780 s fence)", async () => {
  const kv = fakeKv(w1Seed({ "cfg:failover_lease_min": "15", "cfg:failover_hub_fence_s": "780" }));
  route.lease = () => json(200, leaseBody({ staleMin: 16 }));
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 1);
});

test("default windows: one missed ping or a few missed renews is not a dead hub", async () => {
  // 15-min-old ping (two missed */5 pings) with the lease 11 min stale.
  let kv = fakeKv(w1Seed({ [`ping:${HOLDER}`]: ping(15) }));
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 0, "ping 15 min");

  // Holder silent 17 min but the lease only 9 min unrenewed.
  reset();
  kv = fakeKv(w1Seed());
  route.lease = () => json(200, leaseBody({ staleMin: 9 }));
  await worker.scheduled({}, envOf(kv));
  assert.equal(promotes().length, 0, "lease 9 min");
});

test("W10: the guarded route's refusals are distinct terminal outcomes with their own page, never retried", async () => {
  const variants = {
    // The operator's move for THIS outage is a hand promote; arming the switch is
    // only for future ones (#2131 r3 note).
    "promote-disabled": [403, /hub\.promote_enabled is off in D1.*promote .* by hand for this outage.*future outages/],
    stale_epoch: [409, /no longer at epoch 5/],
    lease_live: [409, /lease is live/],
    unknown_box: [400, /no box_status row for box-small/],
  };
  for (const [error, [code, page]] of Object.entries(variants)) {
    reset();
    const kv = fakeKv(w1Seed());
    route.promote = () => json(code, { error });
    await worker.scheduled({}, envOf(kv));
    assert.equal(promotes().length, 1, error);
    assert.equal(JSON.parse(kv.m.get(failoverKey(5))).result, `refused:${error}`, error);
    assert.equal(tgs().length, 1, error);
    assert.match(tgs()[0], new RegExp(`HUB FAILOVER → box-small REFUSED \\(${error}\\)`), error);
    assert.match(tgs()[0], page, error);

    reset();
    await worker.scheduled({}, envOf(kv));
    assert.equal(promotes().length, 0, `${error} (repeat)`);
    assert.equal(tgs().length, 0, `${error} (repeat)`);
  }
});

test("W10b: an unlisted 409 error, or a listed error on the wrong status, is failed:<status>", async () => {
  for (const [code, error] of [[409, "no_lease"], [400, "stale_epoch"]]) {
    reset();
    const kv = fakeKv(w1Seed());
    route.promote = () => json(code, { error });
    await worker.scheduled({}, envOf(kv));
    assert.equal(JSON.parse(kv.m.get(failoverKey(5))).result, `failed:${code}`, error);
    assert.match(tgs()[0], new RegExp(`FAILED \\(${code}\\) — needs you`), error);
  }
});

test("W9c: a 200 without ok:true is a mismatch, not a promote", async () => {
  const kv = fakeKv(w1Seed());
  route.promote = (body) => { const lb = leaseBody(); return json(200, { lease: { ...lb.lease, holder: body.target } }); };
  await worker.scheduled({}, envOf(kv));
  assert.equal(JSON.parse(kv.m.get(failoverKey(5))).result, "failed:200-mismatch");
});
