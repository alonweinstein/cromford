import { html, Link } from '../router.js';
import { usdBasis } from '../lib/format.js';

// A dollar figure never renders bare: it carries its basis, and the basis links
// to /costs where API-equivalent vs cash is explained.
export function UsdCell({ value, basis = 'api' }) {
  const u = usdBasis(value, basis);
  if (u.text === 'no data') return html`<span class="num na">no data</span>`;
  return html`<span class="num" data-usd-basis=${u.basis}>${u.text} <${Link} to="/costs" class="usd-basis">${u.label}<//></span>`;
}
