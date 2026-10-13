import { useState, useEffect, useRef, useCallback } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useConfirm } from '../ui/Modal.js';
import { BUILTIN_THEMES, THEME_ORDER, DEFAULT_THEME_ID } from '../theme/themes.js';
import { resolveTheme } from '../theme/resolve.js';
import {
  applyTheme, readViewerPick, writeViewerPick, readFleetCache, syncFleetDefault, FLEET_SETTING_KEY,
  readThemeCache, writeThemeCache, themeFor, isCustomId
} from '../theme/apply.js';
import {
  CUSTOM_PREFIX, docFromTheme, exportTheme, importTheme, slugify, validateThemeDoc
} from '../theme/custom.js';
import { ThemeEditorView } from './ThemeEditor.js';

// APPEARANCE (BH-4844): pick this browser's theme. One live preview per
// built-in theme, side by side whatever theme the page is in: each card's
// wrapper carries that theme's tokens inline, and everything inside reads only
// semantic or extended tokens straight off it. (A legacy alias like --bg or
// --green resolves once at :root, so inside a card it would show the PAGE's
// theme, not the card's.)
//
// BH-4846: custom themes. NEW THEME FROM opens the editor (ThemeEditor.js)
// inline; SAVE writes the settings row ui.theme.custom.<slug>, which the coord
// proxy validates and stamps with who saved it. Saved themes are cards for
// every viewer, read from GET /api/coord/settings. EXPORT and IMPORT move a
// theme as a JSON file through the same validator. DELETE asks first. SET AS
// FLEET DEFAULT shows only for a verified Access identity (whoami 'on').

const BLURB = {
  mill: 'Warm ink and brick. Mill is the default.',
  paper: 'Warm paper and dark ink, for daylight.',
  phosphor: 'The original green terminal look.'
};

const FLEET_ROW = `/config/setting/${FLEET_SETTING_KEY}`;
const tokenStyle = (tokens) => Object.entries(tokens).map(([k, v]) => `${k}:${v}`).join(';');
const customOf = (id, customs) => (customs && customs.themes || []).find((t) => t.id === id) || null;
function nameOf(id, customs) {
  if (BUILTIN_THEMES[id]) return BUILTIN_THEMES[id].name;
  const c = customOf(id, customs);
  return c ? c.theme.name : BUILTIN_THEMES[DEFAULT_THEME_ID].name;
}

function FleetLine({ fleet, customs }) {
  const link = (id) => html`<${Link} to=${FLEET_ROW} class="theme-fleet__link">${nameOf(id, customs)}<//>`;
  if (fleet.state === 'loading') return html`<span>Checking the settings row for the fleet default…</span>`;
  if (fleet.state === 'error') {
    const why = (fleet.error && fleet.error.message) || 'unknown error';
    return html`<span>Couldn't read the settings row (${why}). Using ${fleet.id ? html`${nameOf(fleet.id, customs)}, from this browser's last read` : nameOf(DEFAULT_THEME_ID)} as the fleet default for now. <${Link} to=${FLEET_ROW} class="theme-fleet__link">Open the row<//></span>`;
  }
  if (!fleet.hasRow) return html`<span>Fleet default: ${link(DEFAULT_THEME_ID)} (no row)</span>`;
  if (!fleet.id) return html`<span>Fleet default: ${link(DEFAULT_THEME_ID)} (the settings row says "${String(fleet.raw)}", which is not a theme)</span>`;
  if (isCustomId(fleet.id) && !customOf(fleet.id, customs)) {
    if (customs.state === 'ok') return html`<span>Fleet default: ${link(DEFAULT_THEME_ID)} (the settings row names ${fleet.id}, and no saved theme has that id)</span>`;
    return html`<span>Fleet default: ${fleet.id} (settings row; the saved themes aren't read yet, so it isn't confirmed)</span>`;
  }
  return html`<span>Fleet default: ${link(fleet.id)} (settings row)</span>`;
}

