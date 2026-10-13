// SPDX-License-Identifier: Apache-2.0
// Learning: an agent's own output is never its input; precision of its calls.

const norm = (s) => (typeof s === 'string' ? s.trim().toLowerCase() : '');

export function isOwnOutput(finding, agent) {
  const me = norm(agent);
  const source = finding && finding.source;
  if (!me || !source) return false;
  if (Array.isArray(source.labels) && source.labels.some((l) => norm(l) === `staff:${me}`)) return true;
  return norm(source.filedBy) === me;
}

// agree / (agree + overrule). null when nothing was counted: absent is not zero.
export function precision(outcomes) {
  if (!Array.isArray(outcomes)) return null;
  let agree = 0, overrule = 0;
  for (const o of outcomes) {
    if (o && o.verdict === 'agree') agree++;
    else if (o && o.verdict === 'overrule') overrule++;
  }
  return agree + overrule === 0 ? null : agree / (agree + overrule);
}
