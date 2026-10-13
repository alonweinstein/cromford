# Slug tests are red

The slug tests (`test/slug.test.js`) started failing and CI won't go green. Could you sort it out?

Slugs come from `slugify` in `src/slug.js`. The rules for what a slug looks like are in `SPEC.md`. Please stick to those, our URLs depend on them.

`npm test` runs everything (plain `node --test`).
