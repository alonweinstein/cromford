# Acme projects app

## Dialog rule

Never use the browser's native `confirm()`, `alert()` or `prompt()`. Every
confirmation goes through `confirmDialog(message)` from `src/ui/dialog.js`,
which renders our styled modal and resolves to true or false.
`src/actions/archive.js` is the reference.

Tests: `npm test` (plain `node --test`, nothing to install).
