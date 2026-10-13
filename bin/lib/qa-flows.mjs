// bin/lib/qa-flows.mjs — run ONE persona flow as a real signed-in user and
// report only what the browser actually did.
//
// A flow is a list of steps from a persona document (see docs/E2E-POLICY.md):
//
//   { "goto": "/dashboard" }
//   { "click": "button:has-text(\"Start scan\")" }
//   { "fill": { "selector": "input[name=name]", "value": "qa-smoke" } }
//   { "expect": { "selector": "role=row", "text": "qa-smoke" } }
//
// THREE THINGS THIS FILE IS OPINIONATED ABOUT
//
// 1. A SCREENSHOT AFTER EVERY STEP. The pngs are the only evidence the flow
//    leaves behind, so they are taken even for a step that failed — the frame
//    of the failure is the most useful one. A screenshot that itself throws
//    records `shot: null` and does NOT fail the step: losing the picture is not
//    losing the behaviour.
// 2. IT NEVER THROWS FOR A PAGE DEFECT, and the page is ALWAYS closed. A flow
//    that blew up would take the remaining flows of the run with it, and a
//    leaked page keeps the browser alive for the whole drive.
// 3. A NATIVE DIALOG AND AN AUTH-WALL LANDING BOTH FAIL THE FLOW. The dialog is
//    a UI iron law (and an undismissed one hangs a headless run forever); a
//    landing on /sign-in mid-flow means the session did not hold, which is
//    never a pass with a note.
import { mkdirSync } from "fs";
import { join } from "path";
import { isAuthWall } from "../qa-drive.mjs";

const STEP_TIMEOUT = 15000;
const NAV_TIMEOUT = 45000;

// The single key of a step object is its kind. A step with no recognisable key
// is a defect in the persona file, reported as a failing step rather than a
// crash.
function stepKind(step) {
  if (!step || typeof step !== "object") return null;
  for (const k of ["goto", "click", "fill", "expect"]) if (k in step) return k;
  return Object.keys(step)[0] || null;
}

async function runStep(page, { base, kind, step }) {
  if (kind === "goto") {
    await page.goto(`${base}${step.goto}`, { waitUntil: "domcontentloaded", timeout: NAV_TIMEOUT });
    return;
  }
  if (kind === "click") {
    await page.click(step.click, { timeout: STEP_TIMEOUT });
    return;
  }
  if (kind === "fill") {
    await page.fill(step.fill.selector, step.fill.value, { timeout: STEP_TIMEOUT });
    return;
  }
  if (kind === "expect") {
    const { selector, text } = step.expect;
    await page.waitForSelector(selector, { state: "visible", timeout: STEP_TIMEOUT });
    if (text) {
      const seen = (await page.textContent(selector)) || "";
      if (!seen.includes(text)) throw new Error(`expected text "${text}" in ${selector}`);
    }
    return;
  }
  throw new Error(`unknown step kind ${kind === null ? "(none)" : `"${kind}"`}`);
}

// Runs `flow` for `persona` in an already signed-in browser context. Returns
//   { persona, flow, verdict: "pass"|"fail", steps: [{n, kind, ok, error, shot}], reason }
// and resolves for every input, including a context that is already gone.
export async function runFlow(ctx, { base, persona, flow, outDir, viewport = { width: 1280, height: 900 } }) {
  const record = { persona, flow: flow.id, verdict: "pass", steps: [], reason: null };
  let page = null;
  try {
    mkdirSync(outDir, { recursive: true });
    page = await ctx.newPage();
    page.setViewportSize?.(viewport);
    let dialog = null;
    page.on("dialog", async (d) => {
      dialog = `${d.type()}: ${String(d.message()).slice(0, 200)}`;
      await d.dismiss().catch(() => {});
    });

    const steps = Array.isArray(flow.steps) ? flow.steps : [];
    if (steps.length === 0) throw new Error("flow has no steps");

    for (let i = 0; i < steps.length; i++) {
      const step = steps[i];
      const kind = stepKind(step);
      const entry = { n: i + 1, kind: kind === null ? "none" : kind, ok: true, error: null, shot: null };
      try {
        await runStep(page, { base, kind, step });
      } catch (e) {
        entry.ok = false;
        entry.error = String(e && e.message ? e.message : e).slice(0, 300);
      }
      // The frame is captured whatever happened, so a failure ships its picture.
      const shot = join(outDir, `${persona}-${flow.id}-${String(i + 1).padStart(2, "0")}.png`);
      try {
        await page.screenshot({ path: shot, fullPage: false });
        entry.shot = shot;
      } catch {
        entry.shot = null;
      }
      if (entry.ok && dialog) {
        entry.ok = false;
        entry.error = `native browser dialog (${dialog})`;
      }
      if (entry.ok && onAuthWall(page)) {
        entry.ok = false;
        entry.error = "session did not hold";
      }
      record.steps.push(entry);
      if (!entry.ok) {
        record.verdict = "fail";
        record.reason = `step ${entry.n} (${entry.kind}): ${entry.error}`;
        break;
      }
    }
  } catch (e) {
    record.verdict = "fail";
    record.reason = String(e && e.message ? e.message : e).slice(0, 300);
  } finally {
    if (page) await page.close().catch(() => {});
  }
  return record;
}

// An unreadable URL is not evidence of an auth wall, so it is not reported as
// one — and it must not throw out of the step loop either.
function onAuthWall(page) {
  try {
    return isAuthWall(new URL(page.url()).pathname);
  } catch {
    return false;
  }
}
