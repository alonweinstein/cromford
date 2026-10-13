// The built-in themes (BH-4844). A theme is a plain object: an id, a display
// name, the colour scheme the browser should use for its own chrome, the
// theme-color for the address bar, one value for every colour token in the
// :root block of src/styles.css, and (BH-4845) a `shape`: one value for every
// key in SHAPE_TOKENS (src/theme/tokens.js). Applying a theme writes those values onto
// :root (src/theme/apply.js; before first paint, src/theme/boot.js).
//
// Built-ins ship in code (BH-4840: "built-in themes ship as token objects in
// code"). Which one a page gets is data: the viewer's pick, then the fleet
// default in the settings row ui.theme.default (src/theme/resolve.js).
//
// Mill and Paper come from the Cromford design reference (ink, stage,
// rule, dim, chalk, stone, brick). Where a reference colour misses 4.5:1 as
// text, the token here is the nearest shade that clears it:
// tests/theme-contrast.bh-4844.test.js checks every text token on every surface.
//
// BH-4990: Paper replaced Mill Light (both were the light Mill; Paper is the
// reference's own [data-theme="paper"] block). A stored `mill-light` is an alias
// for `paper` (THEME_ALIASES), read wherever a stored theme id is read.

import { PHOSPHOR_TOKENS, PHOSPHOR_SHAPE } from './phosphor.js';

// The documented code fallback when neither the viewer nor the fleet row names
// a theme. The fleet's real default is the settings row ui.theme.default.
export const DEFAULT_THEME_ID = 'mill';

// The Mill Floor form (BH-4845), shared by Mill and Paper: Archivo
// condensed titles, Geist body, Geist Mono uppercase labels, 10-14px panels,
// pill buttons. No title, brand, nav-tab or stat glow: Mill's glow is brick,
// and brick is for work in progress only.
const MILL_SHAPE = {
  '--font-display': "'Archivo', 'Arial Narrow', system-ui, sans-serif",
  '--font-body': "'Geist', system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
  '--font-mono': "'Geist Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
  '--radius-sm': '6px',
  '--radius-md': '10px',
  '--radius-lg': '14px',
  '--radius-pill': '999px',
  '--label-case': 'uppercase',
  '--display-stretch': '75%',
  '--title-shadow': 'none',
  '--brand-shadow': 'none',
  '--nav-shadow': 'none',
  '--stat-shadow': 'none'
};

const MILL = {
  id: 'mill',
  name: 'Mill',
  scheme: 'dark',
  themeColor: '#0d0d0c',
  tokens: {
    '--surface-0': '#0d0d0c',
    '--surface-1': '#151513',
    '--surface-2': '#1d1c1a',
    '--rule': '#2b2a26',
    '--text': '#d6d3cc',
    '--text-strong': '#f2f0eb',
    '--text-dim': '#8d8a82',
    '--accent': '#dc6a40',
    '--ok': '#6fae7b',
    '--warn': '#d9a441',
    '--err': '#e0675c',
    '--info': '#7fa8d6',
    '--glow': 'rgba(200, 87, 47, 0.35)',
    '--world-idle': '#8d8a82',
    '--world-label-live': '#f2f0eb',
    '--world-sky': '#e7e5df',
    '--world-ground': '#151513',
    '--world-sun': '#fff6ea',
    '--world-rim': '#dc6a40',
    '--hex-sky-top': '#1d1c1a',
    '--shadow': '#000',
    '--surface-nav': '#111110',
    '--ink-on-ok': '#0d0d0c',
    '--note': '#8d8a82',
    '--line-hover': '#4f4b44',
    '--line-warn-hover': '#6a5426',
    '--line-cyan-hover': '#3a5576',
    '--row-warn-hover': '#1f1910',
    '--term-text': '#b0aca3',
    '--artifact-text': '#cfcbc3',
    '--transcript-text': '#bdb9b0',
    '--skeleton-hi': '#252420',
    '--scrim': 'rgba(5, 5, 4, 0.82)',
    '--world-bg': '#080807',
    '--world-tip-bg': 'rgba(13, 13, 12, 0.92)',
    '--panel-active': '#1a1917',
    '--terminal': '#0a0a09',
    '--artifact': '#11110f',
    '--line-active': '#3a3833',
    '--line-btn': '#45423c',
    '--line-row': '#1f1e1b',
    '--line-warn': '#4a3a1c',
    '--line-dead': '#4a2420',
    '--line-cyan': '#26364a',
    '--bg-warn': '#17130b',
    '--bg-warn-2': '#1a150c',
    '--bg-dead': '#180e0c',
    '--bg-cyan': '#0f141a',
    '--select-ink': '#ffffff',
    '--select-ink-soft': 'rgba(255, 255, 255, 0.55)',
    '--soft': '#b5b1a8',
    '--soft-2': '#cbc7be',
    '--faint': '#6b6862',
    '--fainter': '#55524c',
    '--dim': '#3a3833',
    '--green-lt': '#9fd0a9',
    '--green-mid': '#3d5a43',
    '--green-dk': '#2a3b2d',
    '--track': '#1f1e1b',
    '--amber-lt': '#ecc77a',
    '--amber-txt': '#c29a4f',
    '--amber-dk': '#8a6a2a',
    '--amber-dim': '#b8862b',
    '--red-lt': '#ee8a80',
    '--red-ltr': '#f3a59d',
    '--red-txt': '#c98a80',
    '--red-dim': '#8f726c',
    '--cyan-lt': '#c8d9ec',
    '--cyan-dk': '#4f6e8e',
    '--live': '#c8572f',
    '--live-text': '#dc6a40',
    '--grid': '#1a1917',
    '--live-soft': 'rgba(200, 87, 47, 0.14)'
  },
  shape: MILL_SHAPE
};

