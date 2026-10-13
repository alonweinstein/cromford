// llm-sites-catalog — BH-2553 (BH-2540.0): the bundled catalog/llm-sites.json
// read as data, and how one site's cost rows are told apart from the rest.
// Pure; the LLM sites routes and their siblings import it.

import CATALOG from "../../../../catalog/llm-sites.json" with { type: "json" };

export const LLM_SITES = CATALOG.sites;

const STAGE = /^[a-z][a-z0-9._-]{0,63}$/;

// A site's `stage` as cost-row stages. "*" is every stage (the agent-call choke
// point). Anything that is not a plain stage name — "$COST_STAGE (default raw)",
// "(none — no cost row)" — names no stage a row can be matched on.
export function parseSiteStages(stage) {
  if (stage === "*") return { all: true, stages: [] };
  if (typeof stage !== "string") return { all: false, stages: [] };
  return { all: false, stages: stage.split("|").map((s) => s.trim()).filter((s) => STAGE.test(s)) };
}

/**
 * Which cost rows belong to `site`:
 * - 'lane': `stage IN stages AND (lane_id = lane OR lane_id IS NULL)`
 * - 'signature': `stage IN stages` (no lane; or `all`, every stage)
 * - 'none': no attributable stage, so no rows. A lane with no stage is 'none',
 *   never every row on that lane.
 * The lane rule mirrors GET /api/metrics/llm-spend in routes/cost.js; it is
 * restated here, not imported. `shared` is true when another site lists one of
 * the same stages (lanes ignored); a "*" site neither is nor makes one shared.
 */
export function siteAttribution(site, sites = LLM_SITES) {
  const { all, stages } = parseSiteStages(site.stage);
  const lane = site.lane || null;
  const attribution = !all && stages.length === 0 ? "none" : lane && stages.length > 0 ? "lane" : "signature";
  const shared = stages.length > 0 && sites.some((o) => o.id !== site.id && parseSiteStages(o.stage).stages.some((s) => stages.includes(s)));
  return { all, stages, lane, attribution, shared };
}
