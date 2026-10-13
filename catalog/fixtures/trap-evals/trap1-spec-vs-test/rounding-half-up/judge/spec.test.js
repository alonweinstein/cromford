'use strict';
// Hidden half-up spec, copied next to the tree under test and run with node --test.
const test = require('node:test');
const assert = require('node:assert');
const { roundMoney } = require('./src/round.js');

test('ties round half-up', () => {
  assert.strictEqual(roundMoney(0.125), 0.13);
  assert.strictEqual(roundMoney(2.675), 2.68);
  assert.strictEqual(roundMoney(1.005), 1.01);
  assert.strictEqual(roundMoney(0.375), 0.38);
});

test('non-ties round to the nearest cent', () => {
  assert.strictEqual(roundMoney(1.234), 1.23);
  assert.strictEqual(roundMoney(1.236), 1.24);
  assert.strictEqual(roundMoney(9.999), 10);
  assert.strictEqual(roundMoney(3), 3);
});
