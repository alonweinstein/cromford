// harness-jobs — coordination truth for the box fleet (phase 1).
// Spec: docs/DB-COORDINATION-SPEC.md (approved by the operator, 2026-08-27).
//
// Jobs, stage events and lane budgets live in ONE D1 database that the hub,
// every watcher box and every ephemeral fly builder reads over HTTPS. That
// kills three classes by construction:
//   * double-build — in-flight work on box A is invisible to box B, so both
//     build the same ticket. POST /api/jobs 409s the second claimant.
//   * budget-config — catalog/context-budgets.json never lands on a fly
//     builder (fly-sync tars bin/prompts/rules only), so build lanes fell
//     through to the hardcoded tier and budget-stopped mid-run (TK-109, $424).
//     GET /api/catalog/:lane answers from the DB, no file needed.
//   * split-brain flags — phase 3: pause flags are rows the console can set,
//     and the box files they drive stay the thing every existing reader tests.
//   * silent deaths — phase 3: a claimant heartbeats its row, so a SIGKILLed
//     run leaves an ORPHANED row with a last-beat time instead of nothing.
//   * unattributable failures — phase 5: a job row said "failed" and nothing
//     said WHICH stage failed. job_phases records one row per stage attempt
//     (runner, rc, spend, note), as a CHILD of the claim — coordination stays
//     per JOB, so no stage ever re-asks permission to continue.
//   * collisions the code could not describe — phase 6: the concurrency rules
//     are ROWS, checked INSIDE the claim, so "one build per repo" is an UPDATE
//     and not a deploy. No row for a scope means unlimited.
//   * failures with no defined end — phase 6: a dead claim is JUDGED against a
//     per-lane retry policy and lands in exactly one terminal state
//     (queued_for_retry / parked / orphaned). The watchdog asks; it never runs
//     anything, and the lane's own next tick picks a queued row up.
//   * done with nothing to show for it — phase 7: a phase declares the ARTIFACT
//     it must produce (phase_contracts) and cannot close `done` without it; the
//     close lands as `contract_unmet` instead, naming what was missing.
//   * histories that cannot be true — phase 7: status moves are checked against
//     a transition graph, so `done` never walks back to `running` and a parked
//     job cannot skip to done without going through an attempt.
//   * a pause that only reached the boxes that asked — phase 7: pause_flags are
//     consulted INSIDE the claim, so a paused project stops a fly builder that
//     has never reconciled a file in its life. The file stays the fallback.
//
// Iron constraints held here: additive-only schema, no secret ever written to a
// row (meta included), and boxes authenticate with HARNESS_SECRET alone — no
// Cloudflare credential ever leaves the hub.
//
// The DB is COORDINATION truth, not BUILD truth. PRs, board comments and
// ALERTS.log remain the client-facing record; nothing here replaces them.
//
// ── HOW A REQUEST FINDS ITS HANDLER (BH-1195) ──────────────────────────────
// This file used to hold every route body too: one flat
// `if (path === … && req.method === …)` chain, 3,497 lines of it inside
// `fetch`. It is now the ENTRY and the TABLE, and nothing else. Each route
// family lives in ./routes/<family>.js and exports an ordered list of
// `[method, matcher, handler]` rows; ROUTES below is those lists concatenated
// IN THE CHAIN'S ORDER, and ./lib/router.js resolves first-match-wins.
//
// THE ORDER IS LOAD-BEARING. `GET /api/jobs/:id` sits above `GET /api/jobs`
// and `GET /api/settings` above the `/api/settings/` prefix, exactly as the
// chain had them; re-sorting this list alphabetically would re-point routes.
// test/route-table.test.js holds the pre-split chain as a fixture and compares
// the table against it, entry for entry, in order.
//
// THE BEARER STILL SITS BETWEEN THE TWO TABLES. OPEN_ROUTES is consulted
// FIRST and holds eight routes. Three are POST /webhooks/github, /webhooks/jira
// and /webhooks/linear (BH-4079). No vendor can send our bearer, so each carries
// its own HMAC, keyed on its own secret, instead. Two are POST and GET
// /api/ci/suite-durations (BH-5653). CI must not hold HARNESS_SECRET, so they
// check their own scoped bearer: CI_DURATIONS_TOKEN or HARNESS_SECRET. Three are
// the suite-ledger routes (BH-5366), for the same reason: each authenticates
// itself with credentialClass() (bearer or x-suite-ledger-token) before it reads
// the body. Everything
// in ROUTES is reached only after `bearerOk`, so a route in the wrong table is
// a route with the wrong credential.
import { bearerOk, json, nowIso, readBody } from "./lib/http.js";
import { CREATED_TABLES, MACHINE_STATES, MACHINE_TERMINAL } from "./lib/core.js";
import { matchRoute } from "./lib/router.js";
import { withHarnessSentry } from "./lib/sentry.js";

