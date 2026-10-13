// The scene's art, drawn into canvases at load time.
//
// A body, a label and a beacon are the only images this planet needs, and
// shipping them as PNGs would mean binary assets in a repo whose whole world
// view is otherwise diffable text. So they are drawn in code, cached by the
// thing they depict, and shared: seven bodies on screen sharing one texture is
// one upload to the GPU, not seven.

import { CanvasTexture, LinearFilter, SRGBColorSpace } from 'three';

const cache = new Map();

function canvas(w, h) {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return c;
}

function finish(c) {
  const tex = new CanvasTexture(c);
  tex.colorSpace = SRGBColorSpace;
  tex.minFilter = LinearFilter;
  tex.magFilter = LinearFilter;
  tex.generateMipmaps = false;
  return tex;
}

// The body, drawn inside the middle 62% of the canvas. The transparent margin
// is deliberate and is the mobile tap target: the art reads at ~24px while the
// quad the raycaster hits is nearer 40, which is the difference between a
// thumb opening a job and a thumb rotating the planet by accident.
const S = 128;

function drawBody(ctx, { color, raised, asleep, walking }) {
  const cx = S / 2;
  const base = S * 0.80;
  const bodyH = S * 0.26;
  const headR = S * 0.115;

  ctx.save();
  if (asleep) {
    // Lying down at the station.
    ctx.translate(cx, base - bodyH * 0.5);
    ctx.rotate(-Math.PI / 2.6);
    ctx.translate(-cx, -(base - bodyH * 0.5));
  }

  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.strokeStyle = color;
  ctx.fillStyle = 'rgba(6,12,7,0.92)';
  ctx.lineWidth = S * 0.035;

  // torso
  ctx.beginPath();
  ctx.moveTo(cx - S * 0.07, base);
  ctx.lineTo(cx - S * 0.07, base - bodyH * 0.62);
  ctx.quadraticCurveTo(cx, base - bodyH * 1.05, cx + S * 0.07, base - bodyH * 0.62);
  ctx.lineTo(cx + S * 0.07, base);
  ctx.closePath();
  ctx.fill();
  ctx.stroke();

  // legs
  ctx.beginPath();
  ctx.moveTo(cx - S * 0.035, base);
  ctx.lineTo(cx - S * 0.05, base + S * 0.05);
  ctx.moveTo(cx + S * 0.035, base);
  ctx.lineTo(cx + S * 0.05, base + S * 0.05);
  ctx.stroke();

  // arms — one up for a hand raised, both forward for hands on the keyboard
  ctx.beginPath();
  if (raised) {
    ctx.moveTo(cx + S * 0.06, base - bodyH * 0.5);
    ctx.lineTo(cx + S * 0.15, base - bodyH * 1.35);
    ctx.moveTo(cx - S * 0.06, base - bodyH * 0.5);
    ctx.lineTo(cx - S * 0.12, base - bodyH * 0.1);
  } else if (walking) {
    ctx.moveTo(cx - S * 0.06, base - bodyH * 0.5);
    ctx.lineTo(cx - S * 0.13, base - bodyH * 0.2);
    ctx.moveTo(cx + S * 0.06, base - bodyH * 0.5);
    ctx.lineTo(cx + S * 0.13, base - bodyH * 0.2);
  } else {
    ctx.moveTo(cx - S * 0.06, base - bodyH * 0.5);
    ctx.lineTo(cx - S * 0.10, base - S * 0.01);
    ctx.moveTo(cx + S * 0.06, base - bodyH * 0.5);
    ctx.lineTo(cx + S * 0.10, base - S * 0.01);
  }
  ctx.stroke();
  if (raised) {
    ctx.beginPath();
    ctx.arc(cx + S * 0.155, base - bodyH * 1.42, S * 0.028, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
  }

  // head
  const hy = base - bodyH - headR * 0.9;
  ctx.beginPath();
  ctx.roundRect(cx - headR, hy - headR, headR * 2, headR * 1.85, headR * 0.55);
  ctx.fillStyle = 'rgba(6,12,7,0.95)';
  ctx.fill();
  ctx.stroke();

  // eyes — shut when asleep, which is the only state where that is a claim
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineWidth = S * 0.026;
  if (asleep) {
    ctx.beginPath();
    ctx.moveTo(cx - headR * 0.62, hy + headR * 0.1);
    ctx.lineTo(cx - headR * 0.12, hy + headR * 0.1);
    ctx.moveTo(cx + headR * 0.12, hy + headR * 0.1);
    ctx.lineTo(cx + headR * 0.62, hy + headR * 0.1);
    ctx.stroke();
  } else {
    ctx.beginPath();
    ctx.arc(cx - headR * 0.38, hy + headR * 0.1, S * 0.017, 0, Math.PI * 2);
    ctx.arc(cx + headR * 0.38, hy + headR * 0.1, S * 0.017, 0, Math.PI * 2);
    ctx.fill();
  }
  // antenna
  ctx.beginPath();
  ctx.moveTo(cx, hy - headR);
  ctx.lineTo(cx, hy - headR * 1.5);
  ctx.stroke();
  ctx.beginPath();
  ctx.arc(cx, hy - headR * 1.62, S * 0.022, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}

export function bodyTexture(state, color) {
  const key = `body:${state}:${color}`;
  if (cache.has(key)) return cache.get(key);
  const c = canvas(S, S);
  const ctx = c.getContext('2d');
  drawBody(ctx, {
    color,
    raised: state === 'blocked' || state === 'stuck' || state === 'quiet' || state === 'offline',
    asleep: state === 'asleep',
    walking: state === 'working'
  });
  const tex = finish(c);
  cache.set(key, tex);
  return tex;
}

// Colours arrive as [r,g,b] 0-255 so a gradient can fade one to nothing
// without string surgery on a hex.
const rgba = (c, a) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;

// A soft round glow, used additively: the halo behind a raised hand and the
// bloom under the beacon column.
export function glowTexture(rgb) {
  const key = `glow:${rgb.join(',')}`;
  if (cache.has(key)) return cache.get(key);
  const c = canvas(64, 64);
  const ctx = c.getContext('2d');
  const g = ctx.createRadialGradient(32, 32, 0, 32, 32, 32);
  g.addColorStop(0, rgba(rgb, 0.95));
  g.addColorStop(0.35, rgba(rgb, 0.4));
  g.addColorStop(1, rgba(rgb, 0));
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 64, 64);
  const tex = finish(c);
  cache.set(key, tex);
  return tex;
}

// The beacon column: bright at the ground, gone by the top.
export function beamTexture(rgb) {
  const key = `beam:${rgb.join(',')}`;
  if (cache.has(key)) return cache.get(key);
  const c = canvas(16, 128);
  const ctx = c.getContext('2d');
  const g = ctx.createLinearGradient(0, 128, 0, 0);
  g.addColorStop(0, rgba(rgb, 0.9));
  g.addColorStop(0.45, rgba(rgb, 0.28));
  g.addColorStop(1, rgba(rgb, 0));
  ctx.fillStyle = g;
  ctx.fillRect(3, 0, 10, 128);
  const tex = finish(c);
  cache.set(key, tex);
  return tex;
}

// A project's name, burned into a strip. Territory labels only — a body's
// label is HTML, because it has to be selectable and long.
export function labelTexture(text, color) {
  const key = `label:${text}:${color}`;
  if (cache.has(key)) return cache.get(key);
  const w = 512;
  const h = 96;
  const c = canvas(w, h);
  const ctx = c.getContext('2d');
  ctx.font = '700 44px "JetBrains Mono", ui-monospace, monospace';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.lineWidth = 8;
  ctx.strokeStyle = 'rgba(4,8,5,0.9)';
  ctx.strokeText(text, w / 2, h / 2);
  ctx.fillStyle = color;
  ctx.fillText(text, w / 2, h / 2);
  const tex = finish(c);
  cache.set(key, tex);
  return tex;
}

// The keyboard's cursor: a ring drawn around whatever the arrow keys are
// standing on. It is deliberately NOT one of the four severity accents — the
// selection is the reader's own position, not a fact about the fleet, so on
// this black scene it is plain white, backed by the scene's own dark so the
// ring survives a lit body and a phosphor coastline alike.
export function haloTexture(color) {
  const key = `halo:${color}`;
  if (cache.has(key)) return cache.get(key);
  const w = 128;
  const c = canvas(w, w);
  const ctx = c.getContext('2d');
  const r = w * 0.40;
  ctx.beginPath();
  ctx.arc(w / 2, w / 2, r, 0, Math.PI * 2);
  ctx.lineWidth = 13;
  ctx.strokeStyle = 'rgba(10,17,11,0.95)';
  ctx.stroke();
  ctx.lineWidth = 7;
  ctx.strokeStyle = color;
  ctx.stroke();
  const tex = finish(c);
  cache.set(key, tex);
  return tex;
}

export function disposeTextures() {
  for (const tex of cache.values()) tex.dispose();
  cache.clear();
}
