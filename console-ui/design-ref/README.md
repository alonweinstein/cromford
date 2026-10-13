# design-ref

`mission-control-line.html` is a verbatim copy of `docs/design/mission-control-line.html` from `example-org/cromford-web` main (commit `866b868`, blob sha `cac25831763da4d16a60f7b5a25d2901de19027a`), copied 2026-10-08.
It is a reference only: the build does not bundle it, and no screen imports it. Its fonts (`fonts/*.woff2`) stay in cromford-web, so the copy renders with fallback fonts when opened from here.
`console-ui/tests/theme-paper.bh-4990.test.js` P3b pins the Paper theme to its `[data-theme="paper"]` block. To update it, copy the new file verbatim and replace the blob sha above.
