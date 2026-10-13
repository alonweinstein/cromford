// The flat map, kept.
//
// This is the hex scene that shipped in #147, moved out of screens/World.js
// unchanged when the 3D planet became the default. It is not dead code and it
// is not a legacy path: it is what /world renders when the browser has no
// WebGL, when the three.js chunk fails to load, or when someone asks for it —
// a console that answers "your browser cannot draw this" is a console that
// stops being usable exactly when someone is checking the fleet from a locked
// down machine.
//
// Pan and zoom are done on the viewBox rather than with a CSS transform, so the
// stroke widths and label sizes stay honest at every zoom and the SVG itself
// never overflows the page — the container clips, the body never scrolls
// sideways.

import { useState, useEffect, useRef, useCallback, useMemo } from 'preact/hooks';
import { html } from '../router.js';
import { initialViewBox, clampZoom, sceneBounds } from '../lib/world.js';
import { ensureVisible } from '../lib/worldnav.js';
import { AgentSprite, ProjectHex } from '../ui/sprites.js';
import { PickCard } from '../ui/WorldPick.js';

// Movement, in client pixels, past which a gesture is a pan and not a tap.
const DRAG_SLOP = 10;

export function HexScene({ scene, wrapRef: outerRef, selection, hint }) {
  const localRef = useRef(null);
  const wrapRef = outerRef || localRef;
  const svgRef = useRef(null);
  const [box, setBox] = useState(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const pointers = useRef(new Map());
  const drag = useRef({ moved: 0, last: null, pinch: null, captured: null });
  const [suppressClick, setSuppressClick] = useState(false);
  const layoutKey = scene.hexes.map((h) => h.project).join(',') + `|${scene.station.length}`;
  const lastLayout = useRef(null);

  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return undefined;
    const measure = () => setSize({ width: el.clientWidth, height: el.clientHeight });
    measure();
    if (typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', measure);
      return () => window.removeEventListener('resize', measure);
    }
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // The camera is placed once per LAYOUT, not once per poll: a refresh that
  // adds a sprite must not yank the view out from under a thumb mid-pan.
  const base = useMemo(
    () => initialViewBox(scene, { width: size.width || 1024, height: size.height || 560 }),
    [layoutKey, size.width, size.height]
  );
  useEffect(() => {
    if (!size.width) return;
    if (lastLayout.current === layoutKey) return;
    lastLayout.current = layoutKey;
    setBox(base);
  }, [layoutKey, base, size.width]);

  // The arrow keys can walk the selection off the edge of a phone's viewport,
  // which starts zoomed IN on the busiest tile. The camera follows by the
  // smallest amount that puts the body back on screen — a jump to centre on
  // every press would make the whole map lurch under a reader's eyes.
  const selId = selection ? selection.id : null;
  useEffect(() => {
    if (!selection || typeof selection.x !== 'number') return;
    setBox((prev) => ensureVisible(prev || base, { x: selection.x, y: selection.y }));
  }, [selId]);

  const view = box || base;
  const toScene = (px) => (view.w / Math.max(1, size.width)) * px;

  const zoomBy = useCallback((factor, cx, cy) => {
    setBox((prev) => {
      const v = prev || base;
      const w = clampZoom(v.w * factor, base.w);
      const h = w * (v.h / v.w);
      const ax = cx === undefined ? 0.5 : cx;
      const ay = cy === undefined ? 0.5 : cy;
      return { x: v.x + (v.w - w) * ax, y: v.y + (v.h - h) * ay, w, h };
    });
  }, [base]);

  const onPointerDown = (e) => {
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    drag.current.moved = 0;
    drag.current.last = { x: e.clientX, y: e.clientY };
    if (pointers.current.size === 2) {
      const [a, b] = [...pointers.current.values()];
      drag.current.pinch = Math.hypot(a.x - b.x, a.y - b.y) || 1;
    }
    // NO pointer capture here, deliberately. Capturing on pointerdown makes the
    // browser retarget the following `click` to the capture element, so every
    // tap on a sprite would be swallowed by the <svg> and no link would ever
    // open. Capture is taken lazily below, once a gesture is clearly a drag.
  };

  const capture = (pointerId) => {
    if (drag.current.captured) return;
    const el = svgRef.current;
    if (!el || !el.setPointerCapture) return;
    try { el.setPointerCapture(pointerId); drag.current.captured = pointerId; } catch { /* not captureable */ }
  };

  const onPointerMove = (e) => {
    if (!pointers.current.has(e.pointerId)) return;
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });

    if (pointers.current.size >= 2) {
      const [a, b] = [...pointers.current.values()];
      const dist = Math.hypot(a.x - b.x, a.y - b.y) || 1;
      const prev = drag.current.pinch || dist;
      drag.current.pinch = dist;
      drag.current.moved += Math.abs(dist - prev);
      const rect = svgRef.current ? svgRef.current.getBoundingClientRect() : null;
      const mx = rect ? ((a.x + b.x) / 2 - rect.left) / Math.max(1, rect.width) : 0.5;
      const my = rect ? ((a.y + b.y) / 2 - rect.top) / Math.max(1, rect.height) : 0.5;
      capture(e.pointerId);
      zoomBy(prev / dist, mx, my);
      return;
    }

    const last = drag.current.last;
    if (!last) return;
    const dx = e.clientX - last.x;
    const dy = e.clientY - last.y;
    drag.current.last = { x: e.clientX, y: e.clientY };
    drag.current.moved += Math.abs(dx) + Math.abs(dy);
    // Past the threshold this is a pan, not a tap: hold the pointer so the
    // gesture survives the finger leaving the scene.
    if (drag.current.moved > DRAG_SLOP) capture(e.pointerId);
    setBox((prev) => {
      const v = prev || base;
      return { ...v, x: v.x - toScene(dx), y: v.y - toScene(dy) };
    });
  };

  const onPointerUp = (e) => {
    pointers.current.delete(e.pointerId);
    if (drag.current.captured === e.pointerId) {
      const el = svgRef.current;
      if (el && el.releasePointerCapture) {
        try { el.releasePointerCapture(e.pointerId); } catch { /* already gone */ }
      }
      drag.current.captured = null;
    }
    if (pointers.current.size < 2) drag.current.pinch = null;
    if (!pointers.current.size) drag.current.last = null;
    // A pan that ended on top of a sprite must not also open it. Anything past
    // a few pixels was a drag, and the click it produces is swallowed once.
    setSuppressClick(drag.current.moved > DRAG_SLOP);
  };

  const onClickCapture = (e) => {
    if (!suppressClick) return;
    e.preventDefault();
    e.stopPropagation();
    setSuppressClick(false);
  };

  const onWheel = (e) => {
    e.preventDefault();
    const rect = svgRef.current ? svgRef.current.getBoundingClientRect() : null;
    const mx = rect ? (e.clientX - rect.left) / Math.max(1, rect.width) : 0.5;
    const my = rect ? (e.clientY - rect.top) / Math.max(1, rect.height) : 0.5;
    zoomBy(e.deltaY > 0 ? 1.12 : 1 / 1.12, mx, my);
  };

  const bounds = sceneBounds(scene);

  return html`
    <div class="worldwrap" ref=${wrapRef}
      tabindex="0" role="group" aria-label=${`fleet world, flat map — ${hint || 'arrow keys move between projects and bodies, Enter opens, Escape clears'}`}
      aria-keyshortcuts="ArrowUp ArrowDown ArrowLeft ArrowRight Enter Escape">
      <svg class="world" ref=${svgRef}
        viewBox=${`${view.x.toFixed(1)} ${view.y.toFixed(1)} ${view.w.toFixed(1)} ${view.h.toFixed(1)}`}
        role="img" aria-label="fleet world map"
        onPointerDown=${onPointerDown} onPointerMove=${onPointerMove}
        onPointerUp=${onPointerUp} onPointerCancel=${onPointerUp}
        onClickCapture=${onClickCapture} onWheel=${onWheel}>
        <defs>
          <radialGradient id="world-glow" cx="50%" cy="45%" r="60%">
            <stop offset="0%" style="stop-color:var(--hex-sky-top)"/>
            <stop offset="100%" style="stop-color:var(--bg)"/>
          </radialGradient>
        </defs>
        <rect x=${bounds.x - bounds.w} y=${bounds.y - bounds.h} width=${bounds.w * 3} height=${bounds.h * 3}
          fill="url(#world-glow)"/>
        <${Stars} bounds=${bounds}/>
        ${scene.hexes.map((h) => html`<${ProjectHex} key=${h.project} hex=${h}
          selected=${selId === `t:${h.project}`}/>`)}
        ${scene.station.length ? html`
          <g class="wstation">
            <line x1=${(scene.station[0].x - 50).toFixed(1)} y1=${(scene.station[0].y - 34).toFixed(1)}
              x2=${(scene.station[scene.station.length - 1].x + 50).toFixed(1)} y2=${(scene.station[0].y - 34).toFixed(1)}
              style="stroke:var(--line-active)" stroke-width="1.5"/>
            <text x="0" y=${(scene.station[0].y - 40).toFixed(1)} text-anchor="middle" class="whex__meta">STATION — IDLE BOXES</text>
          </g>` : null}
        ${scene.sprites.filter((s) => !s.homeless).map((s) => html`
          <${AgentSprite} key=${s.id} sprite=${s} selected=${selId === s.id}/>`)}
        ${scene.station.map((s) => html`
          <${AgentSprite} key=${s.id} sprite=${s} selected=${selId === s.id}/>`)}
      </svg>
      <div class="worldctl">
        <button type="button" class="btn btn--sm" aria-label="zoom in" onClick=${() => zoomBy(1 / 1.3)}>+</button>
        <button type="button" class="btn btn--sm" aria-label="zoom out" onClick=${() => zoomBy(1.3)}>−</button>
        <button type="button" class="btn btn--sm" onClick=${() => setBox(base)}>RESET</button>
      </div>
      <span class="worldhint">drag to pan · pinch to zoom · ←↑↓→ to walk · ↵ to open</span>
      <${PickCard} pick=${selection} keyed=${Boolean(selection && selection.viaKey)}/>
    </div>`;
}

// A fixed, deterministic starfield: seeded from the index so it does not
// re-scatter on every render and cost a repaint the scene does not need.
function Stars({ bounds }) {
  const stars = useMemo(() => {
    const out = [];
    for (let i = 0; i < 60; i++) {
      const a = Math.sin(i * 12.9898) * 43758.5453;
      const b = Math.sin(i * 78.233) * 12345.6789;
      out.push({
        x: bounds.x + (a - Math.floor(a)) * bounds.w,
        y: bounds.y + (b - Math.floor(b)) * bounds.h,
        r: 0.6 + ((i % 4) * 0.35)
      });
    }
    return out;
  }, [bounds.x, bounds.y, bounds.w, bounds.h]);
  return html`<g opacity="0.5">
    ${stars.map((s, i) => html`<circle key=${i} cx=${s.x.toFixed(1)} cy=${s.y.toFixed(1)} r=${s.r} style="fill:var(--line-active)"/>`)}
  </g>`;
}
