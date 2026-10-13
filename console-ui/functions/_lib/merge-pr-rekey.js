// BH-4439: a "head moved" merge_pr refusal must not hold the command key once
// the moved head has a fresh verdict.
//
// The console worker keys a merge_pr command on `<project>:<ticket>:merge_pr`
// and hands back whatever row already sits under that key. The box refuses a
// merge when the PR's live head is not the REVIEWED sha (bin/poll-commands.sh
// rc 4, result `refused: head moved since sha <reviewed:8> — …`), and that
// terminal row kept the key, so every later Merge click, even after the moved
// head was re-reviewed, got the old refusal back (project-3 #396).
//
// The live head can't tell those clicks apart: the refused click and the click
// after the re-review both carry the same moved head. What changes is the
// verdict. So the PR screen sends the sha of the standing verdict for the live
// head as `verdict_sha` (never as `sha`: the box reads `.sha` as the reviewed
// sha it binds the merge to, and a merge stays bound to the ledger's). Before
// the Pages proxy forwards a merge_pr, this moves a head-moved refusal off the
// key, but only when it was bound to a DIFFERENT reviewed sha. The bound sha is
// the one the box wrote into the result (`since sha <8>`); a row without one
// falls back to the payload's `verdict_sha`; a row with neither counts as
// different. It's one guarded UPDATE, so the predicate is re-checked in the
// same statement that renames. The old row is renamed to `<key>:refused:<id>`,
// never deleted, so the history keeps it. The worker then finds no row under
// the key and mints a fresh command. A repeat with the same verdict matches
// nothing and stays idempotent, and a click with no fresh verdict sends no
// `verdict_sha` and gets the refusal back as before.
//
// Every skip forwards the click exactly as before. Once the console worker keys
// on the reviewed sha itself, this UPDATE never matches and can be deleted.

const SHA_RE = /^[0-9a-f]{40}$/i;
const SINCE = 'refused: head moved since sha ';

const REKEY_SQL = `UPDATE commands SET ckey = ckey || ':refused:' || id
 WHERE ckey = ?1 AND type = 'merge_pr' AND status = 'refused'
   AND result LIKE 'refused: head moved%'
   AND substr(lower(COALESCE(
         CASE WHEN result LIKE '${SINCE}%' THEN substr(result, ${SINCE.length + 1}, 8) END,
         CASE WHEN json_valid(payload) THEN json_extract(payload, '$.verdict_sha') END,
         '')), 1, 8) <> substr(?2, 1, 8)`;

// -> {rekeyed: n} | {skipped: 'no-db'|'no-verdict'|'bad-verdict'|'no-key'|'d1-error'}
export async function rekeyHeadMovedRefusal(db, body) {
  if (!db || typeof db.prepare !== 'function') return { skipped: 'no-db' };
  const verdict = body.verdict_sha;
  if (verdict == null || verdict === '') return { skipped: 'no-verdict' };
  if (typeof verdict !== 'string' || !SHA_RE.test(verdict)) return { skipped: 'bad-verdict' };
  const { project, ticket } = body;
  if (typeof project !== 'string' || !project || typeof ticket !== 'string' || !ticket) {
    return { skipped: 'no-key' };
  }
  try {
    const res = await db.prepare(REKEY_SQL).bind(`${project}:${ticket}:merge_pr`, verdict.toLowerCase()).run();
    return { rekeyed: Number((res && res.meta && res.meta.changes) || 0) };
  } catch (err) {
    console.error('merge_pr rekey skipped: ' + (err && err.message));
    return { skipped: 'd1-error' };
  }
}

// BH-4917: the same rename for ONE command row, by id, for every entry point.
// The hub poller (bin/poll-commands.sh) executes every merge_pr, whether the
// console, the MCP tool, Telegram or a box command sent it, and after it acks
// a head-moved refusal it asks functions/api/merge-pr/release.js to free that
// row's key. The guard re-checks type, terminal status, the result prefix and
// an unrenamed key in the same statement, so a row the console does not hold
// as a terminal head-moved refusal is never touched and a replay changes 0.
const RELEASE_SQL = `UPDATE commands SET ckey = ckey || ':refused:' || id
 WHERE id = ?1 AND type = 'merge_pr' AND status = 'refused'
   AND result LIKE 'refused: head moved%' AND ckey NOT LIKE '%:refused:%'`;

// -> {released: n} | {skipped: 'no-db'|'bad-id'|'d1-error'}
export async function releaseHeadMovedRefusal(db, id) {
  if (!db || typeof db.prepare !== 'function') return { skipped: 'no-db' };
  const n = typeof id === 'string' && /^[1-9][0-9]*$/.test(id) ? Number(id) : id;
  if (!Number.isSafeInteger(n) || n < 1) return { skipped: 'bad-id' };
  try {
    const res = await db.prepare(RELEASE_SQL).bind(n).run();
    return { released: Number((res && res.meta && res.meta.changes) || 0) };
  } catch (err) {
    console.error('merge_pr release failed: ' + (err && err.message));
    return { skipped: 'd1-error' };
  }
}
