// BH-5668 (BH-5008 child 2): batch progress and ETA from check-duration
// medians. Pure: no I/O, no clock (the caller passes nowMs).
//
// A check's expected seconds is its own median (merge_queue_check_medians by
// name), else the median of the medians in its job_class, else unknown.
//   eta_s     = sum over open checks of max(0, expected - elapsed). Checks run
//               in parallel, so this sum overstates wall time (the #5668 rule).
//   progress  = expected seconds of completed checks / of all checks. An
//               unknown weight is one equal share: the mean of the known
//               weights in the batch, or 1 each when none is known.
//   eta_basis = 'name' | 'class' (one or more used a class median) |
//               'partial' (one or more had neither: eta_s is null, never a
//               guessed 0) | 'done' (the batch finished: eta_s 0 is a fact).

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  if (!n) return null;
  return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
};

const known = (v) => typeof v === "number" && Number.isFinite(v) && v > 0;

// rows: [{ name, job_class, median_s }] → Map(job_class → median of median_s)
export function classMedians(rows) {
  const by = new Map();
  for (const r of rows || []) {
    if (!r || r.job_class == null || !known(r.median_s)) continue;
    if (!by.has(r.job_class)) by.set(r.job_class, []);
    by.get(r.job_class).push(r.median_s);
  }
  return new Map([...by].map(([k, xs]) => [k, median(xs)]));
}

// → { s, source: 'name' | 'class' | null }. A median of 0 or less is missing.
export function expectedOf(name, jobClass, byName, byClass) {
  const n = byName.get(name);
  if (known(n)) return { s: n, source: "name" };
  const c = jobClass == null ? undefined : byClass.get(jobClass);
  if (known(c)) return { s: c, source: "class" };
  return { s: null, source: null };
}

const round3 = (x) => Math.round(x * 1000) / 1000;

// checks: [{ name, job_class, status, started_at }]
export function batchEta(checks, medianRows, nowMs, { finished = false } = {}) {
  if (finished) return { progress: 1, eta_s: 0, eta_basis: "done" };
  const list = checks || [];
  if (!list.length) return { progress: 0, eta_s: null, eta_basis: "partial" };

  const byName = new Map();
  for (const r of medianRows || []) if (r && known(r.median_s)) byName.set(r.name, r.median_s);
  const byClass = classMedians(medianRows);

  const exp = list.map((c) => expectedOf(c.name, c.job_class, byName, byClass));
  const ws = exp.filter((e) => e.s != null).map((e) => e.s);
  const share = ws.length ? ws.reduce((a, x) => a + x, 0) / ws.length : 1;

  let all = 0, done = 0, eta = 0, missing = false, usedClass = false;
  list.forEach((c, i) => {
    const e = exp[i];
    const w = e.s ?? share;
    all += w;
    if (c.status === "completed") { done += w; return; }
    if (e.s == null) { missing = true; return; }
    if (e.source === "class") usedClass = true;
    const start = c.started_at ? Date.parse(c.started_at) : NaN;
    const elapsed = Number.isFinite(start) ? Math.max(0, (nowMs - start) / 1000) : 0;
    eta += Math.max(0, e.s - elapsed);
  });

  const progress = Math.min(1, Math.max(0, round3(all > 0 ? done / all : 0)));
  if (missing) return { progress, eta_s: null, eta_basis: "partial" };
  return { progress, eta_s: Math.round(eta), eta_basis: usedClass ? "class" : "name" };
}
