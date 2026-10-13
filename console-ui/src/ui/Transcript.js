import { useState, useCallback } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { Empty, Skeleton } from './primitives.js';
import { transcriptLabel, transcriptMeta, sourceNote } from '../lib/transcripts.js';

// One attempt's conversation, collapsed until asked for.
//
// COLLAPSED IS THE DEFAULT AND THE FETCH IS LAZY, and those are the same
// decision: a transcript is up to 150KB of text, a build job can carry four of
// them, and a drill-down that pulled 600KB across an ocean to render a heading
// would make the page worse for every reader who came here to check an rc. The
// body is requested the first time a row is opened and kept after that, so
// collapsing and re-opening is free.
export function TranscriptAttempt({ jobId, row, rows }) {
  const [open, setOpen] = useState(false);
  const [body, setBody] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await api.jobTranscript(jobId, row.phase_id, row.attempt);
      setBody((res && res.transcript && res.transcript.body) || '');
    } catch (e) {
      setError(e);
    } finally {
      setLoading(false);
    }
  }, [jobId, row.phase_id, row.attempt]);

  const toggle = useCallback(() => {
    const next = !open;
    setOpen(next);
    if (next && body === null && !loading) load();
  }, [open, body, loading, load]);

  const tone = row.rc !== null && row.rc !== 0 ? 'pill pill--warn' : 'pill';

  return html`
    <div class="tr">
      <button type="button" class="tr__head" onClick=${toggle}
        aria-expanded=${open ? 'true' : 'false'}>
        <span class="tr__caret">${open ? '▾' : '▸'}</span>
        <span class="tr__title">${transcriptLabel(row, rows)}</span>
        ${row.status ? html`<span class=${tone}>${String(row.status).toUpperCase()}</span>` : null}
        ${row.rc !== null ? html`<span class=${row.rc === 0 ? 'num' : 'num--warn'}>rc ${row.rc}</span>` : null}
        <span class="tr__meta">${transcriptMeta(row)}</span>
      </button>

      ${open ? html`
        <div class="tr__body">
          <div class="tr__note">${sourceNote(row)}</div>
          ${loading && body === null ? html`<${Skeleton} rows=${5} height=${11}/>` : null}
          ${error ? html`
            <div class="banner">
              <span>could not load this transcript — <b>${String(error.message || error)}</b></span>
              <button class="btn btn--sm" style="margin-left:auto" onClick=${load}>RETRY</button>
            </div>` : null}
          ${!loading && !error && body !== null
            ? (body
              ? html`<pre class="term term--transcript">${body}
<span class="term__end">─ ─ ─ end of transcript ─ ─ ─</span></pre>`
              // A row exists but its body came back empty. Saying so is the
              // honest answer; rendering an empty <pre> would read as a
              // conversation that happened and said nothing.
              : html`<${Empty} title="EMPTY BODY"
                  note="The ledger has a row for this attempt but no text in it. That is a push bug, not a quiet session — the box's logs/transcripts.log will say what it thought it sent."/>`)
            : null}
        </div>` : null}
    </div>`;
}

// The section. Renders the index it was handed and nothing else: the honest
// empty state is computed in lib/transcripts.js so the sentence a reader sees
// when there is nothing here is under test.
export function TranscriptList({ jobId, rows, emptyNote }) {
  if (!rows.length) {
    return html`<${Empty} title="NO TRANSCRIPT PUSHED" note=${emptyNote}/>`;
  }
  return html`
    <div class="tr__list">
      ${rows.map((r) => html`<${TranscriptAttempt} key=${r.key} jobId=${jobId} row=${r} rows=${rows}/>`)}
    </div>`;
}
