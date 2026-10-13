import { html } from '../router.js';

// The HELD tag a ticket card shows (BH-2326), fed a holdFromLedger() result.
// Nothing renders unless the ledger says held; a missing actor, time or reason
// reads "unknown", never a guess.
export const HeldTag = ({ held, by, at, why }) => held
  ? html`<span class="tag tag--warn" title=${`Held by ${by ?? 'unknown'} at ${at ?? 'unknown'}: ${why ?? 'no reason recorded'} (as recorded by Mission Control)`}>HELD</span>`
  : null;
