// WORLD — the fleet as a place rather than as a table.
//
// Every other tab answers a question with rows. This one answers the question
// people actually walk up to a wall display with: is anything happening, and is
// anyone stuck. A territory on the planet is a project, a little body is a LIVE
// claim in the jobs ledger, a beacon is a row that needs a human, and a body
// asleep on the orbital station is a box with nothing to do.
//
// It is read-only and it invents nothing. Four existing D1-backed reads —
// /api/coord/jobs, /api/cockpit/needs, /api/dash/machines, /api/dash/projects —
// are the same payloads JOBS, NEEDS, MACHINES and FLEET already render; the
// scene is a second VIEW of them, never a second source of truth. What the
// scene MEANS is decided in lib/world.js (tested in tests/world.test.js) and
// where everything STANDS in lib/world3d.js (tested in tests/world3d.test.js).
//
// Three renderers' worth of code is not three renderers' worth of download:
// three.js is behind a dynamic import that only this route ever reaches, and
// only after hasWebGL() says the browser can use it. A browser that cannot —
// or a chunk that fails to load — gets the flat hex map from #147, which is
// still here in screens/WorldHex.js and still fully navigable.
//
// Nothing here is a dead pixel: every territory links to /p/<project>, every
// body to the job or machine screen that already owns it, and both lists below
// the scene carry the same links for a keyboard or a screen reader.

