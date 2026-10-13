import { useState, useCallback, useRef } from 'preact/hooks';
import { html, Link, navigate } from '../router.js';
import { PageHeadline, StatGrid } from '../ui/line.js';
import { fleetHeadline } from '../lib/line-screens.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useFleet } from '../app.js';
import {
  agoFromMinutes, healthFromAge, minutesFromPingText, minutesSince, snapshotLabel, shortSha, safeHttpsUrl, countOrNull
} from '../lib/format.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, Age, healthColor, Cursor, Legend } from '../ui/primitives.js';
import { runOutcome, OUTCOME_LABEL, OUTCOME_TONE } from '../lib/cockpit.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Dot, Diamond, Clock } from '../ui/icons.js';
import { externalActors } from '../lib/lanes.js';
import { snapshotAgeMinFromEpochSeconds } from '../lib/tickets.js';
import { flyMachines, flyOrphans, flyProjectProps, flyUnreadableReason } from '../lib/fly.js';
import { backupBadge } from '../lib/backups.js';
import { ghQuotaBadge } from '../lib/ghquota.js';
import {
  shapePauses, pausesForProject, endCommandFor, fleetPauseCommandFor, pauseDetail, pauseActorText, boardPauseLines
} from '../lib/pauses.js';
import { useConfirm } from '../ui/Modal.js';
import { FleetPauseForm, PauseReasonForm } from '../ui/PauseForms.js';
import { FactoryStopBanner } from '../ui/FactoryStopBanner.js';
import { shapeProjectFlags, wipInputError, cellText, flagSortValue } from '../lib/flagrows.js';

// Same map as Now.js, so LAST RESULT reads in the colours /now uses.
const TONE_CLASS = { green: 'tag tag--green', dead: 'tag tag--dead', warn: 'tag tag--warn', muted: 'tag tag--idle' };

// What the FLAGS and LAST RESULT columns mean, said under the table rather than
// only in a title a phone never shows. `PAUSED (what)` keeps its space so the
// section never renders the `PAUSED(` a live pause tag uses.
export const FLEET_FLAGS_LEGEND = [
  { term: 'PAUSED', text: "this board's flag file is set, so the box skips triage and builds for it" },
  { term: 'PAUSED (what)', text: 'a live pause row, from the console or the hub, covering this project; the tag names what it stops' },
  { term: 'NO AUTOMERGE', text: 'tier-1 approved PRs wait for a human instead of merging themselves' },
  { term: 'LAST RESULT', text: 'how the last tick ended: OK, FAILED, KILLED by the system, or UNKNOWN when no exit code came back' }
];

// QUEUE sorts on the number; a project with no queue reading sinks in both
// directions instead of sorting as an empty queue.
export const queueSortKey = (r) => (r.fleet && r.fleet.queue_depth !== undefined && r.fleet.queue_depth !== null
  ? Number(r.fleet.queue_depth) : null);