function PreviewCard({ theme, active, blurb, savedBy, canSetFleet, isFleet, onPick, onFleetPick, onEdit, onExport, onDelete, busy }) {
  const custom = isCustomId(theme.id);
  return html`
    <section class=${`theme-card${active ? ' theme-card--on' : ''}`} data-theme-id=${theme.id} style=${tokenStyle(theme.tokens)}>
      <div class="theme-card__head">
        <span class="theme-card__name">${theme.name}</span>
        <span class="theme-card__dim">${custom ? `custom · ${theme.scheme}` : theme.scheme}</span>
        ${active ? html`<span class="theme-card__on">IN USE</span>` : null}
      </div>
      <p class="theme-card__text">${custom ? `A custom theme from ${nameOf(theme.base)}, saved by ${savedBy || 'an unknown actor'}.` : blurb}</p>
      <div class="theme-card__panel">
        <div class="theme-card__panel-head">BUILDING NOW</div>
        <div class="theme-card__row">
          <span class="theme-card__strong">board-a</span>
          <span class="theme-card__dim">sample build · 4m</span>
          <span class="theme-card__pill theme-card__pill--ok">MERGED</span>
        </div>
        <div class="theme-card__row">
          <span class="theme-card__strong">board-b</span>
          <span class="theme-card__dim">sample build · 12m</span>
          <span class="theme-card__pill theme-card__pill--warn">WAITING</span>
        </div>
      </div>
      <div class="theme-card__pills">
        <span class="theme-card__pill theme-card__pill--ok">OK</span>
        <span class="theme-card__pill theme-card__pill--warn">WARN</span>
        <span class="theme-card__pill theme-card__pill--err">ERR</span>
        <span class="theme-card__pill theme-card__pill--live">LIVE</span>
        <span class="theme-card__pill theme-card__pill--info">INFO</span>
      </div>
      <p class="theme-card__text">Body text, <span class="theme-card__accent">a link</span> and <span class="theme-card__dim">a quieter note</span>.</p>
      <button type="button" class="theme-card__use" data-theme-pick=${theme.id} aria-pressed=${String(active)}
        onClick=${() => onPick(theme.id)}>USE ${theme.name.toUpperCase()}</button>
      ${canSetFleet || custom ? html`
        <div class="theme-card__actions">
          ${canSetFleet ? html`<button type="button" class="btn btn--sm" data-fleet-pick=${theme.id} disabled=${isFleet || Boolean(busy)}
            onClick=${() => onFleetPick(theme.id)}>${isFleet ? 'FLEET DEFAULT' : 'SET AS FLEET DEFAULT'}</button>` : null}
          ${custom ? html`
            <button type="button" class="btn btn--sm" data-theme-edit=${theme.id} onClick=${() => onEdit(theme.id)}>EDIT</button>
            <button type="button" class="btn btn--sm" data-theme-export=${theme.id} onClick=${() => onExport(theme.id)}>EXPORT</button>
            <button type="button" class="btn btn--sm btn--danger" data-theme-delete=${theme.id} disabled=${Boolean(busy)}
              onClick=${() => onDelete(theme.id)}>DELETE THEME</button>` : null}
        </div>` : null}
    </section>`;
}

function CustomList({ customs, cardProps }) {
  if (customs.state === 'loading') return html`<p class="section__note">Reading custom themes…</p>`;
  if (customs.state === 'error') {
    const why = (customs.error && customs.error.message) || 'unknown error';
    return html`<p class="theme-fleet__warn">Couldn't read custom themes (${why}). Reload to try again.</p>`;
  }
  return html`
    ${customs.themes.length
      ? html`<div class="theme-grid">${customs.themes.map((c) => html`<${PreviewCard} key=${c.id} theme=${c.theme} savedBy=${c.actor} ...${cardProps(c.id)} />`)}</div>`
      : html`<p class="section__note">No custom themes yet. Start one from a built-in above.</p>`}
    ${customs.skipped.length ? html`
      <div class="theme-editor__warn">
        <span>These rows aren't valid themes, so they're not shown or painted:</span>
        <ul>${customs.skipped.map((s) => html`<li key=${s.key}><${Link} to=${`/config/setting/${s.key}`} class="theme-fleet__link">${s.key}<//>: ${s.errors.join('; ')}</li>`)}</ul>
      </div>` : null}`;
}

const noop = () => {};

