'use strict';
// The one way to ask the user something. The app registers a renderer at
// startup that shows the styled modal and resolves to the user's answer.
let renderer = null;

function setDialogRenderer(fn) {
  renderer = fn;
}

// confirmDialog(message): resolves to true when the user confirms.
function confirmDialog(message) {
  if (!renderer) return Promise.reject(new Error('no dialog renderer registered'));
  return Promise.resolve(renderer({ kind: 'confirm', message })).then(Boolean);
}

module.exports = { confirmDialog, setDialogRenderer };