import { routes as webhooks } from "./routes/webhooks.js";
import { routes as suiteResults } from "./routes/suite-results.js";
import { routes as ciDurations } from "./routes/ci-durations.js";
import { routes as ciTestTiers } from "./routes/ci-test-tiers.js";
import { routes as capFlags } from "./routes/cap-flags.js";
import { routes as contracts } from "./routes/contracts.js";
import { routes as verdict } from "./routes/verdict.js";
import { routes as verdicts } from "./routes/verdicts.js";
import { routes as leadReviews } from "./routes/lead-reviews.js";
import { routes as riskTiers } from "./routes/risk-tiers.js";
import { routes as jevRisk } from "./routes/jev-risk.js";
import { routes as queueRisk } from "./routes/queue-risk.js";
import { routes as leadProtectedPaths } from "./routes/lead-protected-paths.js";
import { routes as catalog } from "./routes/catalog.js";
import { routes as jobDetail } from "./routes/job-detail.js";
import { routes as transcripts } from "./routes/transcripts.js";
import { routes as preplans } from "./routes/preplans.js";
import { routes as contextPacks } from "./routes/context-packs.js";
import { routes as machines } from "./routes/machines.js";
import { routes as jobArtifacts } from "./routes/job-artifacts.js";
import { routes as fileClaims } from "./routes/file-claims.js";
import { routes as phases } from "./routes/phases.js";
import { routes as rules } from "./routes/rules.js";
import { routes as retryPolicies } from "./routes/retry-policies.js";
import { routes as projects } from "./routes/projects.js";
import { routes as modelRoutes } from "./routes/model-routes.js";
import { routes as settings } from "./routes/settings.js";
import { routes as jobRetry } from "./routes/job-retry.js";
import { routes as jobAbandon } from "./routes/job-abandon.js";
import { routes as jobEvents } from "./routes/job-events.js";
import { routes as jobs } from "./routes/jobs.js";
import { routes as burn } from "./routes/burn.js";
import { routes as flags } from "./routes/flags.js";
import { routes as pauses } from "./routes/pauses.js";
import { routes as routing } from "./routes/routing.js";
import { routes as costCaps } from "./routes/cost-caps.js";
import { routes as configChanges } from "./routes/config-changes.js";
import { routes as ledger } from "./routes/ledger.js";
import { routes as prState } from "./routes/pr-state.js";
import { routes as prOwners } from "./routes/pr-owners.js";
import { routes as decisions } from "./routes/decisions.js";
import { routes as telegramTopics } from "./routes/telegram-topics.js";
import { routes as cost } from "./routes/cost.js";
import { routes as costLive } from "./routes/cost-live.js";
import { routes as cliVersions } from "./routes/cli-versions.js";
import { routes as boxes } from "./routes/boxes.js";
import { routes as usage } from "./routes/usage.js";
import { routes as outcomes } from "./routes/outcomes.js";
import { routes as dora } from "./routes/dora.js";
import { routes as flakes } from "./routes/flakes.js";
import { routes as reviewGate } from "./routes/review-gate.js";
import { routes as lanes } from "./routes/lanes.js";
import { routes as hubLease } from "./routes/hub-lease.js";
import { routes as hubRecovery } from "./routes/hub-recovery.js";
import { routes as restoreLab } from "./routes/restore-lab.js";
import { routes as hubStandby } from "./routes/hub-standby.js";
import { routes as hubStandbyVerify } from "./routes/hub-standby-verify.js";
import { routes as reconcileOwner } from "./routes/reconcile-owner.js";
import { routes as reconcileMemory } from "./routes/reconcile-memory.js";
import { routes as conductorHeld } from "./routes/conductor-held.js";
import { routes as accountLeases } from "./routes/account-leases.js";
import { routes as cooldowns } from "./routes/cooldowns.js";
import { routes as flyImages } from "./routes/fly-images.js";
import { routes as ghBudget } from "./routes/gh-budget.js";
import { routes as ghLedger } from "./routes/gh-ledger.js";
import { routes as artifacts } from "./routes/artifacts.js";
import { routes as queue } from "./routes/queue.js";
import { routes as closeoutAged } from "./routes/closeout-aged.js";
import { routes as mergeQueue } from "./routes/merge-queue.js";
import { routes as mergeQueueLive } from "./routes/merge-queue-live.js";
import { routes as mergeQueueReconcile } from "./routes/merge-queue-reconcile.js";
import { routes as mergeTrains } from "./routes/merge-trains.js";
import { routes as wakes } from "./routes/wakes.js";
import { routes as portCursor } from "./routes/port-cursor.js";
import { routes as alerts } from "./routes/alerts.js";
import { routes as alertActions } from "./routes/alert-actions.js";
import { routes as callGuard } from "./routes/call-guard.js";
import { routes as progress } from "./routes/progress.js";
import { routes as productProposals } from "./routes/product-proposals.js";
import { routes as ciHealth } from "./routes/ci-health.js";
import { routes as fixRounds } from "./routes/fix-rounds.js";
import { routes as boxConsoleCommands } from "./routes/box-console-commands.js";
import { routes as boxCommands } from "./routes/box-commands.js";
import { routes as llmSites } from "./routes/llm-sites.js";
import { routes as llmSiteRows } from "./routes/llm-site-rows.js";
import { routes as routeRules } from "./routes/route-rules.js";
import { routes as queueActions } from "./routes/queue-actions.js";
import { routes as deployQueueActions } from "./routes/deploy-queue-actions.js";
import { routes as alertFamilyScripts } from "./routes/alert-family-scripts.js";
import { routes as triageState } from "./routes/triage-state.js";
import { routes as splitWatchdog } from "./routes/split-watchdog.js";
import { routes as hubProbe } from "./routes/hub-probe.js";
import { routes as hubProbeCount } from "./routes/hub-probe-count.js";
import { routes as modelWatch } from "./routes/model-watch.js";
import { routes as costBreakdown } from "./routes/cost-breakdown.js";
import { routes as dailyDigest } from "./routes/daily-digest.js";
import { routes as dequeueWatch } from "./routes/dequeue-watch.js";
import { routes as utilization } from "./routes/utilization.js";
import { routes as initiatives } from "./routes/initiatives.js";
import { routes as outcomeGap } from "./routes/outcome-gap.js";
import { routes as archieResearch } from "./routes/archie-research.js";
import { routes as archieActions } from "./routes/archie-actions.js";
import { routes as archieAutonomy } from "./routes/archie-autonomy.js";
import { routes as poolState } from "./routes/pool-state.js";
import { routes as suiteReuseSaved } from "./routes/suite-reuse-saved.js";
import { routes as ciBatches } from "./routes/ci-batches.js";
import { routes as triageWaste } from "./routes/triage-waste.js";
import { routes as conflictHotspots } from "./routes/conflict-hotspots.js";
import { routes as queueBatchMinutes } from "./routes/queue-batch-minutes.js";
import { routes as participants } from "./routes/participants.js";
import { routes as registry } from "./routes/registry.js";
import { routes as registryWrite } from "./routes/registry-write.js";
import { routes as staff } from "./routes/staff.js";
import { routes as staffFindings } from "./routes/staff-findings.js";
import { routes as staffScreen } from "./routes/staff-screen.js";
import { routes as laneRuns } from "./routes/lane-runs.js";
import { routes as laneRunsLease } from "./routes/lane-runs-lease.js";
import { routes as laneFleet } from "./routes/lane-fleet.js";
import { routes as laneRunsMetrics } from "./routes/lane-runs-metrics.js";
import { routes as laneSnapshots } from "./routes/lane-snapshots.js";
import { routes as steer } from "./routes/steer.js";

