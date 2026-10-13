// The real three.js, minus the one class that needs a GPU. Loaded in place of
// 'three' by tests/theme-world.bh-4843.test.js so createPlanet() runs in node:
// every Scene, Light, Material and Color is the genuine article, and the
// renderer just remembers the last scene it was asked to draw.
export * from 'three';

export class WebGLRenderer {
  constructor({ canvas } = {}) {
    this.domElement = canvas;
    globalThis.__headless = { renders: 0, scene: null };
  }
  setPixelRatio() {}
  setSize() {}
  render(scene) {
    globalThis.__headless.renders += 1;
    globalThis.__headless.scene = scene;
  }
  dispose() {}
}
