import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { flush } from './helpers/settle.js';
import { h, render } from 'preact';
import { useState, useEffect } from 'preact/hooks';

// BH-3561 (BH-3554.0): tests/helpers/settle.js. A useEffect that fetches and
// sets state must have rendered by the time `await flush()` returns, even when
// the event loop stalls right after the mount; and `flush(ms)` waits at least
// `ms` before it settles; and the rAF hook runs effects on 0 ms timers, not
// preact's 35 ms fallback.

// FakeNode, all() and the document setup: copied from build-queue-panel.bh-2510.test.js.
class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, { nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data,
      childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {} });
  }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.childNodes;
    return s[s.indexOf(this) + 1] || null;
  }
  insertBefore(n, ref) {
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this;
    const i = ref ? this.childNodes.indexOf(ref) : -1;
    if (i < 0) this.childNodes.push(n); else this.childNodes.splice(i, 0, n);
    return n;
  }
  appendChild(n) { return this.insertBefore(n, null); }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t.toLowerCase()] = fn; (this.types = this.types || {})[t.toLowerCase()] = t; }
  removeEventListener(t) { delete this.listeners[t.toLowerCase()]; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };

const doc = new FakeNode(9, '#document');
doc.createElement = (t) => new FakeNode(1, t);
doc.createElementNS = (_, t) => new FakeNode(1, t);
doc.createTextNode = (d) => new FakeNode(3, null, d);
globalThis.document = doc;
globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };

function Probe() {
  const [t, setT] = useState('loading');
  useEffect(() => { fetch('/probe').then((r) => r.text()).then(setT); }, []);
  return h('p', null, t);
}

const busyWait = (ms) => {
  const end = performance.now() + ms; // determinism: ok a CPU stall to reproduce a loaded box; no assertion reads the clock
  while (performance.now() < end) { /* stall */ } // determinism: ok a CPU stall to reproduce a loaded box; no assertion reads the clock
};

let mounted = null;
afterEach(() => { if (mounted) { render(null, mounted); mounted = null; } });

test('S1: flush() settles a fetching useEffect even when the loop stalls after mount', async () => {
  globalThis.fetch = async () => ({ ok: true, status: 200, text: async () => 'fetched-ok' });
  const root = doc.createElement('div');
  mounted = root;
  render(h(Probe), root);
  setTimeout(() => busyWait(120), 1);
  await flush();
  assert.ok(root.textContent.includes('fetched-ok'), `rendered: ${root.textContent}`);
  assert.equal(all(root).filter((n) => n.localName === 'p').length, 1);
});

test('S2: flush(ms) waits at least ms and lets an earlier timer run', async () => {
  let ran = false;
  setTimeout(() => { ran = true; }, 40);
  const t0 = performance.now(); // determinism: ok measures that flush waited at least ms; lower bound only, never an upper bound
  await flush(50); // fixed-wait: ok S2 pins flush(ms) itself
  const dt = performance.now() - t0; // determinism: ok measures that flush waited at least ms; lower bound only, never an upper bound
  assert.ok(dt >= 50, `flush(50) resolved after ${dt} ms`);
  assert.equal(ran, true);
});

test('S3: effects run on 0 ms timers, so a fetching useEffect renders within three turns', async () => {
  // Without the helper's rAF hook preact waits a 35 ms real timer before any
  // effect, and three zero-delay turns never reach it on an idle box.
  globalThis.fetch = async () => ({ ok: true, status: 200, text: async () => 'fetched-ok' });
  const root = doc.createElement('div');
  mounted = root;
  render(h(Probe), root);
  await flush(0, 3);
  assert.ok(root.textContent.includes('fetched-ok'), `rendered: ${root.textContent}`);
});
