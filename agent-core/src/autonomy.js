// SPDX-License-Identifier: Apache-2.0
// Autonomy: three levels, earned per action class, capped per class.

export const LEVELS = Object.freeze(['automation', 'augmentation', 'autonomy']);

const rank = (level) => LEVELS.indexOf(level);
const norm = (s) => s.toLowerCase().replace(/`/g, '').replace(/\s+/g, ' ').trim().replace(/\.$/, '').trim();

// decide returns 'allow', 'ask' or 'refuse'. Any input it cannot read refuses.
export function decide(level, cap, action) {
  if (rank(level) < 0 || rank(cap) < 0) return 'refuse';
  if (!action || typeof action.name !== 'string' || action.name.trim() === '' || !Array.isArray(action.never)) return 'refuse';
  const name = norm(action.name);
  if (action.never.some((entry) => typeof entry === 'string' && norm(entry) === name)) return 'refuse';
  if (rank(level) > rank(cap)) return 'refuse';
  if (level === 'automation') return 'refuse';
  if (level === 'augmentation') return 'ask';
  return 'allow';
}

// nextLevel: an overrule demotes one level (floor automation). A delegate that
// follows rule.agreementsToPromote agreements in a row promotes one level, never
// above rule.cap. Anything else, and any input it cannot read, keeps the level.
export function nextLevel(level, history, rule) {
  const r = rank(level);
  if (r < 0 || !Array.isArray(history) || history.length === 0) return level;
  const last = history[history.length - 1];
  const verdict = last && last.verdict;
  if (verdict === 'overrule') return LEVELS[Math.max(0, r - 1)];
  if (verdict !== 'delegate') return level;
  const n = rule && rule.agreementsToPromote;
  if (!Number.isInteger(n) || n < 1 || rank(rule.cap) < 0) return level;
  const before = history.slice(0, -1);
  if (before.length < n) return level;
  if (!before.slice(-n).every((h) => h && h.verdict === 'agree')) return level;
  if (r + 1 > rank(rule.cap)) return level;
  return LEVELS[r + 1];
}
