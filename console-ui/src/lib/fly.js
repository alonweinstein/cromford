// Whether a project's Fly block is a measurement or a gap.
//
// The Worker publishes `fly[project]` and, separately, a `fly_errors` list. When
// a per-project read token is missing it still fills the block in — machine_count
// 0, machines [], and every claimed queue row as an "orphan" — so the console
// reported "0 machines, 6 orphan jobs" about a project with six machines running
// (BH-667, 2026-09-17). Absent is not zero: if we could not ask Fly, the only
// honest readout is the reason we could not.
//
// Three signals, any one of which means "do not trust the numbers in this block":
// the new `unreadable` flag the Worker is asked to set, an absent machine_count
// (the ticket lets the Worker null it or drop the key, and neither is 0), and an
// entry for this project in fly_errors — the last one is what the deployed
// Worker sends today, so the screens stop lying the moment this ships, without
// waiting on the Worker change.

// Both screens hold the whole /api/dash/machines payload, and a reader needs one
// project's block AND the payload's fly_errors list. Handing the block over
// without the errors is exactly how the bug shipped, so the pair is built here,
// once, and spread into the component — there is no per-prop call site left to
// forget.
export function flyProjectProps(data) {
  const d = data || {};
  const fly = d.fly || {};
  const flyErrors = d.fly_errors || [];
  return Object.keys(fly).map((project) => ({ project, fly: fly[project], flyErrors }));
}

export function flyUnreadableReason(block, flyErrors, project) {
  const b = block || {};
  const err = (flyErrors || []).find((e) => e && e.project === project);
  // A dropped key only counts as absent when there is no machine list either —
  // a block that carries the machines has been read, whether or not it totals them.
  const countAbsent = b.machine_count === null
    || (b.machine_count === undefined && !Array.isArray(b.machines));
  if (b.unreadable !== true && !countAbsent && !err) return null;
  return b.unreadable_reason || (err && err.error) || 'fly not enumerated';
}

// null, never [] — an empty list reads as "we looked and found nothing".
export function flyMachines(block, reason) {
  if (reason) return null;
  return (block && block.machines) || [];
}

// Orphan detection compares claimed queue rows against the live machine list.
// With no machine list there is nothing to compare against, so the answer is
// "unknown", which renders as no claim at all rather than as every job.
export function flyOrphans(block, reason) {
  if (reason) return [];
  return (block && block.orphan_jobs) || [];
}
