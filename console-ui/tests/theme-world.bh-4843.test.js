// BH-4843: /world's three.js renderer takes its colours from the :root tokens,
// reads them when the planet is created, and reads them again when the theme
// changes (THEME_CHANGE_EVENT). Driven through the real createPlanet() with the
// real three.js; only the GPU renderer and the 2D canvas are headless stand-ins.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { register } from 'node:module';

const stub = new URL('./helpers/three-headless.bh-4843.js', import.meta.url).href;
register('data:text/javascript,' + encodeURIComponent(`
  export async function resolve(spec, ctx, next) {
    if (spec === 'three' && ctx.parentURL !== ${JSON.stringify(stub)}) return { url: ${JSON.stringify(stub)}, shortCircuit: true };
    return next(spec, ctx);
  }`));

// ------------------------------------------------------------- headless DOM

// Every colour any 2D canvas was painted with, in order.
const painted = [];
function fakeCanvas() {
  const ctx = new Proxy({}, {
    get: (t, k) => (k in t ? t[k] : () => ({ addColorStop() {} })),
    set: (t, k, v) => {
      if (k === 'fillStyle' || k === 'strokeStyle') painted.push(String(v).toUpperCase());
      t[k] = v;
      return true;
    }
  });
  return {
    width: 0, height: 0, style: {},
    getContext: () => ctx,
    setAttribute() {}, addEventListener() {}, removeEventListener() {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 400, height: 400 })
  };
}

// The token values the "stylesheet" currently answers with.
let tokens = {};
const listeners = { added: 0, removed: 0 };
const win = new EventTarget();
const add = win.addEventListener.bind(win);
const remove = win.removeEventListener.bind(win);
win.addEventListener = (...a) => { if (a[0] === 'mc:themechange') listeners.added += 1; return add(...a); };
win.removeEventListener = (...a) => { if (a[0] === 'mc:themechange') listeners.removed += 1; return remove(...a); };
win.devicePixelRatio = 1;
globalThis.window = win;
globalThis.document = { documentElement: {}, createElement: () => fakeCanvas() };
globalThis.getComputedStyle = () => ({ getPropertyValue: (n) => (n in tokens ? ` ${tokens[n]}` : '') });
globalThis.requestAnimationFrame = () => 1;
globalThis.cancelAnimationFrame = () => {};

const { createPlanet } = await import('../src/world3d/planet.js');
const { buildScene } = await import('../src/lib/world.js');
const { THEME_CHANGE_EVENT } = await import('../src/theme/tokens.js');

const job = (over = {}) => ({
  id: 'build-project-3-TK-1-1', project: 'project-3', kind: 'build', box: 'project-3-1',
  stage: 'execute', status: 'running', heartbeating: true, activity_age_s: 60, ...over
});
const SCENE = buildScene({
  jobs: { jobs: [job(), job({ id: 'build-project-4-TK-3-1', project: 'project-4', box: 'project-4-1' })] },
  projects: { projects: [
    { project: 'project-3', open_prs: 1, open_alerts: 0, fleet: { queue_depth: 1 } },
    { project: 'project-4', open_prs: 0, open_alerts: 0, fleet: { queue_depth: 0 } }
  ] },
  machines: { boxes: { 'project-3-1': '1m ago', 'project-4-1': '1m ago', 'hub-1': '2m ago', 'spare-1': '3m ago' } },
  needs: { alerts: [], commands: [], builds: [], ideas: [] }
});

function lights(scene) {
  const out = { hemi: null, dir: [] };
  scene.traverse((o) => {
    if (o.isHemisphereLight) out.hemi = o;
    else if (o.isDirectionalLight) out.dir.push(o);
  });
  return out;
}
function basicColors(scene) {
  const seen = new Set();
  scene.traverse((o) => {
    if (o.isMesh && o.material && o.material.type === 'MeshBasicMaterial' && !o.material.map) seen.add(o.material.color.getHexString());
  });
  return seen;
}
const container = () => ({ clientWidth: 400, clientHeight: 400, appendChild() {}, removeChild() {} });

test('/world draws in the Phosphor values when the stylesheet answers nothing', () => {
  tokens = {};
  painted.length = 0;
  const planet = createPlanet(container());
  planet.setScene(SCENE);
  const scene = globalThis.__headless.scene;
  const { hemi, dir } = lights(scene);
  assert.equal(hemi.color.getHexString(), '9fd8b0');
  assert.equal(hemi.groundColor.getHexString(), '0a1a10');
  assert.deepEqual(dir.map((d) => d.color.getHexString()).sort(), ['4affa0', 'd8ffe4']);
  assert.ok(basicColors(scene).has('1e3325'), 'the station ring is --line-active');
  assert.ok(painted.includes('#4AF37A'), 'a working body is drawn in --ok');
  planet.dispose();
});

test('/world reads tokens at init and again on a theme change, until disposed', () => {
  tokens = {
    '--world-sky': '#112233', '--world-ground': '#223344', '--world-sun': '#334455',
    '--world-rim': '#445566', '--world-ring': '#556677', '--ok': '#00AA11',
    '--world-label': '#ABCDEF', '--world-label-live': '#FEDCBA'
  };
  painted.length = 0;
  const before = { ...listeners };
  const planet = createPlanet(container());
  planet.setScene(SCENE);
  let scene = globalThis.__headless.scene;
  let l = lights(scene);
  assert.equal(l.hemi.color.getHexString(), '112233');
  assert.equal(l.hemi.groundColor.getHexString(), '223344');
  assert.deepEqual(l.dir.map((d) => d.color.getHexString()).sort(), ['334455', '445566']);
  assert.ok(basicColors(scene).has('556677'));
  assert.ok(painted.includes('#00AA11'), 'a working body is drawn in the --ok token');
  assert.ok(painted.includes('#ABCDEF') || painted.includes('#FEDCBA'), 'labels read the label tokens');
  assert.ok(!painted.includes('#4AF37A'), 'no Phosphor literal leaks in when the token says otherwise');

  // The theme engine rewrites :root, then fires the event.
  tokens = { ...tokens, '--world-sky': '#778899', '--world-sun': '#8899AA', '--world-ring': '#99AABB', '--ok': '#CC0033' };
  painted.length = 0;
  const renders = globalThis.__headless.renders;
  window.dispatchEvent(new Event(THEME_CHANGE_EVENT));
  assert.ok(globalThis.__headless.renders > renders, 'a theme change redraws');
  scene = globalThis.__headless.scene;
  l = lights(scene);
  assert.equal(l.hemi.color.getHexString(), '778899');
  assert.ok(l.dir.some((d) => d.color.getHexString() === '8899aa'));
  assert.ok(basicColors(scene).has('99aabb'), 'the ring is rebuilt in the new token');
  assert.ok(painted.includes('#CC0033'), 'bodies are redrawn in the new --ok');

  planet.dispose();
  assert.equal(listeners.added - before.added, 1);
  assert.equal(listeners.removed - before.removed, 1, 'dispose() unsubscribes');
});
