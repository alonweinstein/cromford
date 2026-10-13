// The verdict sources whose newest row on a head STANDS (routes/verdicts.js,
// BH-5022). A box row is history only. A risk-tier row stands too, because
// vd_standing is what every merge lane reads; it can only ever be a MERGE, and
// a later lead or human row on the head is newer, so it never outranks a
// reviewer. ONE list (lead review lr-5060-f2bef1d50074): the verdicts route,
// its SQL and the PR gate's event writer (lib/pr-gate-intake.js) all read it,
// so the gate table and the reconcile sweep cannot disagree about a source.
export const STANDING_SOURCES = Object.freeze(["lead", "human", "risk-tier"]);
