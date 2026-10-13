#!/bin/bash
# tests/qa-drive-flows-test.sh — the --flows/--persona/--preview/--production
# surface of bin/qa-drive.mjs, DRIVEN THROUGH THE CLI.
#
# WHAT IS BEING PINNED, and why each property is driven rather than grepped:
#
#   1. NO FLAG MEANS TODAY'S BEHAVIOUR, BYTE FOR BYTE. bin/postmerge-qa.sh
#      calls this CLI with no flags, so the usage text and its exit code are
#      load-bearing; the test diffs the whole output.
#   2. THE MODE GATE FAILS CLOSED. A `production_safe: false` flow is NEVER
#      executed outside preview — proven by a fake browser that counts pages,
#      not by reading the selection function's return value alone.
#   3. AN UNREADABLE FLOWS FILE FAILS BEFORE ANY CLERK OR PLAYWRIGHT TOUCH.
#      Driven with the Clerk env unset: if the check moved after it, the
#      failure would name the env instead of the file.
#   4. THE FLOW ROW GRAMMAR IS THE CONTRACT (docs/E2E-POLICY.md line 266): the
#      lanes grep these rows, so pass/fail/blocked/skipped spellings, the
#      coverage counts and observed.json are asserted from real CLI output.
#   5. NOTHING OBSERVED IS NOT A PASS. A sign-in failure gives one blocked row
#      per flow and rc 1; a failing flow gives rc 1.
#
# playwright is a fake CJS module under a fake resolve-root, and Clerk is a
# stubbed global fetch, so the whole CLI runs for real with no network.
# Run from anywhere: tests/qa-drive-flows-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

for C in node jq; do
  command -v "$C" >/dev/null 2>&1 || { echo "FAIL: $C is not installed — this test cannot verify anything (NOT a pass)"; exit 1; }
done

node --check "$DIR/bin/qa-drive.mjs" 2>/dev/null && ok || bad "bin/qa-drive.mjs must parse"

# --- (a) no flags: usage output is byte-identical to today ------------------
EXPECTED=$(printf 'usage: qa-drive.mjs <base-url> <resolve-root> <out-dir> <path> [path...]\nQA COVERAGE: screens=0 flows=0 shots=0\nQA: FAIL\n')
OUT=$(node "$DIR/bin/qa-drive.mjs" a b 2>&1); RC=$?
[ "$OUT" = "$EXPECTED" ] && ok || bad "no-flag usage output changed: $OUT"
[ "$RC" = 2 ] && ok || bad "no-flag usage must exit 2 (got $RC)"

# --- (b) an unreadable flows file fails before Clerk or playwright ----------
OUT=$(cd "$DIR" && env -u QA_CLERK_SECRET_KEY -u QA_TEST_USER_ID \
  node "$DIR/bin/qa-drive.mjs" https://x /tmp "$T/out-b" --flows /nonexistent 2>&1); RC=$?
has "$OUT" "FAIL: flows file /nonexistent" && ok || bad "a missing flows file must name itself: $OUT"
has "$OUT" "QA COVERAGE: screens=0 flows=0 shots=0" && ok || bad "a flows-file failure must print zero coverage: $OUT"
has "$OUT" "QA: FAIL" && ok || bad "a flows-file failure must print QA: FAIL: $OUT"
[ "$RC" = 2 ] && ok || bad "a flows-file failure must exit 2 (got $RC)"
has "$OUT" "QA_CLERK_SECRET_KEY" && bad "the flows file must be read BEFORE the Clerk env check: $OUT" || ok

# a document that is the word NONE is a flows-file error, never a silent pass
printf 'NONE\n' > "$T/none.json"
OUT=$(env -u QA_CLERK_SECRET_KEY -u QA_TEST_USER_ID \
  node "$DIR/bin/qa-drive.mjs" https://x /tmp "$T/out-none" --flows "$T/none.json" 2>&1); RC=$?
has "$OUT" "FAIL: flows file $T/none.json" && ok || bad "a NONE document must be refused by name: $OUT"
[ "$RC" = 2 ] && ok || bad "a NONE document must exit 2 (got $RC)"

# --- (c) the scoped fixtures, built from the personas fixture --------------
PERSONAS="$DIR/tests/fixtures/qa-personas/valid.json"
jq '{version, mode: "preview", personas}' "$PERSONAS" > "$T/preview.json"
jq '{version, mode: "production", personas: [.personas[] | .flows |= [.[] |
      if .production_safe == true then . else (del(.steps) + {skipped: "write flow, production"}) end]]}' \
  "$PERSONAS" > "$T/scoped.json"

cat > "$T/select-test.mjs" <<EOF
const M = await import("file://$DIR/bin/qa-drive.mjs");
import { readFileSync } from "fs";
const fail = [];
const T = (name, cond) => { if (!cond) fail.push(name); };
const scoped = JSON.parse(readFileSync("$T/scoped.json", "utf8"));
const preview = JSON.parse(readFileSync("$T/preview.json", "utf8"));
const find = (rows, p, f) => rows.find((r) => r.persona === p && r.flow === f);

