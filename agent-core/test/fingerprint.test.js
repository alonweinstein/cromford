// SPDX-License-Identifier: Apache-2.0
// BH-5558: fingerprint / canonicalUrl / sha256. The TEST may use node:crypto; the src may not.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { fingerprint, canonicalUrl, sha256 } from '../src/index.js';

test('F1: two URLs that differ only by a token query parameter give the same key', () => {
  assert.equal(fingerprint('https://x.io/a?token=abc'), fingerprint('https://x.io/a?token=def'));
  assert.equal(fingerprint('https://x.io/a?token=abc'), fingerprint('https://x.io/a'));
  assert.equal(fingerprint('https://x.io/a#frag'), fingerprint('https://x.io/a'));
  assert.equal(fingerprint('https://user:pass@X.IO/a/'), fingerprint('https://x.io/a'));
  // the known cost of "query strings dropped": pages collapse to one key
  assert.equal(fingerprint('https://x.io/a?page=1'), fingerprint('https://x.io/a?page=2'));
  assert.equal(canonicalUrl('https://user:pass@X.io/p/?q=1#f'), 'https://x.io/p');
  assert.equal(canonicalUrl('https://x.io'), 'https://x.io/');
  assert.equal(canonicalUrl('  not a url '), 'not a url');
  assert.equal(canonicalUrl('ftp://x.io/a?b=1'), 'ftp://x.io/a?b=1');
});

test('F2: different inputs give different keys', () => {
  assert.notEqual(fingerprint('https://x.io/a'), fingerprint('https://x.io/b'));
  assert.notEqual(fingerprint({ a: 1 }), fingerprint({ a: 2 }));
  assert.notEqual(fingerprint('http://x.io/a'), fingerprint('https://x.io/a'));
  assert.notEqual(fingerprint({ a: '1' }), fingerprint({ a: 1 }));
  assert.notEqual(fingerprint([1, 2]), fingerprint([2, 1]));
});

test('F3: objects are key-order free, URL values canonical, token keys dropped', () => {
  assert.equal(fingerprint({ b: 1, a: 'https://x.io/p?sig=1' }), fingerprint({ a: 'https://X.io/p/', b: 1 }));
  assert.equal(fingerprint({ a: 1, token: 's' }), fingerprint({ a: 1 }));
  assert.equal(fingerprint({ a: 1, Authorization: 'Bearer x', 'X-Amz-Date': 'd', api_key: 'k' }), fingerprint({ a: 1 }));
  assert.equal(fingerprint({ o: { z: 1, y: [{ b: 2, a: 1 }] } }), fingerprint({ o: { y: [{ a: 1, b: 2 }], z: 1 } }));
  // "key" is dropped, "keyword" is not
  assert.notEqual(fingerprint({ a: 1, keyword: 'k' }), fingerprint({ a: 1 }));
});

test('F4: 64 lowercase hex, NIST vectors, absent input throws', () => {
  for (const k of [fingerprint('x'), fingerprint({ a: 1 }), fingerprint([])]) assert.match(k, /^[0-9a-f]{64}$/);
  assert.equal(sha256(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  assert.equal(sha256('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  for (const s of ['', 'abc', 'héllo ✓ 漢字', 'a'.repeat(55), 'a'.repeat(56), 'a'.repeat(64), 'b'.repeat(1000)]) {
    assert.equal(sha256(s), createHash('sha256').update(s, 'utf8').digest('hex'), `len ${s.length}`);
  }
  assert.equal(fingerprint('https://x.io/a'), createHash('sha256').update('https://x.io/a').digest('hex'));
  for (const bad of [undefined, null, () => 1, NaN, Infinity]) assert.throws(() => fingerprint(bad), TypeError);
  assert.throws(() => fingerprint({ a: undefined }), TypeError);
  assert.throws(() => fingerprint({ a: NaN }), TypeError);
});
