// The renderer. This is the ONLY file in the console that imports three.js, and
// it is only ever reached through a dynamic import from the /world route — so a
// phone that opens ALERTS never downloads a 3D engine, and a browser without
// WebGL never downloads it at all (screens/World.js probes first).
//
// It decides nothing. Every position, colour, label and link was already fixed
// by lib/world3d.js, which is pure and tested; this file turns those numbers
// into meshes, runs the frame loop, and reports taps back. If you find yourself
// adding a rule here — what counts as blocked, who stands where — it belongs in
// lib/world3d.js instead, where a test can read it.

import {
  Scene, PerspectiveCamera, WebGLRenderer, Group, Color, Vector2, Vector3,
  Raycaster, Sprite, SpriteMaterial, Mesh, MeshStandardMaterial, MeshBasicMaterial,
  IcosahedronGeometry, SphereGeometry, TorusGeometry, CylinderGeometry,
  BufferGeometry, BufferAttribute, ShaderMaterial, DoubleSide,
  Points, PointsMaterial, HemisphereLight, DirectionalLight, AdditiveBlending,
  BackSide, FrontSide, MathUtils
} from 'three';
import { buildWorld3D, worldKey, ownerAt, offsetOnSphere, DEFAULT_SKIN, STATION_RADIUS, STATION_TILT } from '../lib/world3d.js';
import { bodyTexture, glowTexture, beamTexture, labelTexture, haloTexture, disposeTextures } from './textures.js';
import { readToken, parseColor, onThemeChange } from '../theme/tokens.js';
import { PHOSPHOR_FALLBACK } from '../theme/phosphor.js';

// Same tone tokens the flat map and every table in the console use. A body's
// colour is its STATE and nothing else, so the two views cannot disagree.
const TONE_TOKEN = { ok: '--ok', warn: '--warn', dead: '--err', idle: '--world-idle' };

// Every colour this file draws with, read from the :root tokens. A canvas and a
// WebGL material cannot take a var() string, so the values are read here, at
// init and again on a theme change; before the stylesheet applies they are the
// Phosphor values.
function readPalette() {
  const out = {};
  for (const [name, fallback] of Object.entries(PHOSPHOR_FALLBACK)) out[name] = readToken(name, fallback);
  return out;
}

// Geometry budget. detail 3 is 1280 triangles for the whole globe — enough for
// islands to have a recognisable coastline, few enough that a mid-range phone
// draws it without thinking about it.
const PLANET_DETAIL = 3;
const FOV = 38;
// Movement past which a gesture is an orbit and not a tap. Same number the flat
// map uses, for the same reason.
const DRAG_SLOP = 10;
const MIN_DIST = 1.75;
const MAX_DIST = 9;

