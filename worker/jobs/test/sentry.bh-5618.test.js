// BH-5618: harness-jobs reports exceptions to Sentry, and only when
// HARNESS_SENTRY_DSN is bound. Sends are counted through a stubbed
// globalThis.fetch: a POST whose URL contains sentry.test is one event
// envelope. The DSN is a fixture on a reserved TLD, never a real one.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const DSN = "https://fixturepubkey@sentry.test/42";
const lib = () => import("../src/lib/sentry.js");

class Ctx {
  constructor() { this.waits = []; }
  waitUntil(p) { this.waits.push(Promise.resolve(p).catch(() => {})); }
  passThroughOnException() {}
}

// Every send rides ctx.waitUntil (flushAndDispose). Drain until no new
// promise appears, so a flush that queues another flush is awaited too.
async function settle(ctx) {
  for (let seen = -1; seen !== ctx.waits.length;) {
    seen = ctx.waits.length;
    await Promise.all(ctx.waits);
    await new Promise((r) => setTimeout(r, 5));
  }
}

function stubFetch(t) {
  const real = globalThis.fetch;
  const posts = [];
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push(String(url));
    if (String(url).includes("sentry.test")) {
      const b = init.body;
      posts.push(typeof b === "string" ? b : new TextDecoder().decode(b));
    }
    return new Response("{}", { status: 200 });
  };
  t.after(() => { globalThis.fetch = real; });
  return { posts, calls };
}

const throwingDb = (msg) => {
  const boom = () => { throw new Error(msg); };
  return { prepare: boom, batch: boom, exec: boom };
};

test("W1: a throwing route on the real worker sends one scrubbed, tagged event", async (t) => {
  const { posts } = stubFetch(t);
  const ctx = new Ctx();
  const env = { DB: throwingDb("d1 down W1"), HARNESS_SECRET: "test-secret", HARNESS_SENTRY_DSN: DSN };
  const req = new Request("https://jobs.test/api/flags", {
    headers: { authorization: "Bearer test-secret", cookie: "sid=abc", "x-harness-token": "tok-xyz" },
  });
  await assert.rejects(() => worker.fetch(req, env, ctx), /W1/);
  await settle(ctx);
  assert.equal(posts.length, 1, "exactly one envelope reaches Sentry");
  const body = posts[0];
  assert.match(body, /d1 down W1/);
  assert.match(body, /"lane":"harness-jobs"/);
  assert.match(body, /"box":"cloudflare"/);
  assert.match(body, /"harness_sha":"unknown"/);
  assert.doesNotMatch(body, /authorization|cookie|x-harness-token|test-secret|tok-xyz|sid=abc/i);
});

test("W2: no DSN — the real worker answers 401 exactly as before and calls no fetch", async (t) => {
  const { calls } = stubFetch(t);
  const res = await worker.fetch(new Request("https://jobs.test/api/flags"), { HARNESS_SECRET: "test-secret" });
  assert.equal(res.status, 401);
  assert.deepEqual(await res.json(), { error: "unauthorized" });
  assert.equal(calls.length, 0);
});

test("W3: the wrap is in place, keeps the handler's props, and hands over the ORIGINAL env", async (t) => {
  const { posts } = stubFetch(t);
  const { withHarnessSentry } = await lib();
  let seenEnv;
  const resp = new Response("x");
  const h = { fetch(req, env) { seenEnv = env; return resp; }, extra: 1 };
  const out = withHarnessSentry(h, { worker: "w3" });
  assert.equal(out, h);
  assert.equal(out.extra, 1);

  const plain = { DB: { tag: "plain-db" } };
  const got = await out.fetch(new Request("https://x.test/a"), plain, new Ctx());
  assert.equal(got, resp, "no DSN: the very same Response object");
  assert.equal(seenEnv, plain, "no DSN: the very same env object");

  const armed = { DB: { tag: "armed-db" }, HARNESS_SENTRY_DSN: DSN };
  const ctx = new Ctx();
  const got2 = await out.fetch(new Request("https://x.test/b"), armed, ctx);
  await settle(ctx);
  assert.equal(await got2.text(), "x");
  assert.equal(seenEnv, armed, "DSN: the handler still gets the original env, not Sentry's Proxy");
  assert.equal(seenEnv.DB, armed.DB, "DSN: env.DB is the original binding");
  assert.equal(posts.length, 0, "a clean request sends nothing (traces 0)");

  assert.ok(Array.isArray(worker.ROUTES), "the real export keeps ROUTES");
  assert.ok(worker.CREATED_TABLES, "the real export keeps CREATED_TABLES");
});

// The SDK's default dedupeIntegration drops an event equal to the one before
// it, ahead of beforeSend. Two keys interleaved make the cap the only gate.
async function throwSeq(h, env, msgs) {
  for (const m of msgs) {
    const ctx = new Ctx();
    await assert.rejects(() => h.fetch(new Request("https://x.test/"), env, ctx), new RegExp(m));
    await settle(ctx);
  }
}

