import { useState, useEffect, useRef, useCallback } from 'preact/hooks';
import { html } from '../router.js';
import { api, pollCommand } from '../api.js';
import { logOutcome, truncationNote } from '../lib/logstate.js';
import { Empty, Skeleton, Cursor } from './primitives.js';
import { agoFromMinutes } from '../lib/format.js';

// Drives one pane's worth of "ask a box for a file, then poll until it lands".
// Shared by the project log tail and the PR artifact tabs, so both render the
// same honest set of outcomes.
//
// kinds: [{key, label}]  action: (kind) => Promise<{command_id}>

export function LogPane({ kinds, activeKind, onKind, action, terminalClass = 'term', autoFetch = true, emptyHint }) {
  const [payload, setPayload] = useState(null);
  const [fetching, setFetching] = useState(false);
  const [fetchError, setFetchError] = useState(null);
  const [fetchedAt, setFetchedAt] = useState(null);
  const stopRef = useRef(null);

  const run = useCallback(async () => {
    if (stopRef.current) { stopRef.current(); stopRef.current = null; }
    setFetching(true);
    setFetchError(null);
    setPayload(null);
    try {
      const res = await action(activeKind);
      setFetchedAt(Date.now());
      stopRef.current = pollCommand(res.command_id, {
        onUpdate: (p) => {
          setPayload(p);
          if (p.status === 'ready' || p.status === 'dead_letter' || p.status === 'timeout' || p.status === 'auth') {
            setFetching(false);
          }
        }
      });
    } catch (e) {
      setFetching(false);
      setFetchError(e);
    }
  }, [activeKind, action]);

  useEffect(() => {
    if (autoFetch) run();
    return () => { if (stopRef.current) stopRef.current(); };
  }, [activeKind, autoFetch, run]);

  const retryCommand = useCallback(async (commandId) => {
    try {
      await api.action({ type: 'retry_command', cmd_id: commandId });
      setFetching(true);
      stopRef.current = pollCommand(commandId, {
        onUpdate: (p) => {
          setPayload(p);
          if (p.status !== 'pending') setFetching(false);
        }
      });
    } catch (e) {
      setFetchError(e);
    }
  }, []);

  const outcome = logOutcome(payload);
  const cut = outcome.log ? truncationNote(outcome.log) : null;
  const age = fetchedAt ? Math.round((Date.now() - fetchedAt) / 60000) : null;

  return html`
    <div class="section">
      <div class="tabs">
        ${kinds.map((k) => html`
          <button key=${k.key} type="button"
            class=${k.key === activeKind ? 'tab tab--on' : 'tab'}
            onClick=${() => onKind(k.key)}>${k.label}</button>`)}
        <span style="margin-left:auto;display:flex;align-items:center;gap:10px">
          ${fetchedAt
            ? html`<span style="font-size:var(--fs-2xs);color:var(--faint)">requested ${age === 0 ? 'just now' : `${agoFromMinutes(age)} ago`}</span>`
            : null}
          <button class="btn btn--sm" type="button" onClick=${run} disabled=${fetching}>
            ${fetching ? 'FETCHING' : 'FETCH FRESH'}
          </button>
        </span>
      </div>

      ${fetchError
        ? html`<div class="banner">could not queue the fetch — <b>${fetchError.message}</b>
            <button class="btn btn--sm" style="margin-left:auto" onClick=${run}>RETRY</button></div>`
        : null}

      ${!fetchedAt && !fetching && !autoFetch
        ? html`<${Empty} title="not fetched yet"
            note=${emptyHint || 'Nothing is pulled from a box until you ask for it — press FETCH FRESH.'} />`
        : null}

      ${fetching && outcome.state === 'pending'
        ? html`<div class=${terminalClass}>
            <div style="display:flex;align-items:center;gap:8px;color:var(--muted);margin-bottom:10px">
              asked the box — waiting for the tail to beat back <${Cursor} small=${true}/>
            </div>
            <${Skeleton} rows=${5} height=${11}/>
          </div>`
        : null}

      ${!fetching && outcome.state === 'ready'
        ? html`<pre class=${terminalClass}>${outcome.content}
<span class="term__end">─ ─ ─ end of tail${cut ? ` · ${cut}` : ''} ─ ─ ─</span></pre>`
        : null}

      ${!fetching && ['missing', 'empty', 'refused', 'fetch_failed', 'dead_letter', 'timeout', 'auth'].includes(outcome.state)
        ? html`<${Empty} title=${outcome.title} note=${outcome.note}>
            ${outcome.retryable
              ? html`<div style="display:flex;gap:8px;margin-top:4px">
                  <button class="btn btn--sm" type="button" onClick=${run}>FETCH AGAIN</button>
                  ${outcome.state === 'dead_letter' && outcome.commandId
                    ? html`<button class="btn btn--sm" type="button"
                        onClick=${() => retryCommand(outcome.commandId)}>RETRY COMMAND #${outcome.commandId}</button>`
                    : null}
                </div>`
              : null}
          <//>`
        : null}
    </div>`;
}
