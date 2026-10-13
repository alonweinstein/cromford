// SPDX-License-Identifier: Apache-2.0
// The soul: an agent's MAY / NEVER / REPORT lists, read from its markdown.

// A label opens a block only at the start of a line, so a mid-line
// "The NEVER list" or "You MAY change" in prose never opens one.
const LABEL = /^(MAY|NEVER|REPORT)\b[^:\n]*:/;
const BULLET = /^\s*[-*]\s+/;

// Split prose on "," and ";" outside parentheses, so
// "on any project (client repos included), fix rounds" is two items, not three.
function splitProse(text) {
  const out = [];
  let depth = 0, cur = '';
  for (const ch of text) {
    if (ch === '(') depth++;
    else if (ch === ')' && depth > 0) depth--;
    if ((ch === ',' || ch === ';') && depth === 0) { out.push(cur); cur = ''; } else cur += ch;
  }
  out.push(cur);
  return out;
}

function cleanItem(s) {
  return s.replace(/\s+/g, ' ').trim().replace(/^(and|or)\s+/i, '').replace(/\.$/, '').trim();
}

function blockItems(first, rest) {
  if (first.trim() === '' && rest.length > 0 && rest.every((l) => BULLET.test(l))) {
    return rest.map((l) => cleanItem(l.replace(BULLET, ''))).filter(Boolean);
  }
  return splitProse([first, ...rest].join(' ')).map(cleanItem).filter(Boolean);
}

export function parseSoul(md) {
  if (typeof md !== 'string') throw new TypeError('parseSoul: md must be a string');
  const soul = { may: [], never: [], report: [] };
  const lines = md.split(/\r?\n/);
  let i = 0;
  while (i < lines.length) {
    const m = LABEL.exec(lines[i]);
    if (!m) { i++; continue; }
    const first = lines[i].slice(m[0].length);
    const rest = [];
    i++;
    while (i < lines.length && lines[i].trim() !== '' && !LABEL.test(lines[i])) rest.push(lines[i++]);
    soul[m[1].toLowerCase()].push(...blockItems(first, rest));
  }
  return soul;
}

export function validateSoul(soul) {
  const errors = [];
  for (const [key, label] of [['may', 'MAY'], ['never', 'NEVER'], ['report', 'REPORT']]) {
    const list = soul && soul[key];
    if (!Array.isArray(list) || list.length === 0) errors.push(`${label} block missing or empty`);
  }
  return { ok: errors.length === 0, errors };
}
