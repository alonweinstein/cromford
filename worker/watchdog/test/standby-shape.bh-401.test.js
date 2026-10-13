// BH-401 contract (issue #1920): the standby KV shape, the failoverTick hook in
// scheduled, and its isolation from liveness steps 1-3.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { STANDBY_PREFIX, standbyKey, failoverKey, snapshotAgeMin, listStandbys } from "../src/standby.js";
import worker from "../src/index.js";

// Same surface as the Workers KV binding; list pages one key at a time so the
// cursor loop is exercised.
function fakeKv(seed = {}) {
  const m = new Map(Object.entries(seed));
  return {
    async get(k) { return m.has(k) ? m.get(k) : null; },
    async put(k, v) { m.set(k, v); },
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

test("snapshotAgeMin gives whole minutes, floored", () => {
  assert.equal(snapshotAgeMin("20260924T120000Z", Date.UTC(2026, 8, 24, 12, 7, 0)), 7);
  assert.equal(snapshotAgeMin("20260924T120000Z", Date.UTC(2026, 8, 24, 12, 7, 59)), 7);
});

test("snapshotAgeMin is null for anything unparseable, never 0 or NaN", () => {
  const nowMs = Date.UTC(2026, 8, 24, 12, 7, 0);
  for (const bad of ["garbage", "", undefined, null, "20260924T120000", "20261324T120000Z", "20260999T120000Z", "20260924T250000Z"]) {
    assert.equal(snapshotAgeMin(bad, nowMs), null, `input ${JSON.stringify(bad)}`);
  }
  assert.equal(snapshotAgeMin("20260924T120000Z", NaN), null);
});

test("key helpers", () => {
  assert.equal(STANDBY_PREFIX, "standby:");
  assert.equal(standbyKey("box-project-3-2"), "standby:box-project-3-2");
  assert.equal(failoverKey(1727000000000), "failover:1727000000000");
});

test("listStandbys returns every parseable standby with both ages, skips junk", async () => {
  const nowMs = Date.UTC(2026, 8, 24, 12, 7, 0);
  const kv = fakeKv({
    "standby:a": JSON.stringify({ ts: nowMs - 3 * 60000, of: "box-hub", snapshot: "20260924T120000Z", ok: true }),
    "standby:b": JSON.stringify({ ts: nowMs - 10 * 60000, of: "box-hub", snapshot: "garbage", ok: false }),
    "standby:junk": "not json{",
    "ping:x": JSON.stringify({ ts: nowMs }),
  });
  const rows = (await listStandbys({ KV: kv }, nowMs)).sort((x, y) => x.box.localeCompare(y.box));
  assert.deepEqual(rows, [
    { box: "a", of: "box-hub", snapshot: "20260924T120000Z", ok: true, report_age_min: 3, stream_age_min: 7 },
    { box: "b", of: "box-hub", snapshot: "garbage", ok: false, report_age_min: 10, stream_age_min: null },
  ]);
});

test("listStandbys gives null ages, never NaN, when now is not a number", async () => {
  const kv = fakeKv({
    "standby:a": JSON.stringify({ ts: Date.UTC(2026, 8, 24, 12, 4, 0), of: "box-hub", snapshot: "20260924T120000Z", ok: true }),
  });
  const [row] = await listStandbys({ KV: kv }, NaN);
  assert.equal(row.report_age_min, null);
  assert.equal(row.stream_age_min, null);
});

test("scheduled (the real cron entry) runs to completion with step 4 wired", async () => {
  await worker.scheduled({}, { KV: fakeKv() });
});

test("a throwing failoverTick does not break scheduled", () => {
  const dir = fileURLToPath(new URL(".", import.meta.url));
  const script = `
    import { mock } from "node:test";
    mock.module(${JSON.stringify(new URL("../src/failover.js", import.meta.url).href)}, {
      namedExports: { failoverTick: async () => { throw new Error("boom"); } },
    });
    const { default: worker } = await import(${JSON.stringify(new URL("../src/index.js", import.meta.url).href)});
    const kv = { async get() { return null; }, async put() {}, async delete() {}, async list() { return { keys: [], list_complete: true }; } };
    await worker.scheduled({}, { KV: kv });
    console.log("scheduled-resolved");
  `;
  const r = spawnSync(process.execPath, ["--experimental-test-module-mocks", "--input-type=module", "-e", script], { cwd: dir, encoding: "utf8" });
  assert.equal(r.status, 0, `child exited ${r.status}\n${r.stderr}`);
  assert.match(r.stdout, /scheduled-resolved/);
  assert.match(r.stderr, /failoverTick/);
  assert.match(r.stderr, /boom/);
});
