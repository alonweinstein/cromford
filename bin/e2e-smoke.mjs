// e2e-smoke.mjs <base-url> <out-dir> [resolve-root] — headless smoke of a
// Vercel PREVIEW deployment. Loads a short list of routes and reports whether
// the app is standing: no 5xx, no console errors, no uncaught exceptions.
//
// SMOKE, NOT A SUITE, and strictly READ-ONLY: it navigates and observes,
// never clicks, submits, or mutates. Previews share the PROD database (the
// same reason the QA prompt forbids destructive actions), so a stage that runs
// on every build wave must not be able to touch a real record.
//
// Routes come from ROUTES (newline-separated) — catalog/e2e-smoke-routes.json
// is where they are declared per project, resolved by bin/e2e-smoke.sh.
// Auth: with QA_CLERK_SECRET_KEY + QA_TEST_USER_ID set it signs in as the
// low-privilege QA user via a one-time Clerk sign-in token (the browser lane;
// bin/qa-session.sh is the sibling lane that mints Bearer JWTs for API probes).
// Without them it smokes the anonymous surface and SAYS SO — an auth-walled
// route seen anonymously is a redirect, not a defect.
//
// playwright is resolved from resolve-root because ESM imports ignore NODE_PATH
// (same trick as bin/qa-signin-check.mjs).
//
// Prints one `ROUTE <status> <path> console=<n> <verdict>` line per route, then
// E2E COVERAGE / E2E: PASS|FAIL. Exit 0 = pass, 4 = fail, 3 = could not run.
import { createRequire } from "module";
import { writeFileSync } from "fs";

const base = process.argv[2];
const outDir = process.argv[3];
const resolveRoot = process.argv[4] || process.cwd();
if (!base || !outDir) { console.log("E2E: could not run (missing base-url/out-dir)"); process.exit(3); }

// The repo's own copy first, then the fleet-wide global install
// (bootstrap-machine.sh installs playwright globally and fly/Dockerfile bakes
// it into the image, so most repos have no local copy — that is normal, not a
// failure). A bare `import("playwright")` CANNOT find the global one: ESM
// resolution ignores the global node_modules root, which is why every root here
// goes through createRequire instead.
let chromium;
let pwFrom = "";
const roots = [
  resolveRoot,
  ...(process.env.NODE_PATH || "").split(":").filter(Boolean),
  "/usr/lib/node_modules",
  "/usr/local/lib/node_modules",
];
for (const r of roots) {
  try {
    ({ chromium } = createRequire(r.endsWith("/") ? r : r + "/")("playwright"));
    pwFrom = r;
    break;
  } catch { /* try the next root */ }
}
if (!chromium) {
  console.log("E2E: could not run (playwright resolves from none of: " + roots.join(", ") + ")");
  process.exit(3);
}

const routes = (process.env.ROUTES || "/").split("\n").map((r) => r.trim()).filter(Boolean);
const bypass = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;
const clerkKey = process.env.QA_CLERK_SECRET_KEY;
const qaUserId = process.env.QA_TEST_USER_ID;