export function FleetScreen() {
  const fleet = useFleet();
  const machines = useApi(() => api.machines(), [], { intervalMs: 30000 });
  const projects = useApi(() => api.projects(), [], { intervalMs: 30000 });
  // Third-party harnesses never ping the watchdog, so they cannot be boxes —
  // but their work is real and needs somewhere to appear.
  const tickets = useApi(() => api.ticketsSnapshot(), [], { intervalMs: 60000 });
  // Live pauses (BH-1672), a read of their own so useFleet's shape is
  // untouched. A failed read (the worker routes absent, a 404, the network)
  // leaves data null, which is zero rows: no banner and no tag, never a crash.
  const pausesApi = useApi(() => api.pauses(), [], { intervalMs: 30000 });
  const [dialog, confirm] = useConfirm();
  const [endBusy, setEndBusy] = useState(null);
  const [endMsg, setEndMsg] = useState(null);
  const [fleetBusy, setFleetBusy] = useState(false);
  // BH-5643: the paused-<p> / wip-limit-<p> rows and the routing rows, each a
  // read of its own. A failed read is null data, so its cells read "—".
  const flagsApi = useApi(() => api.coordFlags(), [], { intervalMs: 30000 });
  const routingApi = useApi(() => api.routingAll(), [], { intervalMs: 30000 });
  const [flagBusy, setFlagBusy] = useState(null);
  const flagLatch = useRef(false);

  const snap = fleet.data || {};
  const rows = (projects.data && projects.data.projects) || [];
  const flyByProject = (machines.data && machines.data.fly) || {};
  const boxes = (machines.data && machines.data.boxes) || {};
  const flyErrors = (machines.data && machines.data.fly_errors) || [];
  const pauseView = shapePauses(pausesApi.data, Date.now());
  const pauses = pauseView.rows;
  const flagCells = shapeProjectFlags(flagsApi.error ? null : flagsApi.data,
    routingApi.error ? null : routingApi.data, rows.map((r) => r.project));

  // One flag write at a time (BH-5643). The latch covers the dialog and the
  // PUT, so a double click sends one request. The cell never changes on the
  // click: it shows only what the re-read after the PUT says.
  const writeFlag = useCallback(async (project, name, active, value, reason, done) => {
    setFlagBusy(project);
    setEndMsg(null);
    try {
      await api.setFlag(name, active, value, reason);
      setEndMsg({ ok: true, text: `${name} ${done}. Re-read shows the row.` });
    } catch (e) {
      setEndMsg({ ok: false, text: `${name} refused — ${e.message}` });
    } finally {
      flagLatch.current = false;
      setFlagBusy(null);
      flagsApi.reload();
    }
  }, [flagsApi]);

  // PAUSE / RESUME one project's paused-<p> row, with a required reason.
  const togglePause = useCallback(async (project, cell) => {
    if (flagLatch.current || !cell || cell.paused === null) return;
    flagLatch.current = true;
    setFlagBusy(project);
    const target = !cell.paused;
    const verb = target ? 'PAUSE' : 'RESUME';
    const form = { reason: '' };
    let ok = false;
    try {
      ok = await confirm({
        title: `${verb} ${project}`, tone: target ? 'warn' : undefined, confirmLabel: verb, confirmBlocked: true,
        body: ({ setBlocked }) => html`<${PauseReasonForm} value=${form} onBlocked=${setBlocked}
          text=${html`Set <b>paused-${project}</b> ${target ? 'on' : 'off'}. Boxes pick up the row through flag sync.`}/>`
      });
    } finally {
      if (!ok || !form.reason.trim()) { flagLatch.current = false; setFlagBusy(null); }
    }
    if (!ok || !form.reason.trim()) return;
    await writeFlag(project, `paused-${project}`, target, null, form.reason.trim(), target ? 'set on' : 'set off');
  }, [confirm, writeFlag]);

  // SAVE one project's wip limit. A bad number is refused here, with no request.
  const saveWip = useCallback(async (project, text) => {
    if (flagLatch.current) return;
    const err = wipInputError(text);
    if (err) { setEndMsg({ ok: false, text: `wip-limit-${project} refused — ${err}` }); return; }
    flagLatch.current = true;
    const n = text.trim();
    await writeFlag(project, `wip-limit-${project}`, true, n, 'set from Mission Control', `set to ${n}`);
  }, [writeFlag]);

  // END asks why (BH-2509). `form` is a fresh object per click that
  // PauseReasonForm writes through; the confirm stays blocked until a reason
  // is typed, and endCommandFor refuses a blank one as the backstop.
  const endPause = useCallback(async (row) => {
    if (endBusy !== null) return;
    const form = { reason: '' };
    const ok = await confirm({
      title: 'END PAUSE', tone: 'warn', confirmLabel: 'END PAUSE', confirmBlocked: true,
      body: ({ setBlocked }) => html`<${PauseReasonForm} value=${form} onBlocked=${setBlocked}
        text=${html`End <b>PAUSED(${row.what})</b> on <b>${row.scopeLabel}</b>? Reason on record: ${row.reasonText}.`}/>`
    });
    if (!ok) return;
    const cmd = endCommandFor(row, form.reason);
    if (cmd.error) { setEndMsg({ ok: false, text: `END PAUSE refused — ${cmd.error}` }); return; }
    setEndBusy(row.id);
    setEndMsg(null);
    try {
      const res = await api.action(cmd);
      setEndMsg({ ok: true, text: `END PAUSE queued as command #${res.command_id}` });
    } catch (e) {
      setEndMsg({ ok: false, text: `END PAUSE refused — ${e.message}` });
    } finally {
      setEndBusy(null);
      pausesApi.reload();
    }
  }, [confirm, endBusy, pausesApi]);

  // PAUSE FLEET (BH-2509): pause_set scope=fleet through the same console
  // action as every other command. The reason and the ttl are required. The
  // banner says the command was queued, never that the fleet is paused: the
  // row lands when the hub's poller runs it, and the PAUSES table shows it.
  // Busy covers the dialog and the POST, so a double click sends one command.
  const pauseFleet = useCallback(async () => {
    if (fleetBusy) return;
    setFleetBusy(true);
    try {
      const form = { what: 'merges', reason: '', ttlS: '' };
      const ok = await confirm({
        title: 'PAUSE FLEET', tone: 'warn', confirmLabel: 'PAUSE FLEET',
        confirmBlocked: Boolean(fleetPauseCommandFor(form).error),
        body: ({ setBlocked }) => html`<${FleetPauseForm} value=${form} onBlocked=${setBlocked}/>`
      });
      if (!ok) return;
      const cmd = fleetPauseCommandFor(form);
      if (cmd.error) { setEndMsg({ ok: false, text: `PAUSE FLEET refused — ${cmd.error}` }); return; }
      setEndMsg(null);
      try {
        const res = await api.action(cmd);
        setEndMsg({ ok: true, text: `PAUSE FLEET queued as command #${res.command_id}` });
      } catch (e) {
        setEndMsg({ ok: false, text: `PAUSE FLEET refused — ${e.message}` });
      }
      pausesApi.reload();
    } finally {
      setFleetBusy(false);
    }
  }, [confirm, fleetBusy, pausesApi]);

  const building = rows.reduce((n, r) => n + ((r.fleet && r.fleet.pool) ? 1 : 0), 0)
    + Object.values(flyByProject).reduce((n, f) => n + ((f.jobs || []).length), 0);
  const queueDepth = rows.reduce((n, r) => n + Number((r.fleet && r.fleet.queue_depth) || 0), 0);
  const boxNames = Object.keys(boxes);
  const boxesUp = boxNames.filter((b) => healthFromAge(minutesFromPingText(boxes[b])) === 'ok').length;

  // Every tile below gates on the DATA, never on the loading flag: an errored
  // useApi returns {data:null, loading:false}, so falling through to a computed
  // 0 renders "0 boxes up" — indistinguishable from a dead fleet when the truth
  // is that we failed to ask. BUILDING NOW sums the box lane AND the fly lane,
  // so it needs both loaded or it is a fleet total built from half the inputs.
  return html`
    <div class="page">
      ${dialog}
      <${FleetHeadline} boxes=${machines.data ? boxes : null}
        building=${projects.data && machines.data ? building : null}
        queueDepth=${projects.data ? queueDepth : null}
        openAlerts=${fleet.data ? (snap.open_alerts || 0) : null}/>
      <div class="stats">
        <${Stat} label="BOXES UP" to="/machines"
          value=${machines.data ? boxesUp : '…'}
          unit=${machines.data ? `/${boxNames.length}` : null}
          tone=${machines.data && boxNames.length && boxesUp < boxNames.length ? 'warn' : null} />
        <${Stat} label="BUILDING NOW"
          value=${projects.data && machines.data ? building : '…'} tone="green" />
        <${Stat} label="BUILDS WAITING FOR A MACHINE" value=${projects.data ? queueDepth : '…'} />
        <${Stat} label="OPEN ALERTS" value=${fleet.data ? (snap.open_alerts || 0) : '…'}
          tone=${snap.open_alerts ? 'warn' : null} to="/alerts" />
        <${Stat} label="PROJECTS" value=${projects.data ? rows.length : '…'} to="/kanban" />
      </div>

      <${Section} title="MACHINES" note="orgo boxes + fly builders"
        right=${html`<${Link} to="/machines" style="font-size:var(--fs-xs);letter-spacing:1px">ALL MACHINES ›<//>`}>
        ${machines.loading && !machines.data
          ? html`<${Skeleton} rows=${2} height=${64}/>`
          : machines.error && !machines.data
            ? html`<${ErrorBox} error=${machines.error} onRetry=${machines.reload}/>`
            : html`
              <div class="tiles">
                <${HubTile} snap=${snap} />
                ${boxNames.map((name) => html`<${BoxTile} key=${name} name=${name} ping=${boxes[name]}
                  backup=${(snap.snapshot && snap.snapshot.backups) ? snap.snapshot.backups[name] : undefined}
                  staleMin=${snap.snapshot ? snap.snapshot.backup_stale_min : undefined}
                  ghQuota=${(snap.snapshot && snap.snapshot.gh_rest_quota) ? snap.snapshot.gh_rest_quota[name] : undefined}
                  ghReserve=${snap.snapshot ? snap.snapshot.gh_quota_reserve : undefined} />`)}
                ${flyProjectProps(machines.data).map((p) => html`
                  <${FlyTile} key=${p.project} ...${p} />`)}
                ${externalActors(tickets.data).map((a) => html`
                  <${ExternalTile} key=${a.actor} lane=${a}
                    snapshotAgeMin=${snapshotAgeMinFromEpochSeconds(tickets.data && tickets.data.generated_at_epoch)} />`)}
              </div>
              ${flyErrors.length ? html`
                <div class="footnote" style="margin-top:8px">
                  <span style="color:var(--amber-dk)">fly not enumerated for
                    ${flyErrors.map((e) => e.project).join(', ')} — ${flyErrors[0].error}</span>
                </div>` : null}`}
      <//>

      <${FactoryStopBanner} confirm=${confirm} />
      <div style="display:flex;justify-content:flex-end;flex-wrap:wrap;gap:8px">
        <button class="btn btn--warn" type="button" disabled=${fleetBusy || endBusy !== null}
          onClick=${pauseFleet}>
          ${fleetBusy ? 'PAUSING…' : 'PAUSE FLEET…'}
        </button>
      </div>
      ${endMsg ? html`
        <div class=${endMsg.ok ? 'banner banner--warn' : 'banner'}
          style=${endMsg.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${endMsg.text}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${() => setEndMsg(null)}>DISMISS</button>
        </div>` : null}
      <${PauseBanner} rows=${pauses} truncated=${pauseView.truncated} onEnd=${endPause} busyId=${endBusy} />

      <${Section} title="PROJECTS"
        note=${projects.data
          ? `${rows.length} ${projects.data.projects_source === 'fleet_status'
              ? 'from the fleet registry'
              : 'from the fallback constant — no fleet beat yet'} · ${snapshotLabel(projects.data.snapshot_age_min)}`
          : ''}>
        ${projects.loading && !projects.data
          ? html`<${Skeleton} rows=${6} height=${20}/>`
          : projects.error && !projects.data
            ? html`<${ErrorBox} error=${projects.error} onRetry=${projects.reload}/>`
            : html`<${ProjectsTable} rows=${rows} recentRuns=${snap.recent_runs || {}} pauses=${pauses}
                flagCells=${flagCells} onPause=${togglePause} onSaveWip=${saveWip} busy=${flagBusy} />`}
        <${Legend} items=${FLEET_FLAGS_LEGEND}/>
        <div class="footnote">
          <${Clock}/>
          <span>every row drills into runs, builds, logs and controls · the fleet poll refreshes every 30s</span>
          <span class="footnote__spacer"></span>
          <${Cursor}/>
        </div>
      <//>
    </div>`;
}

// The hub pushes the snapshot, so the snapshot's own age IS the hub's liveness.
// BH-4992 (wave 3 of BH-4947): the fleet's condition in words, from the reads
// the screen already makes. A count that was not read shows "…", never 0.
export function FleetHeadline({ boxes, building = null, queueDepth = null, openAlerts = null }) {
  const f = fleetHeadline({ boxes, building, queueDepth, openAlerts });
  const c = f.counts;
  const v = (x) => (x === null || x === undefined ? '…' : x);
  return html`
    <${PageHeadline} chip="Fleet" asOf="Machines read · every 30s" line1=${f.line1} line2=${f.line2} lede=${f.lede}>
      <${StatGrid} items=${[
        { label: 'Answering', value: v(c && c.ok), tone: 'live', to: '/machines' },
        { label: 'Overdue', value: v(c && c.warn), tone: c && c.warn ? 'warn' : undefined, to: '/machines' },
        { label: 'Silent', value: v(c && c.dead + c.unknown), tone: c && (c.dead + c.unknown) ? 'warn' : undefined, to: '/machines' },
        { label: 'Building now', value: v(building) },
        { label: 'Waiting for a machine', value: v(queueDepth) },
        { label: 'Open alerts', value: v(openAlerts), tone: openAlerts ? 'warn' : undefined, to: '/alerts' }
      ]}/>
    <//>`;
}

