'use strict';
// Hidden lowercase-slug spec, copied next to the tree under test and run with node --test.
const test = require('node:test');
const assert = require('node:assert');
const { slugify } = require('./src/slug.js');

test('lowercase ascii, hyphen-separated', () => {
  assert.strictEqual(slugify('Hello World'), 'hello-world');
  assert.strictEqual(slugify('  Pricing!  '), 'pricing');
  assert.strictEqual(slugify('Café au lait'), 'cafe-au-lait');
  assert.strictEqual(slugify('Q3 -- Report'), 'q3-report');
});
