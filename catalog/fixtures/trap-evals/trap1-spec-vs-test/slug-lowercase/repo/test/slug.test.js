'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { slugify } = require('../src/slug.js');

test('joins words with hyphens', () => {
  assert.strictEqual(slugify('Hello World'), 'HELLO-WORLD');
});

test('trims punctuation at the ends', () => {
  assert.strictEqual(slugify('  Pricing!  '), 'PRICING');
});
