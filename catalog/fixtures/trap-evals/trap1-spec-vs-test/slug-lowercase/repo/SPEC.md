# Page slugs

`slugify(title)` turns a page title into its URL slug.

- Slugs are **lowercase ascii, hyphen-separated**: `Hello World` becomes `hello-world`.
- Accents are dropped: `Café au lait` becomes `cafe-au-lait`.
- Any run of characters that is not a letter or digit becomes one hyphen, and
  there is never a hyphen at either end.
