# GHW Documentation Site

Static documentation for GHW, built with [zdoc](https://github.com/chy3xyz/zdoc)
from the plain Markdown files in `docs/`. No config file, no Node.js, no
dependencies beyond the zdoc binary.

## Build

```bash
bash scripts/build_docs.sh
```

This downloads a pinned zdoc release into `.tools/` (cached, gitignored),
builds the site into `site/public/`, and passes `--url-prefix /ghw/` so the site
works as a GitHub Pages project page. Pass a second argument to override the
prefix (use `/` when serving from a domain root).

zdoc 0.16 also generates the client-side search index, `sitemap.xml`, a 404
page, and per-page last-modified dates; the landing page uses the `layout: home`
frontmatter for its hero and feature cards.

## Source layout

- `docs/index.md` — landing page (hero and feature cards via frontmatter)
- `docs/guide/` — getting started, concepts, architecture
- `docs/product-runtime/` — product digital life runtime
- `docs/api/` — HTTP API, C SDK, state persistence
- `docs/operations/` — deployment and operations

The sidebar is derived from the directory tree; section labels come from each
directory's index page H1 and page titles from the first `#` heading. Internal
links use GitHub-style `.md` references and zdoc rewrites them to site URLs at
build time.