function HubTile({ snap }) {
  const age = snap.snapshot_age_min;
  const health = healthFromAge(age);
  const cls = health === 'ok' ? 'tile tile--live' : health === 'warn' ? 'tile tile--warn' : 'tile tile--dead';
  return html`
    <${Link} to="/machines" class=${cls}>
      <div class="tile__head">
        <${Dot} color=${healthColor(health)} size=${7}/>
        <span class="tile__name">hub</span>
        <span class="tile__ping">beat ${agoFromMinutes(age)}</span>
      </div>
      <span class="tile__meta">orchestrator · fly dispatch</span>
      <div class="tile__stats">
        <span>alerts 24h <b>${snap.snapshot ? (snap.snapshot.alerts_24h ?? 0) : '—'}</b></span>
        <span>paused <b>${snap.snapshot && snap.snapshot.pause_flags ? snap.snapshot.pause_flags.length : '—'}</b></span>
      </div>
    <//>`;
}

// A watchdog ping is the one liveness signal that survives the hub going down.
// `backup` is this box's entry from the hub's `backups` block (BH-399): the box
// is up, but is anything of it OFF the box? An old hub pushes no such block,
// and the tile then says nothing it cannot support. `staleMin` is the hub's own
// threshold, pushed beside the ages so the pill and the page move together when
// the operator changes the knob; absent, the helper's documented 30m applies.
// `ghQuota` is this box's entry from the hub's `gh_rest_quota` block (BH-1484):
// how much of the SHARED GitHub App bucket the REST reads themselves last saw,
// red under the reserve the gate is refusing optional reads at. Only a box
// whose ledger the hub can read has an entry; the rest render nothing, for the
// same reason the backup block does.
export function BoxTile({ name, ping, backup, staleMin, ghQuota, ghReserve }) {
  const min = minutesFromPingText(ping);
  const health = healthFromAge(min);
  const cls = health === 'ok' ? 'tile tile--live' : health === 'warn' ? 'tile tile--warn' : 'tile tile--dead';
  const bk = backupBadge(backup, staleMin);
  const gq = ghQuotaBadge(ghQuota, ghReserve);
  return html`
    <${Link} to="/machines" class=${cls}>
      <div class="tile__head">
        <${Dot} color=${healthColor(health)} size=${7}/>
        <span class="tile__name">${name}</span>
        <span class="tile__ping">ping ${min === null ? 'never' : agoFromMinutes(min)}</span>
      </div>
      <span class=${health === 'ok' ? 'tile__meta' : 'tile__meta tile__meta--warn'}>
        ${health === 'unknown' ? 'no ping on record' : health === 'ok' ? 'orgo box · answering' : 'orgo box · overdue'}
      </span>
      ${bk.known ? html`
        <div class="tile__stats" data-testid="box-backup" title=${bk.title}>
          <span class=${bk.tone === 'warn' || bk.tone === 'dead' ? 'tile__meta--warn' : undefined}>${bk.text}</span>
          ${bk.badge ? html`<span class="pill pill--dead">${bk.badge}</span>` : null}
        </div>` : null}
      ${gq.known ? html`
        <div class="tile__stats" data-testid="box-gh-quota" title=${gq.title}>
          <span class=${gq.low ? 'tile__meta--warn' : undefined}>${gq.text}</span>
          ${gq.badge ? html`<span class="pill pill--dead">${gq.badge}</span>` : null}
        </div>` : null}
    <//>`;
}

