#!/bin/bash
# tests/qa-flows-test.sh — bin/lib/qa-flows.mjs, the flow step engine, DRIVEN.
#
# WHAT IS BEING PINNED, and why each property is driven rather than grepped:
#
#   1. A SCREENSHOT AFTER EVERY STEP. The pngs are the only evidence a flow
#      leaves behind, so the test counts files on disk, not calls.
#   2. THE FIRST FAILING STEP ENDS THE FLOW, and the reason names the step
#      number and its kind. A flow that kept going past a failed expect would
#      report later steps that never really ran.
#   3. A NATIVE DIALOG FAILS THE FLOW. It is a UI iron law, and a headless run
#      hangs forever on an undismissed one, so it is both dismissed and fatal.
#   4. AN AUTH WALL IS `session did not hold` — never a pass with a note.
#   5. THE ENGINE NEVER THROWS FOR A PAGE DEFECT and the page is ALWAYS closed;
#      a leaked page is a hung browser on the next flow.
# Run from anywhere: tests/qa-flows-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed — this test cannot verify anything (NOT a pass)"
  exit 1
fi

node --check "$DIR/bin/lib/qa-flows.mjs" 2>/dev/null && ok || bad "bin/lib/qa-flows.mjs must parse"

cat > "$T/flows-test.mjs" <<EOF
const { runFlow } = await import("file://$DIR/bin/lib/qa-flows.mjs");
import { existsSync, readdirSync } from "fs";
const OUT = "$T/out";
const fail = [];
const T = (name, cond) => { if (!cond) fail.push(name); };

