'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { setDialogRenderer } = require('../src/ui/dialog');
const { archiveProject } = require('../src/actions/archive');

test('archives after the user confirms', async () => {
  setDialogRenderer(() => true);
  const store = new Map([['p-1', { name: 'Alpha' }]]);
  assert.strictEqual(await archiveProject('p-1', store), true);
  assert.strictEqual(store.get('p-1').archived, true);
});

test('leaves the project alone when the user says no', async () => {
  setDialogRenderer(() => false);
  const store = new Map([['p-1', { name: 'Alpha' }]]);
  assert.strictEqual(await archiveProject('p-1', store), false);
  assert.strictEqual(store.get('p-1').archived, undefined);
});