// Mint the sign-in ticket BEFORE launching the browser: if Clerk refuses we
// smoke anonymously rather than failing the stage. An auth lane that is not
// configured is not a defect in the diff under test.
let ticket = null;
let authNote = "anonymous (no QA_CLERK_SECRET_KEY/QA_TEST_USER_ID)";
if (clerkKey && qaUserId) {
  try {
    const res = await fetch("https://api.clerk.com/v1/sign_in_tokens", {
      method: "POST",
      headers: { Authorization: `Bearer ${clerkKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: qaUserId, expires_in_seconds: 600 }),
    });
    if (res.ok) { ticket = (await res.json()).token; authNote = "authenticated as the QA test user"; }
    else authNote = `anonymous (Clerk sign-in token mint HTTP ${res.status})`;
  } catch (e) { authNote = "anonymous (Clerk mint failed: " + String(e).slice(0, 80) + ")"; }
}

let browser;
try { browser = await chromium.launch(); }
catch (e) { console.log("E2E: could not run (chromium launch failed: " + String(e).slice(0, 120) + ")"); process.exit(3); }
const ctx = await browser.newContext();
const page = await ctx.newPage();

// Console + uncaught errors are collected per route. `current` is reset before
// each navigation so an error is attributed to the page that produced it.
let current = { console: [], server: [] };
// APP errors only. The browser logs "Failed to load resource: ... 404" as a
// console error for every missing favicon, image and analytics beacon, and
// counting those would fail the smoke on noise that has nothing to do with the
// diff — a gate that cries wolf is a gate someone switches off. The failures
// that matter from that family are 5xx, and the response listener below catches
// those on their own terms.
const RESOURCE_NOISE = /^Failed to load resource:/;
page.on("console", (m) => {
  if (m.type() !== "error") return;
  const t = m.text();
  if (RESOURCE_NOISE.test(t)) return;
  current.console.push(t.slice(0, 200));
});
page.on("pageerror", (e) => current.console.push("uncaught: " + String(e).slice(0, 200)));
// Subresource 5xx counts too: a page that renders while its data route 500s is
// broken, and that is exactly the regression a status-only check would miss.
page.on("response", (r) => { if (r.status() >= 500) current.server.push(`${r.status()} ${new URL(r.url()).pathname}`); });

const lines = [];
let failed = 0;
let loaded = 0;
try {
  if (bypass) {
    // Bypass COOKIE mode, never a global extraHTTPHeaders header: a global
    // header rides along on third-party requests and breaks their CORS
    // preflight (the Clerk CDN lesson, 2026-07-28).
    await page.goto(`${base}/?x-vercel-protection-bypass=${bypass}&x-vercel-set-bypass-cookie=true`,
      { waitUntil: "domcontentloaded", timeout: 45000 }).catch(() => {});
  }
  if (ticket) {
    await page.goto(`${base}/sign-in?__clerk_ticket=${encodeURIComponent(ticket)}`,
      { waitUntil: "domcontentloaded", timeout: 45000 }).catch(() => {});
    await page.waitForURL((u) => !u.pathname.startsWith("/sign-in"), { timeout: 30000 })
      .catch(() => { authNote = "anonymous (sign-in never landed off /sign-in)"; });
  }

  for (const route of routes) {
    current = { console: [], server: [] };
    let status = 0;
    let note = "";
    try {
      const resp = await page.goto(base + route, { waitUntil: "domcontentloaded", timeout: 45000 });
      status = resp ? resp.status() : 0;
      // Let client-side rendering settle so a React error boundary or a failing
      // data fetch has actually happened before we read the counters.
      await page.waitForTimeout(2500);
      loaded++;
    } catch (e) {
      note = " nav-error:" + String(e).slice(0, 100).replace(/\s+/g, " ");
    }
    const consoleErrs = current.console.length;
    const serverErrs = current.server;
    // A 5xx or a console error is a real finding. Everything else — a 401/403
    // permission wall, a 404 on a route this diff did not add, a redirect — is
    // observed behaviour, reported and not failed.
    const bad = status >= 500 || serverErrs.length > 0 || consoleErrs > 0 || note !== "";
    if (bad) failed++;
    lines.push(`ROUTE ${status || "ERR"} ${route} console=${consoleErrs}${serverErrs.length ? " 5xx=[" + serverErrs.join("; ") + "]" : ""}${note} ${bad ? "FAIL" : "ok"}`);
    if (consoleErrs) for (const c of current.console.slice(0, 3)) lines.push(`    console: ${c}`);
  }
} finally {
  await browser.close().catch(() => {});
}

// A run that loaded nothing is not a pass. Same rule as the QA gate: the word
// PASS is not evidence, counted work is.
const verdict = loaded === 0 ? "FAIL" : failed > 0 ? "FAIL" : "PASS";
const body = [
  `E2E smoke of ${base}`,
  `Auth: ${authNote}`,
  `playwright: resolved from ${pwFrom}`,
  `Read-only: navigation and observation only, no clicks or submissions.`,
  "",
  ...lines,
  "",
  `E2E COVERAGE: routes=${loaded} failed=${failed}`,
  `E2E: ${verdict}`,
].join("\n");
try { writeFileSync(`${outDir}/e2e.md`, body + "\n"); } catch { /* the shell prints it either way */ }
console.log(body);
process.exit(verdict === "PASS" ? 0 : 4);
