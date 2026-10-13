// BH-5619 (BH-5611.3): render errors in a routed screen are caught by a Preact
// error boundary, reported to Sentry once when VITE_SENTRY_DSN was set at build
// time, and replaced by a themed fallback while the top bar and nav stay up.
//
// The Sentry SDK is injected through initSentry's second argument, so every
// case counts real calls on a fake SDK. Case E mounts the real App through the
// real ROUTES table into a small fake DOM against a stubbed fetch.

import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { initSentry, reportError } = await import('../src/lib/error-report.js');
const { ErrorBoundary } = await import('../src/ui/ErrorBoundary.js');
const { App, ROUTES } = await import('../src/app.js');

const DSN = 'https://k@o0.ingest.sentry.io/0';

// ------------------------------------------------------------- fake DOM

class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType;
    this.localName = name;
    this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data;
    this.childNodes = [];
    this.parentNode = null;
    this.attrs = {};
    this.style = {};
    this.listeners = {};
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
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.documentElement = new FakeNode(1, 'html');
  doc.querySelector = () => null;
  globalThis.document = doc;
  return doc;
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };

const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); initSentry(undefined); });

function fakeSdk() {
  const sdk = { inits: [], captures: [], users: 0 };
  sdk.init = (opts) => { sdk.inits.push(opts); };
  sdk.captureException = (err, hint) => { sdk.captures.push([err, hint]); };
  sdk.setUser = () => { sdk.users += 1; };
  return sdk;
}

function Boom() { throw new Error('boom'); }

function mountInto(vnode) {
  const doc = installDom();
  const el = doc.createElement('div');
  mounted.add(el);
  mount(vnode, el);
  return el;
}

// ------------------------------------------------------------- cases

test('A. no DSN: initSentry never calls init', () => {
  for (const env of [{}, { VITE_SENTRY_DSN: '' }, { VITE_SENTRY_DSN: '   ' }, { VITE_SENTRY_DSN: false }, undefined]) {
    const sdk = fakeSdk();
    assert.equal(initSentry(env, sdk), false, `env ${JSON.stringify(env)} must not activate`);
    assert.equal(sdk.inits.length, 0, `env ${JSON.stringify(env)} must not call init`);
    reportError(new Error('x'), '');
    assert.equal(sdk.captures.length, 0);
  }
});

test('B. with a DSN: a render throw reaches the boundary and is captured exactly once', async () => {
  const sdk = fakeSdk();
  assert.equal(initSentry({ VITE_SENTRY_DSN: DSN }, sdk), true);
  let thrown;
  function Thrower() { thrown = new Error('boom'); throw thrown; }
  const tree = () => h(ErrorBoundary, null, h(Thrower));
  const el = mountInto(tree());
  await flush();
  assert.equal(sdk.captures.length, 1);
  assert.equal(sdk.captures[0][0], thrown);
  assert.ok(el.textContent.includes('THIS SCREEN FAILED'), el.textContent);
  assert.ok(el.textContent.includes('boom'));
  assert.ok(all(el).some((n) => n.attrs && n.attrs.class === 'empty'), 'fallback uses the theme .empty block');
  mount(tree(), el);
  await flush();
  assert.equal(sdk.captures.length, 1, 'a re-render of the caught boundary does not capture again');
});

test('C. with a DSN: init is called once with that DSN', () => {
  const sdk = fakeSdk();
  initSentry({ VITE_SENTRY_DSN: DSN }, sdk);
  assert.equal(sdk.inits.length, 1);
  assert.equal(sdk.inits[0].dsn, DSN);
});

test('D. init options: no replay, no PII, no user data', () => {
  const sdk = fakeSdk();
  initSentry({ VITE_SENTRY_DSN: DSN }, sdk);
  const opts = sdk.inits[0];
  assert.equal(opts.sendDefaultPii, false);
  if ('integrations' in opts) {
    const list = Array.isArray(opts.integrations) ? opts.integrations : [];
    assert.ok(!list.some((i) => /replay/i.test(String(i && i.name))), 'no replay integration');
  }
  assert.ok(!('replaysSessionSampleRate' in opts));
  assert.ok(!('replaysOnErrorSampleRate' in opts));
  assert.ok(!('user' in opts));
  assert.ok(!JSON.stringify(opts.initialScope || {}).includes('"user"'));
  assert.equal(sdk.users, 0);
});

test('E. App wraps the routed screen: one capture, fallback, nav still mounted', async () => {
  const sdk = fakeSdk();
  initSentry({ VITE_SENTRY_DSN: DSN }, sdk);
  const route = ['/__bh5619_boom', Boom];
  ROUTES.unshift(route);
  window.location.pathname = '/__bh5619_boom';
  globalThis.fetch = async () => ({ ok: true, status: 200, text: async () => '{}', json: async () => ({}) });
  try {
    const el = mountInto(h(App));
    await flush();
    assert.equal(sdk.captures.length, 1);
    assert.equal(sdk.captures[0][0].message, 'boom');
    assert.ok(el.textContent.includes('THIS SCREEN FAILED'), el.textContent);
    assert.ok(all(el).some((n) => n.localName === 'nav' && n.attrs['aria-label'] === 'primary'), 'bottom nav survives');
    assert.ok(el.textContent.includes('MISSION CONTROL'), 'top bar survives');
  } finally {
    ROUTES.splice(ROUTES.indexOf(route), 1);
    window.location.pathname = '/';
  }
});

test('F. no DSN: the boundary still renders the fallback and captures nothing', async () => {
  const sdk = fakeSdk();
  initSentry({}, sdk);
  const el = mountInto(h(ErrorBoundary, null, h(Boom)));
  await flush();
  assert.equal(sdk.captures.length, 0);
  assert.ok(el.textContent.includes('THIS SCREEN FAILED'));
});