// Warm paper surfaces (BH-4990, the reference's paper block). Brick, green and
// amber are darkened where the reference's shade misses 4.5:1 as text; the
// reference brick stays as --live, the fill. The "-lt" ramp steps are the
// emphasis end of each ramp, so on a light page they go darker, not lighter.
const PAPER = {
  id: 'paper',
  name: 'Paper',
  scheme: 'light',
  themeColor: '#f1efe9',
  tokens: {
    '--surface-0': '#f1efe9',
    '--surface-1': '#fbfaf7',
    '--surface-2': '#f5f3ee',
    '--rule': '#d9d5cb',
    '--text': '#2b2a26',
    '--text-strong': '#161513',
    '--text-dim': '#6b675f',
    '--accent': '#b04a26',
    '--ok': '#357a43',
    '--warn': '#8f630f',
    '--err': '#a33a2c',
    '--info': '#2d5f8a',
    '--glow': 'rgba(176, 74, 38, 0.20)',
    '--world-idle': '#6b6862',
    '--world-label-live': '#0d0d0c',
    '--world-sky': '#f7f6f2',
    '--world-ground': '#cfccc4',
    '--world-sun': '#ffffff',
    '--world-rim': '#9a3f1c',
    '--hex-sky-top': '#dedbd3',
    '--shadow': '#000',
    '--surface-nav': '#ebe9e3',
    '--ink-on-ok': '#fbfaf7',
    '--note': '#6b675f',
    '--line-hover': '#8f8b82',
    '--line-warn-hover': '#b89a52',
    '--line-cyan-hover': '#6f93b5',
    '--row-warn-hover': '#efe4c8',
    '--term-text': '#3a3833',
    '--artifact-text': '#2a2825',
    '--transcript-text': '#34322e',
    '--skeleton-hi': '#ebe9e3',
    '--scrim': 'rgba(25, 24, 22, 0.55)',
    '--world-bg': '#f1efe9',
    '--world-tip-bg': 'rgba(242, 240, 235, 0.94)',
    '--panel-active': '#ebe8e1',
    '--terminal': '#efede7',
    '--artifact': '#f4f2ed',
    '--line-active': '#b9b5ab',
    '--line-btn': '#a8a49a',
    '--line-row': '#e6e2d9',
    '--line-warn': '#d9c38f',
    '--line-dead': '#dcaaa2',
    '--line-cyan': '#a9c0d6',
    '--bg-warn': '#f5ecd6',
    '--bg-warn-2': '#f2e7cc',
    '--bg-dead': '#f5e1dd',
    '--bg-cyan': '#e3ecf4',
    '--select-ink': '#191816',
    '--select-ink-soft': 'rgba(25, 24, 22, 0.55)',
    '--soft': '#45423d',
    '--soft-2': '#34322e',
    '--faint': '#a19c92',
    '--fainter': '#9a978f',
    '--dim': '#c4c0b7',
    '--green-lt': '#24552f',
    '--green-mid': '#a9c9ae',
    '--green-dk': '#cfe0d1',
    '--track': '#dedbd3',
    '--amber-lt': '#6a4a08',
    '--amber-txt': '#7a560c',
    '--amber-dk': '#c9a85e',
    '--amber-dim': '#8a6410',
    '--red-lt': '#8f2f22',
    '--red-ltr': '#7e2a1f',
    '--red-txt': '#8f4a40',
    '--red-dim': '#8a6a64',
    '--cyan-lt': '#1f4a6e',
    '--cyan-dk': '#6f93b5',
    '--live': '#c8572f',
    '--live-text': '#b04a26',
    '--grid': '#e5e1d7',
    '--live-soft': 'rgba(200, 87, 47, 0.10)'
  },
  shape: MILL_SHAPE
};

const PHOSPHOR = {
  id: 'phosphor',
  name: 'Phosphor',
  scheme: 'dark',
  themeColor: PHOSPHOR_TOKENS['--surface-0'],
  tokens: PHOSPHOR_TOKENS,
  shape: PHOSPHOR_SHAPE
};

export const THEME_ORDER = [MILL.id, PAPER.id, PHOSPHOR.id];

export const BUILTIN_THEMES = {
  [MILL.id]: MILL,
  [PAPER.id]: PAPER,
  [PHOSPHOR.id]: PHOSPHOR
};

// Retired built-in ids -> the built-in that replaced them. A browser's
// localStorage, the fleet row ui.theme.default and a custom theme's `base` may
// still say the old id (BH-4990: Mill Light became Paper).
export const THEME_ALIASES = { 'mill-light': 'paper' };

// [text token, surface token] pairs that must clear WCAG AA (4.5:1) in every
// theme: each text colour on each surface, plus the ink on the active nav tab.
const TEXT_FG = ['--text', '--text-strong', '--text-dim', '--accent', '--ok', '--warn', '--err', '--info', '--live-text'];
const SURFACES = ['--surface-0', '--surface-1', '--surface-2'];
export const TEXT_PAIRS = [
  ...TEXT_FG.flatMap((fg) => SURFACES.map((bg) => [fg, bg])),
  ['--ink-on-ok', '--ok']
];