let rows = M.selectFlows(scoped, "production");
T("production selects every flow as a row", rows.length === 3);
T("production runs a safe read flow", find(rows, "owner", "dashboard").action === "run");
T("production NEVER runs a write flow", find(rows, "owner", "new-scan").action === "skip");
T("file order is preserved", rows.map((r) => \`\${r.persona}/\${r.flow}\`).join(",") === "admin/users,owner/dashboard,owner/new-scan");

rows = M.selectFlows(preview, "preview");
T("preview runs the write flow", find(rows, "owner", "new-scan").action === "run");

// An already-scoped flow carries the skipped mark and no steps. Even in preview
// that mark is honoured, or a scoped production document handed to a preview
// drive would fire the write flows it was scoped to hold back.
const marked = JSON.parse(JSON.stringify(preview));
marked.personas[1].flows[0] = { id: "dashboard", production_safe: true, skipped: "write flow, production" };
T("a flow already marked skipped is never run, even in preview",
  M.selectFlows(marked, "preview").find((r) => r.flow === "dashboard").action === "skip");

T("the default mode is production",
  M.selectFlows(preview).find((r) => r.flow === "new-scan").action === "skip");
T("an unknown mode is read fail-closed",
  M.selectFlows(preview, "prevue").find((r) => r.flow === "new-scan").action === "skip");

rows = M.selectFlows(scoped, "production", "owner");
T("--persona restricts to that persona", rows.length === 2 && rows.every((r) => r.persona === "owner"));
T("--persona with no match selects nothing", M.selectFlows(scoped, "production", "nobody").length === 0);

const a = M.parseArgs(["b", "r", "o", "--preview", "--flows", "f.json", "/p"]);
T("flags are parsed anywhere in argv",
  JSON.stringify(a.positional) === JSON.stringify(["b", "r", "o", "/p"]) && a.mode === "preview" && a.flows === "f.json");
const b = M.parseArgs(["b", "r", "o", "--persona", "owner", "--production"]);
T("--persona and --production parse", b.persona === "owner" && b.mode === "production");
T("no flags means production and no flows file",
  M.parseArgs(["b", "r", "o", "/p"]).mode === "production" && M.parseArgs(["b", "r", "o", "/p"]).flows === null);

if (fail.length) { console.log("MJSFAIL:" + fail.join(" | ")); process.exit(1); }
console.log("MJSOK");
EOF
OUT=$(node "$T/select-test.mjs" 2>&1)
has "$OUT" MJSOK && ok || bad "selectFlows/parseArgs contract: $OUT"

# --- (d)(e) the CLI end to end, with a fake playwright and a stubbed Clerk --
mkdir -p "$T/fakeroot/node_modules/playwright"
cat > "$T/fakeroot/node_modules/playwright/index.js" <<'EOF'
// A fake playwright: enough page surface for signIn() and the flow engine.
const fs = require("fs");
const state = { pages: 0 };
function makePage() {
  state.pages += 1;
  fs.appendFileSync(process.env.FAKE_PAGE_LOG, "page\n");
  const page = { _url: "about:blank", handlers: {} };
  page.on = (ev, fn) => { page.handlers[ev] = fn; };
  page.setViewportSize = () => {};
  page.goto = async (url) => {
    fs.appendFileSync(process.env.FAKE_PAGE_LOG, "goto " + url + "\n");
    const u = new URL(url);
    page._url = u.pathname.startsWith("/sign-in") ? u.origin + "/dashboard" : url;
  };
  page.waitForURL = async () => {};
  page.waitForTimeout = async () => {};
  page.url = () => page._url;
  page.click = async () => {};
  page.fill = async () => {};
  page.waitForSelector = async (sel) => {
    if (process.env.FAKE_MISSING_SELECTOR && sel === process.env.FAKE_MISSING_SELECTOR)
      throw new Error("selector " + sel + " not visible");
  };
  page.textContent = async () => "qa-smoke queued";
  page.evaluate = async () => false;
  page.screenshot = async ({ path }) => { fs.writeFileSync(path, ""); };
  page.close = async () => {};
  return page;
}
exports.chromium = {
  launch: async () => ({
    newContext: async () => ({ newPage: async () => makePage() }),
    close: async () => {},
  }),
};
EOF
cat > "$T/stub.mjs" <<'EOF'
// Clerk, stubbed at the fetch boundary: no network, no secrets.
const real = globalThis.fetch;
globalThis.fetch = async (url, opts) => {
  const s = String(url);
  if (s.includes("/sign_in_tokens")) return { ok: true, status: 200, json: async () => ({ token: "tkt" }) };
  if (s.includes("/v1/users/")) return { ok: true, status: 200, json: async () => ({ id: "user_x", banned: process.env.FAKE_BANNED === "1" }) };
  return real(url, opts);
};
EOF

run_cli() {
  env QA_CLERK_SECRET_KEY=sk_test_fake QA_TEST_USER_ID=user_x \
    FAKE_PAGE_LOG="$1" FAKE_BANNED="${FAKE_BANNED:-0}" FAKE_MISSING_SELECTOR="${FAKE_MISSING_SELECTOR:-}" \
    node --import "$T/stub.mjs" "$DIR/bin/qa-drive.mjs" https://app.test "$T/fakeroot" "$2" \
    --flows "$3" "${@:4}" 2>&1
}

# a passing production run: two safe flows execute, the write flow is skipped
: > "$T/pages-pass.log"
OUT=$(run_cli "$T/pages-pass.log" "$T/out-pass" "$T/scoped.json" --production); RC=$?
has "$OUT" "FLOW admin users pass steps=2/2 shot=$T/out-pass/admin-users-02.png" && ok || bad "a passing flow row: $OUT"
has "$OUT" "FLOW owner dashboard pass steps=2/2 shot=$T/out-pass/owner-dashboard-02.png" && ok || bad "the second persona's pass row: $OUT"
has "$OUT" "FLOW owner new-scan skipped (write flow, production)" && ok || bad "the skipped row: $OUT"
has "$OUT" "QA COVERAGE: screens=0 flows=2 shots=4" && ok || bad "flows= counts pass+fail only: $OUT"
has "$OUT" "QA: PASS" && ok || bad "a flows-only clean run must pass: $OUT"
[ "$RC" = 0 ] && ok || bad "a flows-only clean run must exit 0 (got $RC)"
# 1 sign-in page + 2 flow pages: the write flow never got a page at all
[ "$(grep -c '^page$' "$T/pages-pass.log")" = 3 ] && ok || bad "a production write flow must never open a page ($(grep -c '^page$' "$T/pages-pass.log") pages)"
[ "$(ls "$T/out-pass"/*.png 2>/dev/null | wc -l)" = 4 ] && ok || bad "four step screenshots must exist"
node -e '
  const o = require(process.argv[1]);
  if (o.mode !== "production") { console.log("MJSFAIL mode=" + o.mode); process.exit(1); }
  if (!Array.isArray(o.flows) || o.flows.length !== 3) { console.log("MJSFAIL flows=" + JSON.stringify(o.flows)); process.exit(1); }
  console.log("MJSOK");
' "$T/out-pass/observed.json" >"$T/obs.out" 2>&1
has "$(cat "$T/obs.out")" MJSOK && ok || bad "observed.json must carry mode and flows: $(cat "$T/obs.out")"

# preview: the write flow runs
: > "$T/pages-prev.log"
OUT=$(run_cli "$T/pages-prev.log" "$T/out-prev" "$T/preview.json" --preview); RC=$?
has "$OUT" "FLOW owner new-scan pass steps=4/4" && ok || bad "preview must run the write flow: $OUT"
[ "$RC" = 0 ] && ok || bad "a clean preview run must exit 0 (got $RC)"

# --persona restricts what the CLI drives
: > "$T/pages-one.log"
OUT=$(run_cli "$T/pages-one.log" "$T/out-one" "$T/scoped.json" --production --persona owner); RC=$?
has "$OUT" "FLOW admin users" && bad "--persona owner must not drive admin: $OUT" || ok
has "$OUT" "QA COVERAGE: screens=0 flows=1 shots=2" && ok || bad "--persona owner coverage: $OUT"

# a failing step: rc 1, the row names the step
: > "$T/pages-fail.log"
OUT=$(FAKE_MISSING_SELECTOR="role=table" run_cli "$T/pages-fail.log" "$T/out-fail" "$T/scoped.json" --production); RC=$?
has "$OUT" "FLOW admin users fail steps=1/2 shot=$T/out-fail/admin-users-02.png step 2 (expect):" && ok || bad "a failing flow row: $OUT"
has "$OUT" "QA: FAIL" && ok || bad "a failing flow must print QA: FAIL: $OUT"
[ "$RC" = 1 ] && ok || bad "a failing flow must exit 1 (got $RC)"

# a sign-in failure: one blocked row per flow, including the skipped ones
: > "$T/pages-banned.log"
OUT=$(FAKE_BANNED=1 run_cli "$T/pages-banned.log" "$T/out-banned" "$T/scoped.json" --production); RC=$?
for R in "FLOW admin users blocked sign-in:" "FLOW owner dashboard blocked sign-in:" "FLOW owner new-scan blocked sign-in:"; do
  has "$OUT" "$R" && ok || bad "a blocked run owes a row per flow ($R): $OUT"
done
has "$OUT" "QA COVERAGE: screens=0 flows=0 shots=0" && ok || bad "blocked flows are not executed flows: $OUT"
[ "$RC" = 1 ] && ok || bad "a blocked run must exit 1 (got $RC)"

# everything skipped and no screen driven is not a pass
jq '{version, mode: "production", personas: [.personas[] | .flows |= [.[] | del(.steps) + {skipped: "write flow, production"}]]}' \
  "$PERSONAS" > "$T/all-skipped.json"
: > "$T/pages-skip.log"
OUT=$(run_cli "$T/pages-skip.log" "$T/out-skip" "$T/all-skipped.json" --production); RC=$?
has "$OUT" "QA: FAIL" && ok || bad "a run that observed nothing must not pass: $OUT"
[ "$RC" = 1 ] && ok || bad "a run that observed nothing must exit 1 (got $RC)"

echo "qa-drive-flows-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
