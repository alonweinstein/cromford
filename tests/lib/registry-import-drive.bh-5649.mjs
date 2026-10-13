// tests/lib/registry-import-drive.bh-5649.mjs <payload.json>... — BH-5649.
//
// POSTs each payload file, in order, to the REAL harness-jobs worker
// (worker/jobs/src/index.js) over one node:sqlite D1 built from
// worker/jobs/schema.sql, with the bearer and the registry admin token. Prints
// one JSON object: per POST the status, changed, version and the row counts of
// the four registry tables and registry_audit after it; then every audit row.
// Exit 3 = node:sqlite is not available (the caller prints SKIP).
import { readFileSync } from 'node:fs';
import worker from '../../worker/jobs/src/index.js';
import { openDb } from '../../worker/jobs/test/lib/d1-sqlite.bh-1030.js';

const opened = await openDb();
if (!opened) process.exit(3);
const { db, DB } = opened;
const env = { DB, HARNESS_SECRET: 'fixture-secret', REGISTRY_ADMIN_TOKEN: 'fixture-admin-token' };
const count = (t) => db.prepare(`SELECT COUNT(*) AS n FROM ${t}`).get().n;
const posts = [];
for (const file of process.argv.slice(2)) {
  const res = await worker.fetch(new Request('https://jobs.test/api/registry/import', {
    method: 'POST',
    headers: {
      authorization: 'Bearer fixture-secret',
      'x-registry-admin-token': 'fixture-admin-token',
      'content-type': 'application/json',
    },
    body: readFileSync(file, 'utf8'),
  }), env);
  const body = await res.json();
  posts.push({
    status: res.status, changed: body.changed, version: body.version, error: body.error,
    rows: {
      projects: count('registry_projects'), boxes: count('registry_boxes'),
      lane_boxes: count('registry_lane_boxes'), box_accounts: count('registry_box_accounts'),
    },
    audit: count('registry_audit'),
  });
}
const audit = db.prepare('SELECT entity, key, old_value, new_value, version, actor FROM registry_audit ORDER BY id').all();
process.stdout.write(JSON.stringify({ posts, audit }) + '\n');
