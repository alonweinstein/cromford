// qa-signin-check.mjs <base-url> [resolve-root] — proves the QA test user can
// really sign in. Prints LANDED:<url> + TITLE: on success.
//
// ANY landing back on /sign-in is a FAILURE, and as of 2026-08-29 that failure
// is also the EXIT CODE. It used to print "FAIL:" and exit 0, so every caller
// that checked `$?` — and the QA stage prompt tells sessions to run this first
// — read a bounced sign-in as a working one. A banned QA account (they are
// banned at rest by design) mints a ticket happily and only bounces at the
// browser, which is exactly the case this smoke test exists to catch.
//
// The sign-in flow itself lives in bin/qa-drive.mjs and is IMPORTED, never
// re-typed: two implementations of "are we really signed in" is how one of them
// comes to be wrong quietly. That module also checks the ban state first, so a
// banned account fails by name instead of as a mystery redirect.
//
// Env: QA_CLERK_SECRET_KEY, QA_TEST_USER_ID, VERCEL_AUTOMATION_BYPASS_SECRET
// (optional). playwright is resolved from resolve-root (default: the project-1
// repo) because ESM imports ignore NODE_PATH.
import { loadChromium, signIn } from "./qa-drive.mjs";

const base = process.argv[2];
const resolveRoot = process.argv[3] || "/root/repos/project-1/";
const clerkKey = process.env.QA_CLERK_SECRET_KEY;
const userId = process.env.QA_TEST_USER_ID;
const bypass = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;
if (!base || !clerkKey || !userId) {
  console.log("FAIL: missing args/env (base-url, QA_CLERK_SECRET_KEY, QA_TEST_USER_ID)");
  process.exit(1);
}

let browser;
try {
  browser = await loadChromium(resolveRoot).launch();
  const page = await browser.newPage();
  const landed = await signIn(page, { base, userId, clerkKey, bypass });
  console.log("LANDED:" + landed);
  console.log("TITLE:" + (await page.title()));
} catch (e) {
  console.log("FAIL:" + String(e).slice(0, 300));
  await browser?.close().catch(() => {});
  process.exit(1);
}
await browser.close().catch(() => {});