import { useState, useEffect, useRef, useMemo, useCallback } from 'preact/hooks';
import { html, Link, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useDocumentVisible } from '../lib/hooks.js';
import { usePolledApi } from '../lib/poll.js';
import { buildScene, SPRITE_LABEL } from '../lib/world.js';
import { hasWebGL } from '../lib/webgl.js';
import { HexScene } from './WorldHex.js';
import { toneColor } from '../ui/sprites.js';
import { PickCard, pickDetail } from '../ui/WorldPick.js';
import { hexTargets, moveSelection, worldKeyAction } from '../lib/worldnav.js';
import { Section, Stat, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';

// The ledger moves in minutes, not seconds, and this screen is the one people
// leave open — 20s is polite for the live view and 60s is plenty for the three
// slower payloads. usePolledApi backs off on failure and stops while the tab is
// hidden, so a forgotten phone costs nothing.
const LIVE_MS = 20000;
const SLOW_MS = 60000;

const prefersReducedMotion = () =>
  typeof window !== 'undefined' && typeof window.matchMedia === 'function' &&
  window.matchMedia('(prefers-reduced-motion: reduce)').matches;

// What the arrow keys are standing on, and what happens when one is pressed.
//
// One listener, on the window, for exactly as long as /world is mounted. It is
// on the window rather than on the scene box so the keys work the moment the
// page loads — you should not have to click a planet before you can drive it —
// and every decision about whether a given keystroke is OURS is made by the
// pure guard in lib/worldnav.js: a key typed into an input, pressed inside a
// modal, or pressed while the focus is on something outside the scene is left
// entirely alone, which is what keeps arrow-scrolling working everywhere else.
function useWorldKeys({ wrapRef, getTargets, selection, setSelection }) {
  const selRef = useRef(selection);
  selRef.current = selection;

  useEffect(() => {
    const onKey = (e) => {
      const act = worldKeyAction(e, {
        container: wrapRef.current,
        active: typeof document !== 'undefined' ? document.activeElement : null,
        hasSelection: Boolean(selRef.current)
      });
      if (!act) return;

      if (act.action === 'clear') {
        e.preventDefault();
        setSelection(null);
        return;
      }
      if (act.action === 'open') {
        const cur = selRef.current;
        e.preventDefault();
        if (cur && cur.to) navigate(cur.to);
        return;
      }

      const { entities, center } = getTargets();
      // Nothing drawn yet (the planet is still booting, or the fleet is empty):
      // the page keeps its own arrow keys rather than swallowing them for a
      // scene that has nothing to select.
      if (!entities.length) return;
      e.preventDefault();
      const cur = selRef.current;
      const next = moveSelection(entities, cur ? cur.id : null, act.dir, center);
      // Tagged as the keyboard's, so the card can offer ENTER rather than the
      // OPEN a thumb was already going to do.
      if (next && (!cur || next.id !== cur.id)) setSelection({ ...next, viaKey: true });
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [wrapRef, getTargets, setSelection]);
}

// The keyboard's own line of prose, for a reader who cannot see the ring.
const SELECTION_HINT = 'arrow keys or W A S D move between projects and bodies, Enter opens, Escape clears';

export function WorldScreen() {
  const visible = useDocumentVisible();
  const jobs = usePolledApi(() => api.jobs({ limit: 200 }), [], { intervalMs: LIVE_MS, enabled: visible });
  const needs = usePolledApi(() => api.cockpitNeeds(), [], { intervalMs: SLOW_MS, enabled: visible });
  const machines = usePolledApi(() => api.machines(), [], { intervalMs: SLOW_MS, enabled: visible });
  const projects = usePolledApi(() => api.projects(), [], { intervalMs: SLOW_MS, enabled: visible });

  const scene = useMemo(() => buildScene({
    jobs: jobs.data, needs: needs.data, machines: machines.data, projects: projects.data
  }), [jobs.data, needs.data, machines.data, projects.data]);

  // The probe runs once, before anything is imported: a browser without WebGL
  // must not pay for a 3D engine it cannot use.
  const [flat, setFlat] = useState(() => (hasWebGL() ? null : 'this browser has no WebGL'));

  const loadingFirst = !jobs.data && !projects.data && (jobs.loading || projects.loading);
  // Each pane names the read it is missing rather than rendering a confident
  // empty planet built out of half the inputs.
  const missing = [
    jobs.error && !jobs.data ? 'jobs' : null,
    needs.error && !needs.data ? 'needs' : null,
    machines.error && !machines.data ? 'machines' : null,
    projects.error && !projects.data ? 'projects' : null
  ].filter(Boolean);

  const raised = [...scene.sprites, ...scene.station].filter((s) => s.raised);

  // The selection is the screen's, not a renderer's: a tap on the planet and an
  // arrow key land in the same place, and switching renderers cannot lose it.
  const [selection, setSelection] = useState(null);
  const wrapRef = useRef(null);
  const sceneRef = useRef(scene);
  sceneRef.current = scene;

  // Where everything is, asked of whichever renderer is actually mounted. The
  // planet answers in projected screen space because it spins; the flat map
  // answers in scene units, which is the same question with a still camera.
  const planetTargets = useRef(null);
  const registerTargets = useCallback((fn) => { planetTargets.current = fn; }, []);
  const getTargets = useCallback(
    () => (planetTargets.current ? planetTargets.current() : hexTargets(sceneRef.current)),
    []
  );
  useWorldKeys({ wrapRef, getTargets, selection, setSelection });

  // A claim that finished is off the map, so it stops being selected. Holding a
  // ring around a body that is no longer there would be the scene lying.
  useEffect(() => {
    if (!selection) return;
    const live = new Set([
      ...scene.hexes.map((h) => `t:${h.project}`),
      ...scene.sprites.filter((s) => !s.homeless).map((s) => s.id),
      ...scene.station.map((s) => s.id)
    ]);
    if (!live.has(selection.id)) setSelection(null);
  }, [scene, selection]);

  return html`
    <div class="page">
      <${PageHeadline} chip="World" line1="The fleet as a place."
        line2="One territory per project, one body per live claim."/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span style="font-size:11px;color:var(--faint)">
          the fleet as a place — one territory per project, one body per live claim
        </span>
      </div>

      ${/* The selection, spoken. aria-live rather than a focus move: the bodies
           are pixels in a canvas, so there is no element to focus — this is how
           a screen reader hears the arrow keys working. */ null}
      <p class="worldsr" role="status" aria-live="polite">
        ${selection ? `${selection.label} — ${pickDetail(selection)}, selected. ${SELECTION_HINT}` : ''}
      </p>

      <div class="stats stats--4">
        <${Stat} label="WORKING" value=${jobs.data ? scene.counts.working : '…'} tone="green" to="/jobs"/>
        <${Stat} label="HANDS UP" value=${jobs.data ? scene.counts.raised : '…'}
          tone=${scene.counts.raised ? 'warn' : null} to="/needs"/>
        <${Stat} label="ASLEEP" value=${machines.data ? scene.counts.asleep : '…'} to="/machines"/>
        <${Stat} label="WAITING ON A PERSON" value=${needs.data ? scene.counts.needs : '…'}
          tone=${scene.counts.needs ? 'warn' : null} to="/needs"/>
      </div>

      ${missing.length ? html`
        <div class="banner banner--warn">
          <span>the scene is missing <b>${missing.join(', ')}</b> — what is drawn below is the rest,
            not the whole fleet.</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${() => {
            if (jobs.error) jobs.reload();
            if (needs.error) needs.reload();
            if (machines.error) machines.reload();
            if (projects.error) projects.reload();
          }}>RETRY</button>
        </div>` : null}

      ${loadingFirst
        ? html`<${Skeleton} rows=${4} height=${40}/>`
        : missing.includes('jobs') && missing.includes('projects')
          ? html`<${ErrorBox} error=${jobs.error || projects.error} onRetry=${jobs.reload}/>`
          : scene.hexes.length
            ? (flat
                ? html`<${HexScene} scene=${scene} wrapRef=${wrapRef}
                    selection=${selection} hint=${SELECTION_HINT}/>`
                : html`<${Planet} scene=${scene} visible=${visible} onFallback=${setFlat}
                    wrapRef=${wrapRef} selection=${selection} onSelect=${setSelection}
                    registerTargets=${registerTargets}/>`)
            : html`<${Empty} title="no projects on the board yet"
                note="the hub's project snapshot is empty and no claim in the jobs ledger names a project, so there is nothing to put on the map."/>`}

      ${flat && scene.hexes.length ? html`
        <p class="worldnote">2D mode — ${flat}. Everything on the flat map links to the same
          places the planet does; nothing about the fleet is hidden here.</p>` : null}

      <${Legend}/>

      <${Section} title="HANDS UP"
        note="every raised hand on the map, as a list — the same links, for a keyboard or a screen reader">
        ${raised.length ? html`
          <ul class="wlist">
            ${raised.map((s) => html`
              <li key=${s.id}>
                <${Link} to=${s.to} class="wlist__row">
                  <span class="wdot" style=${`background:${toneColor(s.tone)}`}></span>
                  <span class="wlist__name">${s.label}</span>
                  <span class="wlist__state">${SPRITE_LABEL[s.state] || s.state}</span>
                <//>
              </li>`)}
          </ul>`
          : html`<${Empty} title="nobody has a hand up"
              note=${jobs.data && machines.data
                ? 'no claim is parked, out of budget or past its heartbeat, and every box is answering.'
                : 'said only about the reads that landed — see the banner above for the ones that did not.'}/>`}
      <//>

      <${Section} title="TERRITORIES"
        note="every project on the planet, biggest first — the same tap targets, without the globe">
        ${scene.hexes.length ? html`
          <ul class="wlist">
            ${scene.hexes.map((h) => html`
              <li key=${h.project}>
                <${Link} to=${h.to} class="wlist__row">
                  <span class="wdot" style=${`background:${toneColor(h.raised || h.needs_high ? 'dead' : h.paused ? 'warn' : h.live ? 'ok' : 'idle')}`}></span>
                  <span class="wlist__name">${h.project}</span>
                  <span class="wlist__state">
                    ${h.live ? `${h.live} live` : 'idle'}${h.needs ? ` · ${h.needs} need` : ''}${h.paused ? ' · paused' : ''}
                  </span>
                <//>
              </li>`)}
          </ul>` : null}
      <//>
    </div>`;
}

// ---------------------------------------------------------------- the planet

// The 3D scene's container. Everything three.js touches lives behind the
// dynamic import below and inside the controller it returns; this component
// owns the DOM box, the overlay, and the decision to give up and go flat.
function Planet({ scene, visible, onFallback, wrapRef, selection, onSelect, registerTargets }) {
  const ctrlRef = useRef(null);
  const [ready, setReady] = useState(false);

  // The controller keeps the scene it was last handed and rebuilds its meshes
  // only when the world's SHAPE changed — see setScene() in world3d/planet.js.
  const sceneRef = useRef(scene);
  sceneRef.current = scene;

  const onOpen = useCallback((target) => {
    if (target && target.to) navigate(target.to);
  }, []);

  useEffect(() => {
    let dead = false;
    let ctrl = null;
    import('../world3d/planet.js')
      .then(({ createPlanet }) => {
        if (dead || !wrapRef.current) return;
        ctrl = createPlanet(wrapRef.current, {
          reducedMotion: prefersReducedMotion(),
          onPress: onSelect,
          onOpen,
          onLost: () => onFallback('the browser dropped the 3D context')
        });
        ctrlRef.current = ctrl;
        ctrl.setScene(sceneRef.current);
        setReady(true);
      })
      .catch(() => {
        if (!dead) onFallback('the 3D scene could not be loaded');
      });
    return () => {
      dead = true;
      ctrlRef.current = null;
      if (ctrl) ctrl.dispose();
    };
  }, [onOpen, onFallback, onSelect, wrapRef]);

  // The arrow keys ask the CONTROLLER where everything is, because on a globe
  // that is turning the answer is only true for this frame. Registered on
  // mount and taken back on unmount, so a fallback to the flat map cannot
  // leave the keyboard talking to a disposed renderer.
  useEffect(() => {
    registerTargets(() => (ctrlRef.current
      ? ctrlRef.current.navTargets()
      : { entities: [], center: { x: 0, y: 0 } }));
    return () => registerTargets(null);
  }, [registerTargets]);

  useEffect(() => {
    if (ctrlRef.current) ctrlRef.current.setSelected(selection ? selection.id : null);
  }, [selection, ready]);

  useEffect(() => {
    if (ctrlRef.current) ctrlRef.current.setScene(scene);
  }, [scene]);

  useEffect(() => {
    const el = wrapRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return undefined;
    const ro = new ResizeObserver(() => { if (ctrlRef.current) ctrlRef.current.resize(); });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // A hidden tab renders nothing: the frame loop stops with the polling.
  useEffect(() => {
    if (ctrlRef.current) ctrlRef.current.setActive(visible);
  }, [visible, ready]);

  const call = (fn) => () => { if (ctrlRef.current) ctrlRef.current[fn](); };

  return html`
    <div class="worldwrap worldwrap--3d" ref=${wrapRef}
      tabindex="0" role="application"
      aria-label=${`fleet world, 3D planet — ${SELECTION_HINT}`}
      aria-keyshortcuts="ArrowUp ArrowDown ArrowLeft ArrowRight Enter Escape">
      ${!ready ? html`<div class="worldboot">building the planet…</div>` : null}
      <div class="worldctl">
        <button type="button" class="btn btn--sm" aria-label="zoom in" onClick=${call('zoomIn')}>+</button>
        <button type="button" class="btn btn--sm" aria-label="zoom out" onClick=${call('zoomOut')}>−</button>
        <button type="button" class="btn btn--sm" onClick=${call('reset')}>RESET</button>
      </div>
      <span class="worldhint">drag to orbit · pinch to zoom · ←↑↓→ to walk · ↵ to open</span>
      <${PickCard} pick=${selection} keyed=${Boolean(selection && selection.viaKey)}/>
    </div>`;
}

const LEGEND = [
  ['working', 'a claim that is beating and fresh'],
  ['waiting', 'queued for a retry the lane will take — nobody is blocked'],
  ['quiet', 'never beat and has gone silent: a lower bound, not a death'],
  ['blocked', 'parked or out of budget — a person has to decide'],
  ['stuck', 'beats stopped, or the watchdog already released the claim'],
  ['asleep', 'a box answering the watchdog with nothing claimed'],
  ['offline', 'a box that is not answering at all']
];

function Legend() {
  return html`
    <${Section} title="WHAT THE BODIES MEAN"
      note="a body with a beacon over it is a state a PERSON has to answer">
      <ul class="wlegend">
        ${LEGEND.map(([state, note]) => html`
          <li key=${state}>
            <span class="wlegend__key">
              <span class="wdot" style=${`background:${toneColor({ working: 'ok', waiting: 'warn', quiet: 'warn', blocked: 'warn', stuck: 'dead', asleep: 'idle', offline: 'dead' }[state])}`}></span>
              ${SPRITE_LABEL[state] || state}
            </span>
            <span class="wlegend__note">${note}</span>
          </li>`)}
      </ul>
    <//>`;
}
