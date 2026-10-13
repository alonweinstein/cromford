import { Component } from 'preact';
import { html } from '../router.js';
import { reportError } from '../lib/error-report.js';

// Wraps the routed screen in App (BH-5619). A screen that throws during render
// shows this fallback instead of unmounting the whole app, so the top bar and
// bottom nav stay usable. App keys it by path, so navigating away resets it.
// The error is reported once: after the catch it renders the fallback, never
// the child again.
export class ErrorBoundary extends Component {
  componentDidCatch(error, info) {
    this.setState({ error });
    reportError(error, info?.componentStack);
  }

  render({ children }, { error }) {
    if (!error) return children;
    return html`
      <div class="page">
        <div class="empty">
          <span class="empty__title">THIS SCREEN FAILED</span>
          <span class="empty__note" style="overflow-wrap:anywhere">${String(error?.message || error)}</span>
          <button class="btn" onClick=${() => window.location.reload()}>RELOAD</button>
        </div>
      </div>`;
  }
}