// Deterministic per-face jitter, so the terrain is faceted rather than flat and
// looks the same on every reload.
const hash = (i) => {
  const x = Math.sin(i * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

export function createPlanet(container, {
  onPress = () => {},
  onOpen = () => {},
  onLost = () => {},
  reducedMotion = false
} = {}) {
  const canvas = document.createElement('canvas');
  canvas.className = 'world3d';
  canvas.setAttribute('aria-hidden', 'true');
  container.appendChild(canvas);

  let renderer;
  try {
    renderer = new WebGLRenderer({ canvas, antialias: false, alpha: false, powerPreference: 'low-power' });
  } catch (e) {
    container.removeChild(canvas);
    throw e;
  }
  // Two is the cap on purpose: a 3x phone screen triples the pixels for a
  // difference nobody can see on a low-poly planet, and pays for it in frames.
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));

  const scene = new Scene();
  const camera = new PerspectiveCamera(FOV, 1, 0.1, 60);

  const planetGroup = new Group();   // the globe and everyone standing on it
  const orbitGroup = new Group();    // the station ring, which turns the other way
  const worldGroup = new Group();    // both, so a reset is one line
  worldGroup.add(planetGroup, orbitGroup);
  scene.add(worldGroup);

  let palette = readPalette();
  const toneToken = (t) => TONE_TOKEN[t] || TONE_TOKEN.idle;
  const toneHex = (t) => palette[toneToken(t)];
  // A token that is not a plain colour (a theme writing a name or hsl()) keeps
  // the Phosphor triple rather than drawing a black beam.
  const toneRgb = (t) => parseColor(toneHex(t)) || parseColor(PHOSPHOR_FALLBACK[toneToken(t)]);

  const sky = new HemisphereLight(palette['--world-sky'], palette['--world-ground'], 1.15);
  scene.add(sky);
  const sun = new DirectionalLight(palette['--world-sun'], 1.5);
  sun.position.set(3, 2.4, 2.2);
  scene.add(sun);
  const rim = new DirectionalLight(palette['--world-rim'], 0.35);
  rim.position.set(-3, -1, -2);
  scene.add(rim);

  const state = {
    theta: 0.6, phi: 1.15, dist: 4.4, baseDist: 4.4,
    t: 0, last: 0, raf: 0, active: true, disposed: false,
    world: null, key: null,
    // Which entity the arrow keys are standing on. An id, not an object: the
    // meshes are thrown away and rebuilt whenever the world's shape changes,
    // and a selection has to survive that.
    selected: null
  };
  const disposables = [];
  let pickables = [];
  let labels = [];
  let landFaceOwner = null;
  let landMesh = null;
  let stars = null;

  // -------------------------------------------------------------- starfield

  function buildStars(skin) {
    const n = 700;
    const pos = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) {
      // Deterministic, and pushed out past the far side of the orbit so the
      // planet never clips into the sky.
      const u = hash(i) * 2 - 1;
      const a = hash(i + 991) * Math.PI * 2;
      const r = 18 + hash(i + 77) * 12;
      const s = Math.sqrt(Math.max(0, 1 - u * u));
      pos[i * 3] = Math.cos(a) * s * r;
      pos[i * 3 + 1] = u * r;
      pos[i * 3 + 2] = Math.sin(a) * s * r;
    }
    const geo = new BufferGeometry();
    geo.setAttribute('position', new BufferAttribute(pos, 3));
    const mat = new PointsMaterial({
      color: new Color().setHSL(skin.star.h, skin.star.s, skin.star.l),
      size: 0.09, sizeAttenuation: true, transparent: true, opacity: 0.75
    });
    stars = new Points(geo, mat);
    stars.frustumCulled = false;
    scene.add(stars);
    disposables.push(geo, mat);
  }

  // ---------------------------------------------------------------- planet

  // One icosphere, two meshes: the sea is the whole sphere, and the land is
  // only the faces a territory reaches, lifted clear of it. The gap that leaves
  // at a coastline is the point — it is what makes an island read as an island
  // rather than as a stain on a ball.
  function buildGlobe(world) {
    const skin = world.skin;
    const src = new IcosahedronGeometry(1, PLANET_DETAIL);
    const pos = src.attributes.position;
    const faces = pos.count / 3;

    const seaColor = new Color().setHSL(skin.ocean.h, skin.ocean.s, skin.ocean.l);
    const sea = new Mesh(
      new IcosahedronGeometry(0.995, PLANET_DETAIL),
      new MeshStandardMaterial({ color: seaColor, flatShading: true, roughness: 0.85, metalness: 0.05, side: FrontSide })
    );
    disposables.push(sea.geometry, sea.material);
    planetGroup.add(sea);

    const owners = new Int32Array(faces).fill(-1);
    const keep = [];
    const c = new Vector3();
    for (let f = 0; f < faces; f++) {
      c.set(0, 0, 0);
      for (let k = 0; k < 3; k++) c.set(c.x + pos.getX(f * 3 + k), c.y + pos.getY(f * 3 + k), c.z + pos.getZ(f * 3 + k));
      c.normalize();
      const o = ownerAt([c.x, c.y, c.z], world.territories);
      owners[f] = o;
      if (o >= 0) keep.push(f);
    }

    const lp = new Float32Array(keep.length * 9);
    const lc = new Float32Array(keep.length * 9);
    landFaceOwner = new Int32Array(keep.length);
    const col = new Color();
    for (let i = 0; i < keep.length; i++) {
      const f = keep[i];
      const t = world.territories[owners[f]];
      landFaceOwner[i] = owners[f];
      // Every face of an island is lifted by the same amount, so the coast is a
      // cliff and not a slope; a little per-face jitter on top keeps it from
      // looking like a decal.
      const lift = 1 + t.elevation + hash(f) * 0.018;
      col.setHSL(t.color.h, t.color.s, t.color.l * (0.86 + hash(f + 13) * 0.3));
      for (let k = 0; k < 3; k++) {
        const s = f * 3 + k;
        const d = i * 9 + k * 3;
        lp[d] = pos.getX(s) * lift;
        lp[d + 1] = pos.getY(s) * lift;
        lp[d + 2] = pos.getZ(s) * lift;
        lc[d] = col.r; lc[d + 1] = col.g; lc[d + 2] = col.b;
      }
    }
    const landGeo = new BufferGeometry();
    landGeo.setAttribute('position', new BufferAttribute(lp, 3));
    landGeo.setAttribute('color', new BufferAttribute(lc, 3));
    landGeo.computeVertexNormals();
    const landMat = new MeshStandardMaterial({
      vertexColors: true, flatShading: true, roughness: 0.72, metalness: 0.08,
      emissive: new Color().setHSL(skin.atmosphere.h, 0.5, 0.03)
    });
    landMesh = new Mesh(landGeo, landMat);
    planetGroup.add(landMesh);
    disposables.push(landGeo, landMat);
    src.dispose();

    // The atmosphere: a slightly bigger sphere seen from the inside, glowing
    // only where it is edge-on. Eight lines of shader is the whole cost of a
    // rim light — no bloom pass, no second render target, one draw call. A flat
    // additive sphere instead of this reads as a dull disc behind the planet.
    const atmoMat = new ShaderMaterial({
      uniforms: { uColor: { value: new Color().setHSL(skin.atmosphere.h, skin.atmosphere.s, skin.atmosphere.l) } },
      vertexShader: `
        varying vec3 vN; varying vec3 vP;
        void main() {
          vN = normalize(normalMatrix * normal);
          vec4 mv = modelViewMatrix * vec4(position, 1.0);
          vP = mv.xyz;
          gl_Position = projectionMatrix * mv;
        }`,
      fragmentShader: `
        uniform vec3 uColor; varying vec3 vN; varying vec3 vP;
        void main() {
          float f = 1.0 - abs(dot(normalize(vN), normalize(-vP)));
          gl_FragColor = vec4(uColor, pow(f, 4.2) * 0.6);
        }`,
      transparent: true, side: BackSide, blending: AdditiveBlending, depthWrite: false
    });
    const atmo = new Mesh(new SphereGeometry(1.11, 48, 32), atmoMat);
    planetGroup.add(atmo);
    disposables.push(atmo.geometry, atmoMat);
  }

  // Project names, standing on their own ground.
  function buildLabels(world) {
    for (const t of world.territories) {
      const tex = labelTexture(t.project, t.live ? palette['--world-label-live'] : palette['--world-label']);
      const mat = new SpriteMaterial({ map: tex, transparent: true, depthTest: true, depthWrite: false });
      const sp = new Sprite(mat);
      // Not straight up off the centre: a label pushed along the RADIUS moves
      // toward the camera and lands on top of the bodies standing there. It is
      // walked north across the surface instead, where the ground is empty.
      const p = offsetOnSphere(t.center, t.radius * 0.62, Math.PI / 2);
      const h = 1 + t.elevation + 0.045;
      sp.position.set(p[0] * h, p[1] * h, p[2] * h);
      const w = Math.min(0.62, 0.075 * Math.max(6, t.project.length));
      sp.scale.set(w, w * 0.1875, 1);
      // A label is scenery: it must never eat the tap meant for the island it
      // is naming.
      sp.raycast = () => {};
      planetGroup.add(sp);
      disposables.push(mat);
      // Depth-testing a label against the globe cuts words in half at the limb,
      // which reads as a rendering bug rather than as perspective. So labels
      // are drawn on top and instead FADE OUT as their island turns away —
      // see updateFacing().
      mat.depthTest = false;
      labels.push({ sprite: sp, dir: new Vector3(t.center[0], t.center[1], t.center[2]) });
    }
  }

  // ----------------------------------------------------------------- bodies

  // Bodies are billboards, not models: a sprite is one quad, it always faces
  // the camera, and it is the only way a person the size of a pixel stays
  // readable on a globe you can spin.
  const BODY_SCALE = 0.26;

  // One open-ended cone, shared by every beacon: wider at the sky, narrow where
  // it meets the ground, so the column reads as light and not as a pole.
  let beamGeo = null;
  const beamGeometry = () => {
    if (!beamGeo) {
      beamGeo = new CylinderGeometry(0.05, 0.016, 0.52, 8, 1, true);
      disposables.push(beamGeo);
    }
    return beamGeo;
  };

  function addBody(parent, body, pickKind) {
    const g = new Group();
    const p = body.position;
    g.position.set(p[0], p[1], p[2]);

    const hex = toneHex(body.tone);
    const rgb = toneRgb(body.tone);

    if (body.beacon) {
      // The whole reason this view exists: something needs a person, and it has
      // to be findable from across the room. A column of light standing on the
      // ground — a real cylinder, NOT a billboard, because a billboard beam on
      // a body near the limb draws itself vertically while its anchor points
      // sideways, and detaches from the person it is pointing at.
      const beam = new Mesh(beamGeometry(), new MeshBasicMaterial({
        map: beamTexture(rgb), transparent: true, blending: AdditiveBlending,
        depthWrite: false, opacity: 0.8, side: DoubleSide
      }));
      beam.position.set(0, 0.26, 0);
      beam.raycast = () => {};
      beam.userData.pulse = 'beam';
      g.add(beam);
      disposables.push(beam.material);

      const halo = new Sprite(new SpriteMaterial({
        map: glowTexture(rgb), transparent: true, blending: AdditiveBlending,
        depthWrite: false, opacity: 0.55
      }));
      halo.scale.set(0.36, 0.36, 1);
      halo.position.set(0, 0.07, 0);
      halo.raycast = () => {};
      halo.userData.pulse = 'halo';
      g.add(halo);
      disposables.push(halo.material);
    }

    const mat = new SpriteMaterial({ map: bodyTexture(body.state, hex), transparent: true, depthWrite: false });
    const sp = new Sprite(mat);
    sp.scale.set(BODY_SCALE, BODY_SCALE, 1);
    sp.position.set(0, BODY_SCALE * 0.42, 0);
    sp.userData.pick = { kind: pickKind, id: body.id, to: body.to, label: body.label, state: body.state, tone: body.tone, raised: body.raised };
    sp.userData.body = body;
    g.add(sp);
    disposables.push(mat);
    parent.add(g);
    pickables.push(sp);

    // Standing upright on a globe: the sprite billboards, but the group it
    // rides in is tilted so the beacon points at the sky and not at the camera.
    const up = new Vector3(p[0], p[1], p[2]).normalize();
    g.quaternion.setFromUnitVectors(new Vector3(0, 1, 0), up);
    g.userData.anim = { walks: body.walks, phase: body.phase || 0, base: g.position.clone(), up };
    return g;
  }

  function buildBodies(world) {
    for (const b of world.agents) {
      if (b.homeless || !b.position) continue;
      addBody(planetGroup, b, 'agent');
    }
  }

  // The station: one ring in orbit, one sleeping box per bunk. An idle box
  // belongs to no project, so it is not standing on anybody's ground.
  function buildStation(world) {
    if (!world.station.length) return;
    const ringMat = new MeshBasicMaterial({ color: palette['--world-ring'], transparent: true, opacity: 0.5 });
    const ring = new Mesh(new TorusGeometry(STATION_RADIUS, 0.006, 3, 96), ringMat);
    ring.rotation.x = Math.PI / 2 - STATION_TILT * 0.42;
    orbitGroup.add(ring);
    disposables.push(ring.geometry, ringMat);
    for (const b of world.station) addBody(orbitGroup, b, 'box');
  }

  // ------------------------------------------------------------------ build

  function clearGroup(g) {
    for (const child of [...g.children]) g.remove(child);
  }

  // The scene arrives as the SAME object screens/World.js already built for
  // the flat map; turning it into positions happens here, inside the lazy
  // chunk, so the main bundle carries no 3D code at all — not even the maths.
  function setScene(scene, { skin = DEFAULT_SKIN } = {}) {
    const world = buildWorld3D(scene, { skin });
    const key = worldKey(world);
    // A poll that only moved a heartbeat by 20 seconds must not tear the planet
    // down under a moving thumb.
    if (key === state.key) return;
    state.key = key;
    setWorld(world);
  }

  function setWorld(world) {
    state.world = world;
    pickables = [];
    labels = [];
    beamGeo = null;
    landMesh = null;
    landFaceOwner = null;
    clearGroup(planetGroup);
    clearGroup(orbitGroup);
    // Textures are cached and shared, so a rebuild throws away meshes and
    // materials, never the art.
    for (const d of disposables.splice(0)) if (d && d.dispose) d.dispose();
    if (stars) { scene.remove(stars); stars.geometry.dispose(); stars.material.dispose(); stars = null; }
    buildStars(world.skin);
    if (world.territories.length) {
      buildGlobe(world);
      buildLabels(world);
      buildBodies(world);
    }
    buildStation(world);
    // The meshes are new; the reader's place in the world is not.
    applySelection();
    render();
  }

  // -------------------------------------------------------------- selection

  // The keyboard's cursor, as geometry. A body gets a billboard ring around it
  // and a territory gets a real ring lying on its own cap, both in the scene's
  // ink rather than in a severity colour — where the reader is standing is not
  // a fact about the fleet, and it must not be mistaken for one.
  const SEL_SCALE = BODY_SCALE * 1.5;
  let selNode = null;
  const selJunk = [];

  function dropSelection() {
    if (selNode && selNode.parent) selNode.parent.remove(selNode);
    selNode = null;
    for (const d of selJunk.splice(0)) if (d && d.dispose) d.dispose();
  }

  function findPickable(id) {
    for (const sp of pickables) if (sp.userData.pick && sp.userData.pick.id === id) return sp;
    return null;
  }

  function applySelection() {
    dropSelection();
    const id = state.selected;
    if (!id) return;

    const sp = findPickable(id);
    if (sp && sp.parent) {
      const mat = new SpriteMaterial({ map: haloTexture(palette['--select-ink']), transparent: true, depthWrite: false, depthTest: false });
      const halo = new Sprite(mat);
      halo.scale.set(SEL_SCALE, SEL_SCALE, 1);
      halo.position.copy(sp.position);
      halo.renderOrder = 3;
      halo.raycast = () => {};
      sp.parent.add(halo);
      selNode = halo;
      selJunk.push(mat);
      return;
    }

    const terr = state.world ? state.world.territories.find((t) => t.id === id) : null;
    if (!terr) return;
    // A hair inside the coastline, so the ring reads as around the island
    // rather than as floating in the sea beside it.
    const a = terr.radius * 0.92;
    const R = 1 + terr.elevation + 0.006;
    const geo = new TorusGeometry(Math.sin(a) * R, 0.014, 3, 72);
    const mat = new MeshBasicMaterial({ color: new Color(palette['--select-ink']) });
    const ring = new Mesh(geo, mat);
    const dir = new Vector3(terr.center[0], terr.center[1], terr.center[2]).normalize();
    ring.position.copy(dir).multiplyScalar(Math.cos(a) * R);
    ring.quaternion.setFromUnitVectors(new Vector3(0, 0, 1), dir);
    planetGroup.add(ring);
    selNode = ring;
    selJunk.push(geo, mat);
  }

  function setSelected(id) {
    const next = id || null;
    if (next === state.selected) return;
    state.selected = next;
    applySelection();
    render();
  }

  // ------------------------------------------------------------ nav targets

  // Where everything IS, right now, in the reader's screen space — the input
  // the arrow keys need and the one thing a spinning globe cannot precompute.
  // The planet turns, so "the body to the left" is a question about this
  // frame's projection and nothing else. y is flipped on the way out because
  // three.js NDC points up and lib/worldnav.js works in screen coordinates.
  const projV = new Vector3();

  function onScreen(worldPos, eyeDir) {
    const d = worldPos.dot(eyeDir);
    if (d > 0.02) return true;
    // Behind the middle of the globe: only visible if it clears the limb.
    const perp = Math.sqrt(Math.max(0, worldPos.lengthSq() - d * d));
    return perp > 1.04;
  }

  function navTargets() {
    const entities = [];
    if (!state.world) return { entities, center: { x: 0, y: 0 } };
    const eyeDir = camera.position.clone().normalize();

    for (const sp of pickables) {
      if (!sp.userData.pick) continue;
      sp.getWorldPosition(projV);
      if (!onScreen(projV, eyeDir)) continue;
      projV.project(camera);
      if (projV.z > 1 || Math.abs(projV.x) > 1.08 || Math.abs(projV.y) > 1.08) continue;
      entities.push({ ...sp.userData.pick, x: projV.x, y: -projV.y });
    }

    for (const t of state.world.territories) {
      projV.set(t.center[0], t.center[1], t.center[2]).multiplyScalar(1 + t.elevation);
      planetGroup.localToWorld(projV);
      // The same threshold that decides a territory's NAME is legible: an
      // island you cannot read the label of is not one you meant to select.
      if (projV.clone().normalize().dot(eyeDir) <= 0.30) continue;
      projV.project(camera);
      if (projV.z > 1) continue;
      entities.push({
        kind: 'territory', id: t.id, to: t.to, label: t.project, title: t.title,
        live: t.live, needs: t.needs, raised: t.raised, paused: t.paused,
        x: projV.x, y: -projV.y
      });
    }
    // The middle of the viewport, which in normalised device coordinates is
    // exactly the origin — so the first arrow press lands where the eye is.
    return { entities, center: { x: 0, y: 0 } };
  }

  // ---------------------------------------------------------------- camera

  function place() {
    const sp = Math.sin(state.phi);
    camera.position.set(
      state.dist * sp * Math.sin(state.theta),
      state.dist * Math.cos(state.phi),
      state.dist * sp * Math.cos(state.theta)
    );
    camera.lookAt(0, 0, 0);
  }

  function resize() {
    const w = container.clientWidth || 1;
    const h = container.clientHeight || 1;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    // The whole orbit has to fit on a phone held upright, so the distance is
    // driven by the NARROWER of the two dimensions rather than by the width.
    const fit = 1.62 / (Math.tan((FOV / 2) * Math.PI / 180) * Math.min(1, camera.aspect));
    const next = MathUtils.clamp(fit, 3.2, 6.6);
    if (state.baseDist !== next) {
      const ratio = state.dist / state.baseDist;
      state.baseDist = next;
      state.dist = MathUtils.clamp(next * ratio, MIN_DIST, MAX_DIST);
    }
    place();
    render();
  }

  const zoomBy = (factor) => {
    state.dist = MathUtils.clamp(state.dist * factor, MIN_DIST, MAX_DIST);
    place();
    render();
  };

  const reset = () => {
    state.theta = 0.6;
    state.phi = 1.15;
    state.dist = state.baseDist;
    worldGroup.rotation.set(0, 0, 0);
    planetGroup.rotation.y = 0;
    orbitGroup.rotation.y = 0;
    place();
    render();
  };

  // --------------------------------------------------------------- picking

  const ray = new Raycaster();
  const ndc = new Vector2();

  function pickAt(clientX, clientY) {
    const r = canvas.getBoundingClientRect();
    ndc.x = ((clientX - r.left) / Math.max(1, r.width)) * 2 - 1;
    ndc.y = -((clientY - r.top) / Math.max(1, r.height)) * 2 + 1;
    ray.setFromCamera(ndc, camera);
    const hits = ray.intersectObjects(pickables, false);
    if (hits.length) return hits[0].object.userData.pick;
    if (landMesh) {
      const land = ray.intersectObject(landMesh, false);
      if (land.length) {
        const face = Math.floor(land[0].faceIndex);
        const owner = landFaceOwner && face < landFaceOwner.length ? landFaceOwner[face] : -1;
        const t = owner >= 0 ? state.world.territories[owner] : null;
        if (t) return { kind: 'territory', id: t.id, to: t.to, label: t.project, title: t.title, live: t.live, needs: t.needs, raised: t.raised, paused: t.paused };
      }
    }
    return null;
  }

  // ------------------------------------------------------------- gestures

  const pointers = new Map();
  const drag = { moved: 0, last: null, pinch: null, target: null, id: null };

  const onPointerDown = (e) => {
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      drag.pinch = Math.hypot(a.x - b.x, a.y - b.y) || 1;
      drag.target = null;
      return;
    }
    drag.moved = 0;
    drag.last = { x: e.clientX, y: e.clientY };
    drag.id = e.pointerId;
    // The label appears the moment a finger lands, before the tap has decided
    // whether it is a tap: touching a body tells you who it is, and lifting
    // without moving opens it.
    drag.target = pickAt(e.clientX, e.clientY);
    onPress(drag.target);
    render();
  };

  const onPointerMove = (e) => {
    if (!pointers.has(e.pointerId)) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size >= 2) {
      const [a, b] = [...pointers.values()];
      const d = Math.hypot(a.x - b.x, a.y - b.y) || 1;
      const prev = drag.pinch || d;
      drag.pinch = d;
      drag.moved += Math.abs(d - prev);
      zoomBy(prev / d);
      return;
    }
    if (!drag.last || e.pointerId !== drag.id) return;
    const dx = e.clientX - drag.last.x;
    const dy = e.clientY - drag.last.y;
    drag.last = { x: e.clientX, y: e.clientY };
    drag.moved += Math.abs(dx) + Math.abs(dy);
    if (drag.moved <= DRAG_SLOP) return;
    if (canvas.setPointerCapture && !drag.captured) {
      try { canvas.setPointerCapture(e.pointerId); drag.captured = e.pointerId; } catch { /* not captureable */ }
    }
    state.theta -= dx * 0.006;
    state.phi = MathUtils.clamp(state.phi - dy * 0.006, 0.28, Math.PI - 0.28);
    place();
    render();
  };

  const onPointerUp = (e) => {
    const wasTap = pointers.size === 1 && drag.moved <= DRAG_SLOP && e.pointerId === drag.id;
    pointers.delete(e.pointerId);
    if (drag.captured === e.pointerId) {
      try { canvas.releasePointerCapture(e.pointerId); } catch { /* already gone */ }
      drag.captured = null;
    }
    if (pointers.size < 2) drag.pinch = null;
    if (!pointers.size) drag.last = null;
    if (wasTap && drag.target && e.type !== 'pointercancel') onOpen(drag.target);
  };

  const onWheel = (e) => {
    e.preventDefault();
    zoomBy(e.deltaY > 0 ? 1.12 : 1 / 1.12);
  };

  canvas.addEventListener('pointerdown', onPointerDown);
  canvas.addEventListener('pointermove', onPointerMove);
  canvas.addEventListener('pointerup', onPointerUp);
  canvas.addEventListener('pointercancel', onPointerUp);
  canvas.addEventListener('wheel', onWheel, { passive: false });

  const onContextLost = (e) => {
    e.preventDefault();
    stop();
    onLost();
  };
  canvas.addEventListener('webglcontextlost', onContextLost);

  // ------------------------------------------------------------ the frame

  // A name only belongs to the half of the planet you can see.
  const facing = new Vector3();
  function updateFacing() {
    if (!labels.length) return;
    const eye = camera.position.clone().normalize();
    for (const l of labels) {
      facing.copy(l.dir).applyQuaternion(planetGroup.quaternion);
      const d = facing.dot(eye);
      l.sprite.visible = d > 0.22;
      l.sprite.material.opacity = MathUtils.clamp((d - 0.22) / 0.22, 0, 1);
    }
  }

  function render() {
    if (state.disposed) return;
    updateFacing();
    renderer.render(scene, camera);
  }

  function tick(now) {
    if (state.disposed) return;
    state.raf = requestAnimationFrame(tick);
    const dt = state.last ? Math.min(0.05, (now - state.last) / 1000) : 0.016;
    state.last = now;
    state.t += dt;

    // The planet turns; the station ring turns the other way, slower. Both are
    // slow enough to watch and not slow enough to look broken.
    planetGroup.rotation.y += dt * 0.055;
    orbitGroup.rotation.y -= dt * 0.022;
    // A hair of camera drift, so a wall display never looks like a still.
    state.phi += Math.sin(state.t * 0.13) * 0.00035;
    place();

    for (const group of [planetGroup, orbitGroup]) {
      for (const child of group.children) {
        const anim = child.userData.anim;
        if (anim) {
          // Working bodies pace around their seat; everyone else stands still.
          const bob = anim.walks ? Math.sin(state.t * 2.1 + anim.phase) * 0.012 : 0;
          const sway = anim.walks ? Math.cos(state.t * 1.3 + anim.phase) * 0.016 : 0;
          child.position.copy(anim.base).addScaledVector(anim.up, bob);
          child.position.x += sway * 0.35;
        }
        for (const part of child.children) {
          if (!part.userData.pulse) continue;
          const k = 0.55 + Math.sin(state.t * 2.6 + (child.userData.anim ? child.userData.anim.phase : 0)) * 0.35;
          part.material.opacity = part.userData.pulse === 'beam' ? 0.55 * k + 0.3 : 0.75 * k;
        }
      }
    }
    render();
  }

  function start() {
    if (reducedMotion || state.disposed || state.raf) return;
    state.last = 0;
    state.raf = requestAnimationFrame(tick);
  }

  function stop() {
    if (state.raf) cancelAnimationFrame(state.raf);
    state.raf = 0;
  }

  function setActive(on) {
    state.active = on;
    if (on) start(); else stop();
  }

  // The theme engine fires this after it rewrites :root. Re-read every token,
  // relight, and rebuild the meshes from the world already held; textures are
  // cached by colour, so new colours get new art and nothing is fetched.
  const offTheme = onThemeChange(() => {
    if (state.disposed) return;
    palette = readPalette();
    sky.color.set(palette['--world-sky']);
    sky.groundColor.set(palette['--world-ground']);
    sun.color.set(palette['--world-sun']);
    rim.color.set(palette['--world-rim']);
    if (state.world) setWorld(state.world);
    render();
  });

  resize();
  start();
  render();

  return {
    setScene,
    navTargets,
    setSelected,
    resize,
    zoomIn: () => zoomBy(1 / 1.3),
    zoomOut: () => zoomBy(1.3),
    reset,
    setActive,
    render,
    get canvas() { return canvas; },
    dispose() {
      state.disposed = true;
      offTheme();
      stop();
      dropSelection();
      canvas.removeEventListener('pointerdown', onPointerDown);
      canvas.removeEventListener('pointermove', onPointerMove);
      canvas.removeEventListener('pointerup', onPointerUp);
      canvas.removeEventListener('pointercancel', onPointerUp);
      canvas.removeEventListener('wheel', onWheel);
      canvas.removeEventListener('webglcontextlost', onContextLost);
      for (const d of disposables.splice(0)) if (d && d.dispose) d.dispose();
      if (stars) { stars.geometry.dispose(); stars.material.dispose(); stars = null; }
      disposeTextures();
      renderer.dispose();
      if (canvas.parentNode === container) container.removeChild(canvas);
    }
  };
}