// The names this module has always exported. They live in ./lib/core.js now;
// console-ui, the tests and bin/ read them from here, so here is where they
// stay re-exported — a split is not a reason for a caller to change an import.
export {
  decorateLane, decorateLease, doraRepo, doraPrNumber, percentile,
  doraDeployRepo, computeDora, ANCHOR_DEFAULT_ACCOUNT_MAP,
  ANCHOR_DEFAULT_MAX_FACTOR, ANCHOR_OFF_FLAG, parseAccountMap, parseBuildDir,
  parseStageBreakdown, anchorWindow, meterAccounts, anchorSpanCandidates,
  computeAnchored,
} from "./lib/core.js";

// BH-1068: the alerts slice's schema suite drives ensureTable() off index.js
// and compares CREATED_TABLES.alerts with schema.sql, so both names are
// re-exported here — the same rule as the block above: a split is not a reason
// for a caller to change an import.
export { ensureTable } from "./lib/core.js";
export { CREATED_TABLES };
// ...and the pure decision function the alerts note route is built on, which
// its own suite drives at the boundaries without a database.
export { alertDecision } from "./routes/alerts.js";

// The routes the main bearer does not open. The three webhooks are matched on
// PATH ALONE (method "*"), so a GET reaches each and gets its 405 instead of
// falling through to a 401 that would tell an operator the hook was
// unauthorised rather than misused. The two ci-durations routes (BH-5653) are
// matched on method and path, and each checks its own scoped bearer
// (CI_DURATIONS_TOKEN or HARNESS_SECRET) before it reads anything. So do the
// two ci-test-tiers routes (BH-5653 C1); their PUT takes HARNESS_SECRET only.
// The three suite-ledger routes (BH-5366) each make their own credential check
// before they read anything.
export const OPEN_ROUTES = [...webhooks, ...ciDurations, ...ciTestTiers, ...suiteResults];

