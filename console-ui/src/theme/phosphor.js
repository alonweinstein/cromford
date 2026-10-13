// Phosphor: the console's original look, as a theme (BH-4844). Every colour
// token in the :root block of src/styles.css, at the value it holds there, so
// picking Phosphor sets exactly what the stylesheet already says.
// tests/theme-contrast.bh-4844.test.js holds the two equal, key for key.

export const PHOSPHOR_TOKENS = {
  '--surface-0': '#070B08',
  '--surface-1': '#0A110B',
  '--surface-2': '#0C140E',
  '--rule': '#16241A',
  '--text': '#C9DCC9',
  '--text-strong': '#E8F5E8',
  '--text-dim': '#6E8F77',
  '--accent': '#4AF37A',
  '--ok': '#4AF37A',
  '--warn': '#FFB000',
  '--err': '#FF4D4D',
  '--info': '#55D7E8',
  '--glow': 'rgba(74, 243, 122, 0.35)',
  '--world-idle': '#7FA98A',
  '--world-label-live': '#B9F5C8',
  '--world-sky': '#9FD8B0',
  '--world-ground': '#0A1A10',
  '--world-sun': '#D8FFE4',
  '--world-rim': '#4AFFA0',
  '--hex-sky-top': '#0F2016',
  '--shadow': '#000',
  '--surface-nav': '#0A120C',
  '--ink-on-ok': '#0A120C',
  '--note': '#5F8168',
  '--line-hover': '#34573E',
  '--line-warn-hover': '#55401A',
  '--line-cyan-hover': '#1B5568',
  '--row-warn-hover': '#16110A',
  '--term-text': '#7BA184',
  '--artifact-text': '#A8C0AD',
  '--transcript-text': '#8FB397',
  '--skeleton-hi': '#121E15',
  '--scrim': 'rgba(3, 6, 4, 0.82)',
  '--world-bg': '#040705',
  '--world-tip-bg': 'rgba(8, 16, 10, 0.92)',
  '--panel-active': '#0B130D',
  '--terminal': '#060906',
  '--artifact': '#090F0A',
  '--line-active': '#1E3325',
  '--line-btn': '#26402E',
  '--line-row': '#101A12',
  '--line-warn': '#3A2B10',
  '--line-dead': '#3A1515',
  '--line-cyan': '#123A4A',
  '--bg-warn': '#100D06',
  '--bg-warn-2': '#120E06',
  '--bg-dead': '#100808',
  '--bg-cyan': '#081014',
  '--select-ink': '#FFFFFF',
  '--select-ink-soft': 'rgba(255, 255, 255, 0.55)',
  '--soft': '#8FA996',
  '--soft-2': '#A8C9AE',
  '--faint': '#4E6B55',
  '--fainter': '#3D5744',
  '--dim': '#2B3D30',
  '--green-lt': '#8CFFB0',
  '--green-mid': '#2E5A3A',
  '--green-dk': '#1E3D26',
  '--track': '#101A12',
  '--amber-lt': '#FFD780',
  '--amber-txt': '#C9A24B',
  '--amber-dk': '#8A6A2A',
  '--amber-dim': '#B8860B',
  '--red-lt': '#FF7B7B',
  '--red-ltr': '#FF9B9B',
  '--red-txt': '#C97B7B',
  '--red-dim': '#8F7070',
  '--cyan-lt': '#C9EFF7',
  '--cyan-dk': '#3E7A8A',
  '--live': '#2E5A3A',
  '--live-text': '#8CFFB0',
  '--grid': '#101A12',
  '--live-soft': 'rgba(46, 90, 58, 0.25)'
};

// Phosphor's form (BH-4845): the square JetBrains Mono look, equal to the
// :root block of src/styles.css key for key (tests/theme-shape.bh-4845.test.js).
const JETBRAINS = "'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
export const PHOSPHOR_SHAPE = {
  '--font-display': JETBRAINS,
  '--font-body': JETBRAINS,
  '--font-mono': JETBRAINS,
  '--radius-sm': '2px',
  '--radius-md': '2px',
  '--radius-lg': '2px',
  '--radius-pill': '2px',
  '--label-case': 'none',
  '--display-stretch': 'normal',
  '--title-shadow': '0 0 12px color-mix(in srgb, var(--accent) 30%, transparent)',
  '--brand-shadow': '0 0 12px var(--glow)',
  '--nav-shadow': '0 0 14px var(--glow)',
  '--stat-shadow': '0 0 10px var(--glow)'
};

// The Phosphor value of every token JS reads, for the moment before the
// stylesheet applies (and for node, where it never does). readToken() falls
// back to these, so a pre-CSS read and a post-CSS read draw the same world.
// tests/theme-tokens.bh-4843.test.js holds each one equal to styles.css.
// --world-label and --world-ring are aliases in styles.css (var(--soft),
// var(--line-active)), so their values come from what they alias.
const pick = (...names) => Object.fromEntries(names.map((n) => [n, PHOSPHOR_TOKENS[n]]));

export const PHOSPHOR_FALLBACK = {
  ...pick('--ok', '--warn', '--err', '--world-idle'),
  '--world-label': PHOSPHOR_TOKENS['--soft'],
  ...pick('--world-label-live', '--world-sky', '--world-ground', '--world-sun', '--world-rim'),
  '--world-ring': PHOSPHOR_TOKENS['--line-active'],
  ...pick('--select-ink')
};
