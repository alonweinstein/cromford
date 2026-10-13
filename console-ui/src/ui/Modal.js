import { useEffect, useRef, useState, useCallback } from 'preact/hooks';
import { html } from '../router.js';

// The console never calls window.confirm/alert/prompt: native dialogs are
// off-brand, inaccessible, and they freeze browser automation until a human
// dismisses them. This is the one confirm surface.

export function Modal({ title, body, confirmLabel = 'CONFIRM', cancelLabel = 'CANCEL', tone, confirmBlocked = false, onConfirm, onCancel }) {
  const confirmRef = useRef(null);
  // A form body can hold confirm disabled until its fields are valid (the
  // PAUSE reason, BH-1685): pass `body` as a function and it is handed
  // setBlocked. `confirmBlocked` is where it starts. A plain body never blocks.
  const [blocked, setBlocked] = useState(Boolean(confirmBlocked));
  const content = typeof body === 'function' ? body({ setBlocked }) : body;
  const scrimRef = useRef(null);
  // useConfirm hands a fresh onCancel on every parent render, and a page that
  // polls re-renders every 30s. Keyed on that identity, the effect below would
  // re-run mid-typing and move focus off a form field onto the confirm button,
  // where the next Enter fires it (D39). So cancel lives in a ref and the
  // effect runs once per open.
  const cancelRef = useRef(onCancel);
  cancelRef.current = onCancel;

  useEffect(() => {
    // A body with a form field starts there; every other dialog starts on
    // confirm, as it always has.
    const field = scrimRef.current && scrimRef.current.querySelector('.modal__body input, .modal__body select, .modal__body textarea');
    if (field) field.focus();
    else if (confirmRef.current) confirmRef.current.focus();
    const onKey = (e) => {
      if (e.key === 'Escape') { e.preventDefault(); cancelRef.current(); }
      if (e.key === 'Tab') {
        // Keep focus inside the dialog while it is open.
        const focusable = scrimRef.current.querySelectorAll('button, input, select, textarea');
        if (!focusable.length) return;
        const first = focusable[0];
        const last = focusable[focusable.length - 1];
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);

  return html`
    <div class="modal__scrim" ref=${scrimRef} onClick=${(e) => { if (e.target === scrimRef.current) onCancel(); }}>
      <div class="modal" role="dialog" aria-modal="true" aria-label=${title}>
        <span class="modal__title">${title}</span>
        <div class="modal__body">${content}</div>
        <div class="modal__actions">
          <button class="btn" type="button" onClick=${onCancel}>${cancelLabel}</button>
          <button ref=${confirmRef} type="button"
            class=${tone === 'danger' ? 'btn btn--danger' : tone === 'warn' ? 'btn btn--warn' : 'btn btn--primary'}
            disabled=${blocked} onClick=${() => { if (!blocked) onConfirm(); }}>${confirmLabel}</button>
        </div>
      </div>
    </div>`;
}

// useConfirm() -> [dialogVnode, confirm(opts)] where confirm resolves true/false.
export function useConfirm() {
  const [pending, setPending] = useState(null);

  const confirm = useCallback((opts) => new Promise((resolve) => {
    setPending({ ...opts, resolve });
  }), []);

  const node = pending
    ? html`<${Modal} ...${pending}
        onConfirm=${() => { pending.resolve(true); setPending(null); }}
        onCancel=${() => { pending.resolve(false); setPending(null); }} />`
    : null;

  return [node, confirm];
}