test("W4: one cap key sends at most 6 events an hour; a new key still sends", async (t) => {
  const { posts } = stubFetch(t);
  const { withHarnessSentry } = await lib();
  let next;
  const h = withHarnessSentry({ fetch() { throw new Error(next()); } }, { worker: "w4" });
  const env = { HARNESS_SENTRY_DSN: DSN };
  const msgs = [];
  for (let i = 0; i < 7; i++) msgs.push("cap W4 a", "cap W4 b");
  let i = 0;
  next = () => msgs[i++];
  await throwSeq(h, env, msgs);
  const sent = (k) => posts.filter((p) => p.includes(k)).length;
  assert.equal(sent("cap W4 a"), 6, "the 7th 'a' is over the cap");
  assert.equal(sent("cap W4 b"), 6, "the 7th 'b' is over the cap");
  assert.equal(posts.length, 12);
  next = () => "fresh W4";
  await throwSeq(h, env, ["fresh W4"]);
  assert.equal(posts.length, 13, "a new cap key still sends");
});

test("W4b: HARNESS_SENTRY_MAX_PER_FP_HOUR overrides the cap", async (t) => {
  const { posts } = stubFetch(t);
  const { withHarnessSentry } = await lib();
  const msgs = ["cap W4b a", "cap W4b b", "cap W4b a", "cap W4b b", "cap W4b a", "cap W4b b"];
  let i = 0;
  const h = withHarnessSentry({ fetch() { throw new Error(msgs[i++]); } }, { worker: "w4b" });
  await throwSeq(h, { HARNESS_SENTRY_DSN: DSN, HARNESS_SENTRY_MAX_PER_FP_HOUR: "2" }, msgs);
  assert.equal(posts.length, 4, "2 per key, 2 keys");
});

test("W5: a scheduled handler is wrapped too", async (t) => {
  const { posts } = stubFetch(t);
  const { withHarnessSentry } = await lib();
  const h = withHarnessSentry({ scheduled() { throw new Error("cron W5"); } }, { worker: "w5" });
  const ctx = new Ctx();
  await assert.rejects(
    () => h.scheduled({ cron: "* * * * *", scheduledTime: 0 }, { HARNESS_SENTRY_DSN: DSN }, ctx),
    /cron W5/,
  );
  await settle(ctx);
  assert.equal(posts.length, 1);
  assert.match(posts[0], /cron W5/);
});

test("W6: the pause_flags kill switch drops the event; a failed pause read sends (fail-open)", async (t) => {
  const { posts } = stubFetch(t);
  const { withHarnessSentry } = await lib();
  const asked = [];
  const pausedDb = {
    prepare(sql) {
      return { bind(...a) { asked.push([sql, ...a]); return { first: async () => ({ active: 1 }) }; } };
    },
  };
  const h = withHarnessSentry({ fetch() { throw new Error("kill W6"); } }, { worker: "w6", pauseFlags: true });
  let ctx = new Ctx();
  await assert.rejects(() => h.fetch(new Request("https://x.test/"), { DB: pausedDb, HARNESS_SENTRY_DSN: DSN }, ctx));
  await settle(ctx);
  assert.equal(posts.length, 0, "active=1 drops the event");
  assert.equal(asked.length, 1);
  assert.match(asked[0][0], /FROM pause_flags/);
  assert.equal(asked[0][1], "lane-off-sentry-report");

  const h2 = withHarnessSentry({ fetch() { throw new Error("kill W6b"); } }, { worker: "w6", pauseFlags: true });
  ctx = new Ctx();
  await assert.rejects(() => h2.fetch(new Request("https://x.test/"), { DB: throwingDb("pause read down"), HARNESS_SENTRY_DSN: DSN }, ctx));
  await settle(ctx);
  assert.equal(posts.length, 1, "a pause read that throws still sends");
  assert.match(posts[0], /kill W6b/);
});

test("W7: scrubEvent drops the body, cookies, query and every secret-shaped key", async () => {
  const { scrubEvent } = await lib();
  const ev = scrubEvent({
    request: {
      url: "https://x.test/p?token=abc",
      data: "{\"pw\":1}", cookies: { sid: "1" }, query_string: "token=abc",
      headers: { Authorization: "Bearer a", Cookie: "c=1", "X-Api-Token": "t", "x-webhook-secret": "s", accept: "*/*" },
    },
    extra: { db_token: "t", ok: 1 },
    breadcrumbs: [{ data: { secret_key: "s", url: "/a" } }],
  });
  assert.equal(ev.request.data, undefined);
  assert.equal(ev.request.cookies, undefined);
  assert.equal(ev.request.query_string, undefined);
  assert.equal(ev.request.url, "https://x.test/p");
  assert.deepEqual(ev.request.headers, { accept: "*/*" });
  assert.deepEqual(ev.extra, { ok: 1 });
  assert.deepEqual(ev.breadcrumbs[0].data, { url: "/a" });
});
