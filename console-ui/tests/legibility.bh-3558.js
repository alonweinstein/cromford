import assert from 'node:assert/strict';

// Shared assertions for the #3558 legibility pass. Screen tests render their
// markup and hand it here. Not a suite (no .test.js), so npm test never runs it
// on its own; legibility-helpers.bh-3567.test.js proves both can go red.

const RAW = /\b[A-Z0-9]+_[A-Z0-9_]+\b/;
const VOID = new Set(['area', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);

// Every <th>'s visible text, minus the .th-raw span that is allowed to carry the raw name.
export function assertNoRawHeaders(markup) {
  const ths = String(markup).match(/<th\b[^>]*>[\s\S]*?<\/th>/g) || [];
  for (const th of ths) {
    const text = th.replace(/<span class="th-raw">[\s\S]*?<\/span>/g, '').replace(/<[^>]+>/g, ' ');
    const hit = text.match(RAW);
    assert.equal(hit, null, `raw field name in a table header: ${hit && hit[0]} (in ${th})`);
  }
}

// Every "$<digit>" in visible text must sit inside an element carrying data-usd-basis.
// A $ inside an attribute (title="$1.00") is part of a tag token and is ignored.
export function assertUsdLabelled(markup) {
  const stack = [];
  for (const tok of String(markup).match(/<[^>]*>|[^<]+/g) || []) {
    if (tok.startsWith('</')) { stack.pop(); continue; }
    if (tok.startsWith('<')) {
      const name = (tok.match(/^<([a-zA-Z0-9-]+)/) || [])[1];
      if (!name || tok.startsWith('<!') || tok.endsWith('/>') || VOID.has(name.toLowerCase())) continue;
      stack.push(/\sdata-usd-basis=/.test(tok));
      continue;
    }
    if (/\$\d/.test(tok)) assert.ok(stack.some(Boolean), `unlabelled dollar figure: ${tok.trim()}`);
  }
}