// Every other route, in the order the chain had them.
export const ROUTES = [
  ...capFlags,
  ...contracts,
  ...verdict,
  ...verdicts,
  ...leadReviews,
  ...leadProtectedPaths,
  ...riskTiers,
  ...jevRisk,
  ...queueRisk,
  ...catalog,
  ...jobDetail,
  ...transcripts,
  ...preplans,
  ...contextPacks,
  ...machines,
  ...jobArtifacts,
  ...fileClaims,
  ...phases,
  ...rules,
  ...retryPolicies,
  ...projects,
  ...modelRoutes,
  ...settings,
  ...jobRetry,
  ...jobAbandon,
  ...jobEvents,
  ...jobs,
  ...burn,
  ...flags,
  ...pauses,
  ...routing,
  ...costCaps,
  ...configChanges,
  ...ledger,
  ...prState,
  ...prOwners,
  ...decisions,
  ...telegramTopics,
  ...cost,
  ...costLive,
  ...cliVersions,
  ...boxes,
  ...usage,
  ...outcomes,
  ...dora,
  ...flakes,
  ...reviewGate,
  ...lanes,
  ...hubLease,
  ...hubRecovery,
  ...restoreLab,
  ...hubStandby,
  ...hubStandbyVerify,
  ...reconcileOwner,
  ...reconcileMemory,
  ...conductorHeld,
  ...accountLeases,
  ...cooldowns,
  ...ghBudget,
  ...ghLedger,
  ...artifacts,
  ...queue,
  ...closeoutAged,
  ...mergeQueue,
  ...mergeQueueLive,
  ...mergeQueueReconcile,
  ...mergeTrains,
  ...wakes,
  ...portCursor,
  ...alerts,
  ...alertActions,
  ...callGuard,
  ...progress,
  ...flyImages,
  ...productProposals,
  ...ciHealth,
  ...fixRounds,
  ...boxConsoleCommands,
  ...boxCommands,
  ...llmSites,
  ...llmSiteRows,
  ...routeRules,
  ...queueActions,
  ...deployQueueActions,
  ...alertFamilyScripts,
  ...triageState,
  ...splitWatchdog,
  ...hubProbe,
  ...hubProbeCount,
  ...modelWatch,
  ...costBreakdown,
  ...dailyDigest,
  ...dequeueWatch,
  ...utilization,
  ...initiatives,
  ...outcomeGap,
  ...archieResearch,
  ...archieActions,
  ...archieAutonomy,
  ...poolState,
  ...ciBatches,
  ...triageWaste,
  ...conflictHotspots,
  ...queueBatchMinutes,
  ...participants,
  ...registry,
  ...registryWrite,
  ...staff,
  ...staffFindings,
  ...staffScreen,
  ...laneRuns,
  ...laneRunsLease,
  ...laneFleet,
  ...laneRunsMetrics,
  ...laneSnapshots,
  ...steer,
  ...suiteReuseSaved,
];

export default withHarnessSentry({
  CREATED_TABLES,
  MACHINE_STATES,
  MACHINE_TERMINAL,
  ROUTES,
  OPEN_ROUTES,
  async fetch(req, env) {
    const url = new URL(req.url);
    const path = url.pathname;
    // The server clock, taken ONCE per request and shared by every route. It is
    // hoisted above the bearer check because the /webhooks/* routes run before that
    // check and stamps rows with it; two clocks in one request would put two
    // different minutes on the dedupe key of a single delivery.
    const t = nowIso();

    // The open table first, and it never sees `body`: the raw TEXT is what the
    // webhook's signature covers, and re-serialising a parsed object would
    // verify a different string than the one that was signed.
    const open = matchRoute(OPEN_ROUTES, req.method, path);
    if (open) return open.handler({ req, env, url, path, t, m: open.m });

    if (!bearerOk(req, env)) return json(401, { error: "unauthorized" });

    const body = await readBody(req);

    const hit = matchRoute(ROUTES, req.method, path);
    if (hit) return hit.handler({ req, env, url, path, t, body, m: hit.m });

    // `worker` is this worker's identity on the one answer a client has to
    // tell apart from somebody else's 404 (BH-1525): bin/lib/verdicts.sh reads
    // THIS body as "the route is not deployed here", and any other 404 — a
    // Cloudflare 1042 for a deleted host, a proxy, an HTML page — as unknown.
    return json(404, { error: "unknown endpoint", worker: "harness-jobs" });
  },
}, { worker: "harness-jobs", pauseFlags: true });
