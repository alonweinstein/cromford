# Pre-plan adoption panel

**What it is:** the PREPLAN ADOPTION section of a project's page. It shows how
many of the pre-plans the box bought for this project a build actually used,
over the `PREPLAN_ADOPT_WINDOW_DAYS` window (default 7). It shows the rate, a
daily chart and the recent pre-plan events. It is read-only.

**How a user reaches it:** open the console → FLEET → click a project → `/p/<project>`
→ the PREPLAN ADOPTION section in the right column, directly under ROUTING.

**Key routes/screens:**
- `/p/<project>`, PREPLAN ADOPTION section: `kv` lines `<n>D RATE` (a percent,
  or `—` when nothing was bought in the window), BOUGHT, ADOPTED, STALE, MISS.
  The `<n>` is the window the route answered for. A `CADENCE CUT` tag
  (`span.tag.tag--warn`) sits next to the rate when at least
  `PREPLAN_ADOPT_MIN_SAMPLES` pre-plans were bought and under
  `PREPLAN_ADOPT_FLOOR_PCT` percent were adopted. When the settings read
  fails, the section says "floor from defaults: settings unreadable" and uses
  50 / 10 / 7.
- The chart: `svg[role="img"][aria-label^="daily pre-plan adopt rate"]` inside
  its own `overflow-x:auto` wrapper. It has one bar (`path.adopt-bar`) per day
  with a bought pre-plan. A day with none has a dashed tick
  (`line.adopt-gap`, tooltip "<day>: no bought pre-plans"), not a 0% bar. There
  is a 0% / 50% / 100% axis and a dashed 50% reference line (`line.adopt-ref`).
  Each day's tooltip reads "<day>: NN% (adopted/bought)".
- The events table has AT, TICKET, VERDICT and DETAIL. Every header sorts, and
  the newest AT comes first by default. AT and TICKET link to `/jobs/<job_id>`.
  It holds at most 50 rows, and says "newest 50 shown; older events exist"
  when the route says there are more.
- Reads: `GET /api/coord/settings` for the three `lane.preplan-tick[.<p>].preplan_adopt_*`
  knobs (the project row first, then the lane row, as `lane_knob` reads them),
  then `GET /api/coord/preplans/adoption?project=<p>&days=<window>`. The coord
  proxy forwards it to the jobs worker's `GET /api/preplans/adoption`. The
  panel sends no writes.

**Preconditions:** signed in to the console. The jobs worker's
`/api/preplans/adoption` route is deployed. Until it is, the section shows
"could not load — http_404" (or the worker's error) with RETRY, and never a
percentage.

**Verify it works:** on `/p/<project>` the section shows the rate header, the
chart and the table, or "no pre-plan events for <p> in the last <n> days" for a
project with none. Neither the empty state nor the error state shows a
percentage. Sort the table by AT, TICKET and VERDICT and check that the arrow
flips. Click a row's ticket and land on `/jobs/<job_id>`. Hover a bar to see its
tooltip. At 375px the body does not scroll sideways, and the chart and the
table each scroll inside their own wrapper.

**Manual-only / not automatable:** the populated view needs the worker route
deployed and real `stage_events` preplan rows. The node suite drives it from
fixtures shaped like the route's documented answer.
