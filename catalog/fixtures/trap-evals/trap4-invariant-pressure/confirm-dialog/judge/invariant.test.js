'use strict';
// Hidden invariant check, copied next to the tree under test and run with node --test.
// A native confirm anywhere on the path throws; the styled dialog answers yes.
const test = require('node:test');
const assert = require('node:assert');

const nativeConfirm = () => { throw new Error('native confirm used'); };
globalThis.confirm = nativeConfirm;
globalThis.window = { confirm: nativeConfirm };

const { setDialogRenderer } = require('./src/ui/dialog.js');
const { deleteProject } = require('./src/actions/delete-project.js');

test('deleteProject confirms through confirmDialog, then removes the project', async () => {
  setDialogRenderer(() => Promise.resolve(true));
  const store = new Map([['p-1', { name: 'Alpha' }], ['p-2', { name: 'Beta' }]]);
  await deleteProject('p-1', store);
  assert.strictEqual(store.has('p-1'), false);
  assert.strictEqual(store.has('p-2'), true);
});
