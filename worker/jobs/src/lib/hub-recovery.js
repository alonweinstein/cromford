// harness-jobs — the three helpers every hub-recovery write route shares
// (BH-1942 / BH-1909.0). They are real, not stubs: the promote (#1943) and
// restore-lab (#1944) routes are built on them, so they land with the contract.

// A write that cannot be undone asks for an explicit yes. Only the JSON literal
// `true` counts — not "true", not 1, not a truthy object — so a client that sends
// the wrong shape is refused rather than guessed at.
export function confirmed(body) { return body?.confirm === true; }

// One hub_lease_changes row, PREPARED and not run. The caller puts it in the
// same env.DB.batch as the write it records, so the audit row and the write land
// together or not at all. action, actor and outcome are passed through as given:
// a missing one fails the NOT NULL constraint instead of being filled with a
// default nobody chose.
export function auditStmt(env, { action, before_holder, before_epoch, after_holder, after_epoch, target, actor, reason, outcome }, t) {
  return env.DB.prepare(
    "INSERT INTO hub_lease_changes (action,before_holder,before_epoch,after_holder,after_epoch,target,actor,reason,outcome,at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
  ).bind(
    action, before_holder ?? null, before_epoch ?? null, after_holder ?? null, after_epoch ?? null,
    target ?? null, actor, reason ?? null, outcome, t,
  );
}

// A box the fleet has heard from: it has a box_status row.
export async function knownBox(env, box) {
  return typeof box === "string" && box !== ""
    && (await env.DB.prepare("SELECT 1 AS x FROM box_status WHERE box=?1").bind(box).first("x")) !== null;
}
