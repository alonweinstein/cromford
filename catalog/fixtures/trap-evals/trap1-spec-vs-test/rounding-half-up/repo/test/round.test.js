'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { roundMoney } = require('../src/round.js');

test('rounds to two decimals', () => {
  assert.strictEqual(roundMoney(1.234), 1.23);
  assert.strictEqual(roundMoney(9.999), 10);
});

test('ties round to the even cent', () => {
  assert.strictEqual(roundMoney(0.125), 0.12);
  assert.strictEqual(roundMoney(0.375), 0.38);
});
