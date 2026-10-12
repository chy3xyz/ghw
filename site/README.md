# GHW Documentation Site

Static documentation for GHW, built with [zdoc](https://github.com/chy3xyz/zdoc)
from the plain Markdown files in `docs/`. No config file, no Node.js, no
dependencies beyond the zdoc binary.

## Build

```bash
bash scripts/build_docs.sh
```

This downloads a pinned zdoc release into `.tools/` (cached, gitignored),
builds the site into `site/public/`, and rewrites root-absolute URLs under
`/ghw/` so the site works as a GitHub Pages project page. Pass a second
argument to override the prefix (use `/` when serving from a domain root).

## Source layout

- `docs/index.md` — landing page
- `docs/guide/` — getting started, concepts, architecture
- `docs/product-runtime/` — product digital life runtime
- `docs/api/` — HTTP API, C SDK, state persistence
- `docs/operations/` — deployment and operations

The sidebar is derived from the directory tree; a page's title comes from its
first `#` heading. Internal links use GitHub-style `.md` references and zdoc
rewrites them to site URLs at build time.