export function AppearanceView({
  activeId, viewerId, fleet, saveFailed, onPick, onClearPick,
  customs = { state: 'ok', themes: [], skipped: [] }, canSetFleet = false, editor = null, notice = null,
  importErrors = null, busy = null, dialog = null,
  onNewFrom = noop, onImport = noop, onFleetPick = noop, onEdit = noop, onExport = noop, onDelete = noop,
  onEditorChange = noop, onEditorSave = noop, onEditorCancel = noop, onEditorExport = noop
}) {
  const fleetId = fleet.state === 'ok' && fleet.hasRow ? fleet.id : null;
  const cardProps = (id) => ({
    active: id === activeId, canSetFleet, isFleet: id === fleetId, busy,
    onPick, onFleetPick, onEdit, onExport, onDelete
  });
  return html`
    <div class="page">
      <${PageHeadline} chip="Appearance" line1="How Mission Control looks."
        line2="In this browser: a built-in theme, or one of your own."/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/settings" class="crumb">← SETTINGS<//>
        <span class="section__note">how Mission Control looks in this browser</span>
      </div>
      <div class="theme-fleet">
        <${FleetLine} fleet=${fleet} customs=${customs} />
        <span>
          ${viewerId
            ? html`Your pick: ${nameOf(viewerId, customs)}. It's saved in this browser only. <button type="button" class="btn btn--sm" onClick=${onClearPick}>USE THE FLEET DEFAULT</button>`
            : 'You haven\'t picked one, so this browser follows the fleet default.'}
        </span>
        ${saveFailed ? html`<span class="theme-fleet__warn">Couldn't save that in this browser, so it lasts until you reload.</span>` : null}
        ${notice ? html`<span class=${notice.tone === 'ok' ? '' : 'theme-fleet__warn'} role="status">${notice.text}</span>` : null}
      </div>
      <div class="theme-grid">
        ${THEME_ORDER.map((id) => html`<${PreviewCard} key=${id} theme=${BUILTIN_THEMES[id]} blurb=${BLURB[id]} ...${cardProps(id)} />`)}
      </div>
      <div class="theme-tools">
        <span class="section__title">CUSTOM THEMES</span>
        <label class="theme-tools__field">
          <span>New theme from…</span>
          <select data-new-from="1" value="" onChange=${(e) => { const id = e.target.value; e.target.value = ''; onNewFrom(id); }}>
            <option value="">pick a built-in</option>
            ${THEME_ORDER.map((id) => html`<option value=${id} key=${id}>${BUILTIN_THEMES[id].name}</option>`)}
          </select>
        </label>
        <label class="theme-tools__field">
          <span>Import a theme file</span>
          <input type="file" accept=".json,application/json" data-theme-import="1" onChange=${onImport} />
        </label>
      </div>
      ${importErrors ? html`
        <div class="theme-editor__warn" data-import-errors="1" role="alert">
          <span>That file isn't a theme this console can use:</span>
          <ul>${importErrors.map((e) => html`<li key=${e}>${e}</li>`)}</ul>
        </div>` : null}
      ${editor ? html`<${ThemeEditorView} doc=${editor.doc} saving=${editor.saving} saveError=${editor.error}
        onChange=${onEditorChange} onSave=${onEditorSave} onCancel=${onEditorCancel} onExport=${onEditorExport} />` : null}
      <${CustomList} customs=${customs} cardProps=${cardProps} />
      ${dialog}
    </div>`;
}

// A file download in the browser: an object URL on a throwaway link.
function download(filename, text) {
  const url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

export function AppearanceScreen() {
  const [viewerId, setViewerId] = useState(() => readViewerPick());
  const [fleet, setFleet] = useState(() => ({ state: 'loading', id: readFleetCache() }));
  const [customs, setCustoms] = useState({ state: 'loading', themes: [], skipped: [] });
  const [saveFailed, setSaveFailed] = useState(false);
  const [canSetFleet, setCanSetFleet] = useState(false);
  const [editor, setEditor] = useState(null);
  const [importErrors, setImportErrors] = useState(null);
  const [notice, setNotice] = useState(null);
  const [busy, setBusy] = useState(null);
  const [dialog, confirm] = useConfirm();
  // Request versioning: only the newest read lands, so a refresh after a
  // save can't be overwritten by an older one finishing late.
  const seq = useRef(0);
  const live = useRef(true);

  const refresh = useCallback(() => {
    const n = ++seq.current;
    return syncFleetDefault(api).then((r) => {
      if (!live.current || n !== seq.current) return;
      setFleet(r.ok
        ? { state: 'ok', id: r.fleet, hasRow: r.hasRow, raw: r.raw }
        : { state: 'error', id: readFleetCache(), error: r.error });
      const c = r.ok ? r.customs : { ok: false, error: r.error };
      setCustoms(c.ok
        ? { state: 'ok', themes: c.themes, skipped: c.skipped }
        : { state: 'error', themes: [], skipped: [], error: c.error });
    });
  }, []);

  useEffect(() => {
    live.current = true;
    refresh();
    api.whoami().then((w) => { if (live.current) setCanSetFleet(Boolean(w && w.access === 'on')); }, () => {});
    return () => { live.current = false; };
  }, []);

  // Until the rows are read, the cached custom theme stands in for the list.
  const cached = customs.state === 'ok' ? null : readThemeCache();
  const known = customs.state === 'ok' ? customs.themes : (cached ? [{ id: cached.id, theme: cached }] : []);
  const activeId = resolveTheme({ viewer: viewerId, fleet: fleet.id, customIds: known.map((t) => t.id) }).id;

  const onPick = (id) => {
    const theme = themeFor(id, known);
    setSaveFailed(!writeViewerPick(id));
    writeThemeCache(theme);
    applyTheme(document, theme);
    setViewerId(id);
  };
  const onClearPick = () => {
    setSaveFailed(!writeViewerPick(null));
    const theme = themeFor(resolveTheme({ viewer: null, fleet: fleet.id, customIds: known.map((t) => t.id) }).id, known);
    writeThemeCache(theme);
    applyTheme(document, theme);
    setViewerId(null);
  };

  const onNewFrom = (id) => {
    if (!BUILTIN_THEMES[id]) return;
    setImportErrors(null);
    setEditor({ doc: docFromTheme(BUILTIN_THEMES[id], `My ${BUILTIN_THEMES[id].name}`), slug: null, saving: false, error: null });
  };
  const onEdit = (id) => {
    const c = customOf(id, customs);
    if (c) setEditor({ doc: c.doc, slug: c.slug, saving: false, error: null });
  };
  const onImport = async (e) => {
    const input = e.target;
    const file = input.files && input.files[0];
    if (!file) return;
    // Cleared at once, so picking the same file again fires a change.
    input.value = '';
    let text;
    try { text = await file.text(); } catch (err) { setImportErrors([`couldn't read the file (${err.message || err})`]); return; }
    const r = importTheme(text);
    if (!r.ok) { setImportErrors(r.errors); return; }
    setImportErrors(null);
    setEditor({ doc: r.doc, slug: null, saving: false, error: null });
  };
  const onExport = (id) => {
    const c = customOf(id, customs);
    if (c) download(`${c.slug}.theme.json`, exportTheme(c.doc));
  };
  const onEditorExport = () => {
    const v = editor && validateThemeDoc(editor.doc);
    if (v && v.ok) download(`${slugify(v.doc.name)}.theme.json`, exportTheme(v.doc));
  };

  const onEditorSave = async () => {
    const v = validateThemeDoc(editor.doc);
    if (!v.ok) return;
    const slug = slugify(v.doc.name);
    const taken = customOf(`custom.${slug}`, customs);
    if (taken && slug !== editor.slug) {
      const ok = await confirm({
        title: 'Replace a saved theme',
        body: `"${taken.theme.name}" is already saved under that name. Saving replaces it for every viewer.`,
        confirmLabel: 'REPLACE', tone: 'warn'
      });
      if (!ok) return;
    }
    setEditor((ed) => ed && { ...ed, saving: true, error: null });
    try {
      await api.setCoordSetting({ key: CUSTOM_PREFIX + slug, value: exportTheme(v.doc) });
    } catch (err) {
      setEditor((ed) => ed && { ...ed, saving: false, error: err.message || String(err) });
      return;
    }
    setEditor(null);
    setNotice({ tone: 'ok', text: `Saved ${v.doc.name}. It's in every viewer's picker now.` });
    await refresh();
  };

  const onFleetPick = async (id) => {
    setBusy(id);
    try {
      await api.setCoordSetting({ key: FLEET_SETTING_KEY, value: id });
      setNotice({ tone: 'ok', text: `Fleet default set to ${nameOf(id, customs)}.` });
    } catch (err) {
      setNotice({ tone: 'warn', text: `Couldn't set the fleet default: ${err.message || err}` });
    } finally {
      setBusy(null);
    }
    await refresh();
  };

  const onDelete = async (id) => {
    const c = customOf(id, customs);
    if (!c) return;
    const isFleet = fleet.state === 'ok' && fleet.id === id;
    const ok = await confirm({
      title: `Delete ${c.theme.name}`,
      body: `This removes ${c.theme.name} for every viewer.${isFleet ? ' It is the fleet default, so the fleet falls back to Mill until someone picks another.' : ''} Anyone using it goes back to the fleet default.`,
      confirmLabel: 'DELETE', tone: 'danger'
    });
    if (!ok) return;
    setBusy(id);
    try {
      await api.deleteCoordSetting(CUSTOM_PREFIX + c.slug);
    } catch (err) {
      setNotice({ tone: 'warn', text: `Couldn't delete ${c.theme.name}: ${err.message || err}` });
      setBusy(null);
      return;
    }
    // The local pick is cleared only once the row is really gone.
    if (viewerId === id) { setSaveFailed(!writeViewerPick(null)); setViewerId(null); }
    setNotice({ tone: 'ok', text: `Deleted ${c.theme.name}.` });
    setBusy(null);
    await refresh();
  };

  return html`<${AppearanceView} activeId=${activeId} viewerId=${viewerId} fleet=${fleet}
    saveFailed=${saveFailed} onPick=${onPick} onClearPick=${onClearPick}
    customs=${customs} canSetFleet=${canSetFleet} editor=${editor} notice=${notice} importErrors=${importErrors}
    busy=${busy} dialog=${dialog} onNewFrom=${onNewFrom} onImport=${onImport} onFleetPick=${onFleetPick}
    onEdit=${onEdit} onExport=${onExport} onDelete=${onDelete}
    onEditorChange=${(doc) => setEditor((ed) => ed && { ...ed, doc, error: null })} onEditorSave=${onEditorSave}
    onEditorCancel=${() => setEditor(null)} onEditorExport=${onEditorExport} />`;
}