// A fake playwright page: every call is recorded, and each behaviour the engine
// has to cope with (a landing on the auth wall, a dialog fired mid-click, a
// screenshot that throws) is configured per case.
function makePage(cfg = {}) {
  const page = {
    calls: [],
    closed: 0,
    handlers: {},
    _url: "https://app.test/blank",
    on(ev, fn) { page.handlers[ev] = fn; },
    setViewportSize(v) { page.calls.push(\`viewport:\${v.width}\`); },
    async goto(url) {
      page.calls.push(\`goto:\${url}\`);
      const path = new URL(url).pathname;
      page._url = (cfg.landings && cfg.landings[path]) || url;
    },
    async click(sel) {
      page.calls.push(\`click:\${sel}\`);
      if (cfg.dialogOnClick && page.handlers.dialog) {
        await page.handlers.dialog({ type: () => "confirm", message: () => "sure?", dismiss: async () => { page.calls.push("dismissed"); } });
      }
    },
    async fill(sel, value) { page.calls.push(\`fill:\${sel}=\${value}\`); },
    async waitForSelector(sel) {
      page.calls.push(\`wait:\${sel}\`);
      if ((cfg.missing || []).includes(sel)) throw new Error(\`selector \${sel} not visible\`);
    },
    async textContent(sel) { return (cfg.text || {})[sel] ?? ""; },
    url() { return page._url; },
    async screenshot({ path }) {
      page.calls.push(\`shot:\${path}\`);
      if (cfg.shotThrows) throw new Error("page closed while screenshotting");
      const { writeFileSync } = await import("fs");
      writeFileSync(path, "");
    },
    async close() { page.closed += 1; },
  };
  return page;
}
const ctxFor = (page) => ({ newPage: async () => page });

// --- 1. a clean three-step flow -------------------------------------------
let page = makePage({ text: { "role=row": "qa-smoke queued" } });
let rec = await runFlow(ctxFor(page), {
  base: "https://app.test", persona: "owner", flow: {
    id: "dashboard", steps: [
      { goto: "/dashboard" },
      { click: "button:has-text(\\"Refresh\\")" },
      { expect: { selector: "role=row", text: "qa-smoke" } },
    ],
  }, outDir: OUT,
});
T("a clean flow passes", rec.verdict === "pass");
T("a pass has no reason", rec.reason === null);
T("the record names its persona and flow", rec.persona === "owner" && rec.flow === "dashboard");
T("every step is recorded with n/kind/ok", rec.steps.length === 3 && rec.steps.every((s, i) => s.n === i + 1 && s.ok === true) &&
  rec.steps.map((s) => s.kind).join(",") === "goto,click,expect");
T("a screenshot after every step lands on disk",
  rec.steps.every((s) => s.shot && existsSync(s.shot)) &&
  readdirSync(OUT).filter((f) => f.startsWith("owner-dashboard-")).length === 3);
T("shot names are persona-flow-nn.png", rec.steps[0].shot.endsWith("owner-dashboard-01.png"));
T("the page is closed exactly once on a pass", page.closed === 1);
T("the base is prefixed onto the goto path", page.calls.includes("goto:https://app.test/dashboard"));

// --- 2. a failing expect ends the flow at that step ------------------------
page = makePage({ missing: ["role=table"] });
rec = await runFlow(ctxFor(page), {
  base: "https://app.test", persona: "admin", flow: {
    id: "users", steps: [{ goto: "/admin/users" }, { expect: { selector: "role=table" } }, { click: "a" }],
  }, outDir: OUT,
});
T("a missing selector fails the flow", rec.verdict === "fail");
T("the reason names the step number and kind", /^step 2 \(expect\): /.test(rec.reason));
T("the flow stops at the failing step", rec.steps.length === 2 && rec.steps[1].ok === false);
T("no step after the failure ran", !page.calls.some((c) => c.startsWith("click:")));
T("the page is closed exactly once on a fail", page.closed === 1);

// --- 3. expect.text mismatch --------------------------------------------
page = makePage({ text: { "role=row": "nothing here" } });
rec = await runFlow(ctxFor(page), {
  base: "https://app.test", persona: "owner", flow: {
    id: "new-scan", steps: [{ expect: { selector: "role=row", text: "qa-smoke" } }],
  }, outDir: OUT,
});
T("a text mismatch fails", rec.verdict === "fail" && /expected text "qa-smoke" in role=row/.test(rec.reason));

// --- 4. a native dialog fails the flow and is dismissed --------------------
page = makePage({ dialogOnClick: true });
rec = await runFlow(ctxFor(page), {
  base: "https://app.test", persona: "owner", flow: {
    id: "danger", steps: [{ click: "button" }, { goto: "/dashboard" }],
  }, outDir: OUT,
});
T("a native dialog fails the flow", rec.verdict === "fail" && /dialog/.test(rec.reason));
T("the dialog is dismissed so the run does not hang", page.calls.includes("dismissed"));
T("the dialog stops the flow", rec.steps.length === 1);

// --- 5. an auth-wall landing is the session-did-not-hold failure ----------
page = makePage({ landings: { "/dashboard": "https://app.test/sign-in?redirect=/dashboard" } });
rec = await runFlow(ctxFor(page), {
  base: "https://app.test", persona: "owner", flow: { id: "dashboard", steps: [{ goto: "/dashboard" }] }, outDir: OUT,
});
T("an auth wall fails with session did not hold", rec.verdict === "fail" && /session did not hold/.test(rec.reason));

// --- 6. a screenshot that throws is not a failed step ----------------------
page = makePage({ shotThrows: true });
rec = await runFlow(ctxFor(page), {
  base: "https://app.test", persona: "owner", flow: { id: "dashboard", steps: [{ goto: "/dashboard" }] }, outDir: OUT,
});
T("a throwing screenshot still passes the step", rec.verdict === "pass" && rec.steps[0].ok === true);
T("a throwing screenshot records shot:null", rec.steps[0].shot === null);
T("the page is closed after a screenshot failure", page.closed === 1);

// --- 7. malformed / unknown steps never throw -----------------------------
page = makePage();
rec = await runFlow(ctxFor(page), {
  base: "https://app.test", persona: "owner", flow: { id: "empty", steps: [] }, outDir: OUT,
});
T("a flow with no steps fails rather than passing vacuously", rec.verdict === "fail" && /no steps/.test(rec.reason));
T("the page is closed even with no steps", page.closed === 1);

page = makePage();
rec = await runFlow(ctxFor(page), {
  base: "https://app.test", persona: "owner", flow: { id: "weird", steps: [{ teleport: "/x" }] }, outDir: OUT,
});
T("an unknown step kind fails", rec.verdict === "fail" && /unknown step kind/.test(rec.reason));

// --- 8. a page that throws on newPage is a fail, never an exception --------
let threw = null;
try {
  rec = await runFlow({ newPage: async () => { throw new Error("context is gone"); } }, {
    base: "https://app.test", persona: "owner", flow: { id: "dashboard", steps: [{ goto: "/dashboard" }] }, outDir: OUT,
  });
} catch (e) { threw = String(e); }
T("a broken context never throws out of runFlow", threw === null);
T("a broken context is a fail with the message", rec.verdict === "fail" && /context is gone/.test(rec.reason));

if (fail.length) { console.log("MJSFAIL:" + fail.join(" | ")); process.exit(1); }
console.log("MJSOK");
EOF

OUT=$(node "$T/flows-test.mjs" 2>&1)
case "$OUT" in
  *MJSOK*) ok ;;
  *) bad "qa-flows.mjs contract: $OUT" ;;
esac

echo "qa-flows-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
