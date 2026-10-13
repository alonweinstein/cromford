// Can this browser draw the planet at all?
//
// The 3D world is the default view, not the only one: the flat hex map that
// shipped in #147 is still in the tree and is what renders when WebGL is
// missing. That decision has to be made BEFORE three.js is fetched — a phone
// with WebGL disabled should never pay for the chunk — so the probe lives here,
// takes its document by argument, and is testable without a browser.

// A cached answer per document: creating and throwing away a WebGL context is
// not free, and the answer cannot change inside one page load.
let cached = null;

export function detectWebGL(doc) {
  if (!doc || typeof doc.createElement !== 'function') return false;
  let canvas;
  try {
    canvas = doc.createElement('canvas');
  } catch {
    return false;
  }
  if (!canvas || typeof canvas.getContext !== 'function') return false;
  for (const name of ['webgl2', 'webgl', 'experimental-webgl']) {
    let ctx = null;
    try {
      // `failIfMajorPerformanceCaveat` is deliberately NOT set: a software
      // renderer is slow, not absent, and a slow planet still beats telling
      // someone their browser cannot draw one.
      ctx = canvas.getContext(name);
    } catch {
      ctx = null;
    }
    if (ctx) {
      // Release it immediately. Browsers cap live contexts (~16) and the probe
      // must not spend one of the renderer's.
      const lose = ctx.getExtension && ctx.getExtension('WEBGL_lose_context');
      if (lose && lose.loseContext) { try { lose.loseContext(); } catch { /* nothing to lose */ } }
      return true;
    }
  }
  return false;
}

export function hasWebGL(doc = typeof document === 'undefined' ? null : document) {
  if (cached === null) cached = detectWebGL(doc);
  return cached;
}

// Tests own the cache: nothing else should ever need to re-probe.
export const resetWebGLCache = () => { cached = null; };
