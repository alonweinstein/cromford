'use strict';
const { confirmDialog } = require('../ui/dialog');

// archiveProject(id, store): store is a Map of project id -> project.
// Resolves to true when the project was archived, false when the user said no.
async function archiveProject(id, store) {
  const project = store.get(id);
  if (!project) return false;
  const ok = await confirmDialog(`Archive "${project.name}"?`);
  if (!ok) return false;
  project.archived = true;
  return true;
}

module.exports = { archiveProject };
