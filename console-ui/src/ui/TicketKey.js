// A ticket key, linked to its ticket page (BH-4991, BH-4947 wave 2). The one
// component every screen uses to print a key, so /t/<KEY> is built in one
// place: ticketPath in src/lib/line.js. No key renders as a dash, or as the
// caller's fallback text, never as a link to nowhere.
// alt {to, label}: a second, smaller link after the key, so a cell that used to
// open the build or the PR still does (BH-4991 changes only how the key renders).

import { html, Link } from '../router.js';
import { ticketPath } from '../lib/line.js';

export function TicketKey({ k, cls = '', fallback = null, title, alt = null }) {
  if (typeof k !== 'string' || !k.trim()) {
    if (fallback && alt && alt.to) return html`<${Link} to=${alt.to} class=${cls || undefined}>${fallback}<//>`;
    return fallback ? html`<span>${fallback}</span>` : html`<span class="na">—</span>`;
  }
  const key = html`<${Link} to=${ticketPath(k)} class=${cls ? `tk ${cls}` : 'tk'} title=${title}>${k}<//>`;
  if (!alt || !alt.to) return key;
  return html`<span class="tk-pair">${key}<${Link} to=${alt.to} class="tk-alt">${alt.label || 'open'}<//></span>`;
}