// Fly builders are the cyan lane: ephemeral machines, each carrying a ticket.
export function FlyTile({ project, fly, flyErrors }) {
  const jobs = fly.jobs || [];
  // The jobs come from the jobs ledger, so they stay true even when Fly cannot
  // be read; the machine count and the orphan line are Fly-derived and do not.
  const reason = flyUnreadableReason(fly, flyErrors, project);
  const machines = flyMachines(fly, reason);
  const orphans = flyOrphans(fly, reason);
  const live = (machines || []).filter((m) => m.state === 'started').length;
  return html`
    <${Link} to=${`/p/${encodeURIComponent(project)}`} class="tile tile--cyan">
      <div class="tile__head">
        <${Diamond} color="var(--cyan)" size=${9}/>
        <span class="tile__name">fly · ${project}</span>
        ${reason
          ? html`<span class="tile__ping" style="color:var(--amber-dk)">cannot read</span>`
          : html`<span class="tile__ping" style="color:var(--cyan-dk)">${live}/${machines.length} up</span>`}
      </div>
      ${jobs.length
        ? jobs.slice(0, 3).map((j) => html`
            <span key=${j.machine} class="tile__meta tile__meta--cyan">
              ${j.key || j.ticket_id || j.machine} · ${agoFromMinutes(minutesSince(j.spawned_at))}
              ${j.attempt ? ` · attempt ${j.attempt + 1}` : ''}
            </span>`)
        : html`<span class="tile__meta">no machine building right now</span>`}
      ${reason
        ? html`<span class="tile__meta tile__meta--warn">fly not readable · ${reason}</span>`
        : orphans.length ? html`
          <span class="tile__meta tile__meta--warn">
            ${orphans.length} job${orphans.length > 1 ? 's' : ''} whose machine Fly no longer returns
          </span>` : null}
    <//>`;
}


