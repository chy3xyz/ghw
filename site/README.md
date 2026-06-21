# GHW Documentation Site

VitePress documentation for GHW.

## Commands

```bash
npm install
npm run docs:dev
npm run docs:build
npm run docs:preview
```

The site source lives in `docs/`. Build output goes to `docs/.vitepress/dist/`
and is ignored by git.

## Security Note

`npm audit --omit=dev` currently reports 0 production vulnerabilities. Full
`npm audit` reports a Vite/VitePress development-server advisory in the
VitePress dependency chain with no available fix at the time this site was
added. Treat `docs:dev` as a local-only development server; do not expose it
publicly.