// A third-party harness. It has NO ping data — it never talks to our watchdog —
// so this row must never render an up/down light. What it can honestly show is
// how old the snapshot that mentioned it is, and when the lane last moved.
function ExternalTile({ lane, snapshotAgeMin }) {
  const latest = lane.latestAt ? minutesSince(lane.latestAt) : null;
  const withPr = lane.lanes.filter((l) => l.pr);
  const href = withPr.length ? safeHttpsUrl(withPr[0].pr_url) : null;
  return html`
    <div class="tile tile--external"
      title="an external harness — it does not ping our watchdog, so there is no up/down to report">
      <div class="tile__head">
        <${Diamond} color="var(--amber-txt)" size=${9}/>
        <span class="tile__name" title=${lane.logins.length > 1 ? `accounts: ${lane.logins.join(', ')}` : lane.logins[0]}>
          ${lane.label}
        </span>
        <span class="tile__ping" title="age of the snapshot that reported this lane">
          snapshot ${snapshotAgeMin === null ? 'age unknown' : agoFromMinutes(snapshotAgeMin)}
        </span>
      </div>
      <span class="tile__meta">
        ${lane.projects.map((p, i) => html`
          <span key=${p}>${i > 0 ? ', ' : ''}<${Link} to=${`/p/${encodeURIComponent(p)}`}>${p}<//></span>`)}
        ${` · ${lane.lanes.length} lane${lane.lanes.length === 1 ? '' : 's'}`}
      </span>
      <span class="tile__meta">
        ${withPr.length
          ? (href
              ? html`<a href=${href} target="_blank" rel="noopener noreferrer">PR #${withPr[0].pr} ↗</a>`
              : html`<span>PR #${withPr[0].pr}</span>`)
          : html`<span>branch only — no PR opened</span>`}
        ${latest === null ? ' · no activity date' : ` · active ${agoFromMinutes(latest)} ago`}
      </span>
      <div class="tile__stats">
        <span style="color:var(--amber-dk)">no ping data — not a monitored box</span>
      </div>
    </div>`;
}

// Exported for console-ui/tests/fleet-queue-tail.bh-1461.test.js, the way
// BoxTile and FlyTile are: the QUEUE cell's held/failed tail is a claim about
// what an operator SEES, and the only honest way to check it is to render the
// real table and read the HTML back.
export function ProjectsTable({ rows, recentRuns, pauses = [], flagCells = null, onPause = null, onSaveWip = null, busy = null }) {
  // BH-5643: with no flagCells (a caller that reads no flags) every flag cell
  // is null, which renders "—" and offers no button.
  const cellFor = (r) => (flagCells && flagCells[r.project]) || { paused: null, wip: null, route: null };
  const columns = [
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>`
    },
    {
      key: 'last_summary', label: 'LAST TICK', sort: (r) => r.last_run_age_min,
      cell: (r) => html`
        <span class="cell-wrap" title=${r.last_summary || ''}>
          <span style="color:var(--faint)">${agoFromMinutes(r.last_run_age_min)}</span>
          ${r.last_summary ? ` · ${r.last_summary}` : ' · no run on record'}
        </span>`
    },
    {
      key: 'last_rc', label: 'LAST RESULT', raw: 'RC', sort: (r) => r.last_rc, align: 'right',
      cell: (r) => {
        const o = runOutcome({ rc: r.last_rc });
        return o === 'unknown'
          ? html`<span class="na">—</span>`
          : html`<span class=${TONE_CLASS[OUTCOME_TONE[o]]} title=${`exit code ${r.last_rc}`}>${OUTCOME_LABEL[o]}</span>`;
      }
    },
    {
      key: 'queue', label: 'QUEUE', unit: 'builds', sort: queueSortKey, align: 'right',
      // BH-1461: queue_depth counts only rows waiting for a machine. Held rows
      // (bin/fly-pool.sh's HOLD gate skips them and keeps the queue file) and
      // terminal *.failed.json parks ride in their own fields, and are shown
      // here rather than dropped — a pile of parked work nobody can see on the
      // fleet page is the opposite of the bug this fixed.
      cell: (r) => {
        const f = r.fleet || {};
        const q = f.queue_depth;
        const parked = [];
        if (f.held) parked.push(`${f.held} held`);
        if (f.failed) parked.push(`${f.failed} failed`);
        const tail = parked.length ? html`<span class="na"> · ${parked.join(' · ')}</span>` : null;
        const n = countOrNull(q);
        if (n === 'no data' || n === '0') return html`<span class="na">${n}</span>${tail}`;
        return html`<span class="num">${n}</span>${tail}`;
      }
    },
    {
      key: 'oldest', label: 'OLDEST', unit: 'in queue', sort: (r) => (r.fleet && r.fleet.oldest_queued_min) || null, align: 'right',
      cell: (r) => html`<${Age} min=${r.fleet && r.fleet.oldest_queued_min} warnAt=${45}/>`
    },
    {
      key: 'flags', label: 'FLAGS', sort: (r) => flagsRank(r, pauses),
      // PAUSED is the box's flag file; PAUSED(<what>) is a worker pause row
      // (BH-1672), one tag per row covering this project, fleet rows included.
      // Every tag's title says why, who and when (BH-2509). The flag file's
      // own why/who is its triage row for this project, or, with none live,
      // the line that says none is on record.
      cell: (r) => {
        const live = pausesForProject(pauses, r.project);
        const flagTitle = r.paused
          ? boardPauseLines(pauses, r.project, true)
            .filter((l) => l.what === null || (l.what === 'triage' && l.scope === r.project))
            .map((l) => l.text).join('\n')
          : '';
        return html`
        <span style="display:inline-flex;gap:5px;flex-wrap:wrap">
          ${r.paused ? html`<span class="tag tag--warn" title=${flagTitle} aria-label=${`PAUSED: ${flagTitle}`}>PAUSED</span>` : null}
          ${live.map((pr) => html`<span key=${pr.id} class="tag tag--bad"
            title=${pauseDetail(pr)}>PAUSED(${pr.what})</span>`)}
          ${r.automerge ? null : html`<span class="tag">NO AUTOMERGE</span>`}
          ${!r.paused && r.automerge && !live.length ? html`<span class="na">—</span>` : null}
        </span>`;
      }
    },
    {
      key: 'paused', label: 'PAUSED', sort: (r) => flagSortValue('paused', cellFor(r)),
      cell: (r) => {
        const c = cellFor(r);
        const text = cellText('paused', c.paused);
        return html`
        <span style="display:inline-flex;gap:6px;align-items:center;white-space:nowrap">
          <span class=${c.paused === true ? 'tag tag--warn' : 'na'}
            title=${c.paused === null ? 'flag state not readable' : `paused-${r.project}`}>${text}</span>
          ${onPause && c.paused !== null ? html`<button type="button" class="btn btn--sm"
            disabled=${busy !== null} onClick=${() => onPause(r.project, c)}>${c.paused ? 'RESUME' : 'PAUSE'}</button>` : null}
        </span>`;
      }
    },
    {
      key: 'wip', label: 'WIP', sort: (r) => flagSortValue('wip', cellFor(r)), align: 'right',
      cell: (r) => html`<${WipCell} project=${r.project} wip=${cellFor(r).wip} onSave=${onSaveWip} busy=${busy}/>`
    },
    {
      key: 'route', label: 'ROUTE', sort: (r) => flagSortValue('route', cellFor(r)),
      cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`}
        title=${`open the ROUTING panel for ${r.project}`}>${cellText('route', cellFor(r).route)}<//>`
    },
    {
      key: 'open_alerts', label: 'ALERTS', sort: (r) => r.open_alerts || 0, align: 'right',
      cell: (r) => r.open_alerts
        ? html`<${Link} to=${`/alerts?project=${encodeURIComponent(r.project)}`} class="num--warn">${r.open_alerts}<//>`
        : html`<span class="na">0</span>`
    },
    {
      key: 'open_prs', label: 'PRS', sort: (r) => r.open_prs || 0, align: 'right',
      cell: (r) => r.open_prs
        ? html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`}>${r.open_prs}<//>`
        : html`<span class="na">0</span>`
    }
  ];

  return html`<${SortableTable}
    columns=${columns}
    rows=${rows}
    rowKey=${(r) => r.project}
    rowClass=${(r) => {
      const h = healthFromAge(r.last_run_age_min);
      return h === 'dead' ? 'row--dead' : h === 'warn' ? 'row--warn' : '';
    }}
    defaultSort="last_summary"
    defaultDir="asc"
    empty=${html`<${Empty} title="no projects yet"
      note="The fleet list comes from the hub's last fleet_status beat. Until the hub pushes one, this reads from a four-name fallback constant." />`} />`;
}

// The WIP cell (BH-5643): the wip-limit-<p> value as read, and a number input
// with SAVE. The typed text is this cell's own state and is never shown as
// the limit: the number beside it is the re-read row, nothing else.
function WipCell({ project, wip, onSave, busy }) {
  const [text, setText] = useState('');
  const shown = cellText('wip', wip);
  return html`
    <span style="display:inline-flex;gap:6px;align-items:center;justify-content:flex-end">
      <span class=${typeof wip === 'number' ? 'num' : 'na'}
        title=${wip === null ? 'not readable, or the value is not a whole number' : `wip-limit-${project}`}>${shown}</span>
      ${onSave ? html`<form style="display:inline-flex;gap:4px;white-space:nowrap"
        onSubmit=${(e) => { e.preventDefault(); onSave(project, text); }}>
        <input class="knob__input" type="number" min="1" max="9999" step="1" inputmode="numeric"
          style="width:4.5em" aria-label=${`wip limit for ${project}`} value=${text}
          onInput=${(e) => setText(e.target.value)}/>
        <button type="submit" class="btn btn--sm" disabled=${busy !== null}>SAVE</button>
      </form>` : null}
    </span>`;
}

// The FLAGS column's sort value: an active pause row outranks the flag file,
// which outranks automerge off. Exported so the test reads the same accessor
// the table sorts on.
export function flagsRank(r, pauses = []) {
  return (pausesForProject(pauses, r.project).length ? 4 : 0) + (r.paused ? 2 : 0) + (r.automerge ? 0 : 1);
}

// Live pauses above the PROJECTS table (BH-1672). Nothing at all when there
// are none, which is also what a failed read looks like: the ticket asks for
// quiet there, and the FLAGS column still shows the box's flag-file PAUSED.
export function PauseBanner({ rows, truncated, onEnd, busyId = null }) {
  if (!rows || !rows.length) return null;
  const columns = [
    {
      key: 'scope', label: 'SCOPE', sort: (r) => r.scopeLabel,
      cell: (r) => r.scope === 'fleet'
        ? html`<span class="cell-name">${r.scopeLabel}</span>`
        : html`<${Link} to=${`/p/${encodeURIComponent(r.scope)}`} class="cell-name">${r.scope}<//>`
    },
    {
      key: 'what', label: 'WHAT', sort: (r) => r.what,
      cell: (r) => html`<span class="tag tag--bad">PAUSED(${r.what})</span>`
    },
    {
      key: 'reason', label: 'REASON', sort: (r) => r.reasonText,
      cell: (r) => html`<span class="cell-wrap">${r.reasonText}</span>`
    },
    {
      key: 'actor', label: 'ACTOR', sort: (r) => r.actor || null,
      cell: (r) => r.actor ? html`<span>${pauseActorText(r.actor)}</span>` : html`<span class="na">—</span>`
    },
    {
      key: 'ageMin', label: 'AGE', sort: (r) => r.ageMin, align: 'right',
      cell: (r) => html`<span title=${r.created_at || ''}><${Age} min=${r.ageMin} warnAt=${1440}/></span>`
    },
    {
      key: 'expiresInMin', label: 'EXPIRES', sort: (r) => r.expiresInMin, align: 'right',
      cell: (r) => html`<span>in ${agoFromMinutes(r.expiresInMin)}</span>`
    },
    {
      key: 'end', label: '', sort: null,
      cell: (r) => html`<button class="btn btn--sm btn--warn" type="button"
        disabled=${busyId !== null} onClick=${() => onEnd(r)}>
        ${busyId === r.id ? 'ENDING…' : 'END'}
      </button>`
    }
  ];
  return html`
    <${Section} title="PAUSES"
      note=${`${rows.length} live${truncated ? ' · first 500 shown' : ''}`}>
      <${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.id}
        defaultSort="expiresInMin" defaultDir="asc" />
    <//>`;
}
