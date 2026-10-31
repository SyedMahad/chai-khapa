# Chai Khapa — Smoky Slate (02) theme patch

A **safe, CSS-only update**. It preserves your app logic, Google Sign-In, existing Terms and Privacy Policy text, routing, and environment settings.

## Apply

1. Commit or back up your current `chai-khapa` repository.
2. Extract this ZIP **into your repository root**; allow it to replace these three files only:
   - `public/theme.css` (new central palette)
   - `src/chai-khapa.css` (landing page styles)
   - `public/legal.css` (Terms/Privacy styles)
3. Restart `npm run dev`, then hard-refresh with Ctrl+Shift+R.
4. Check `/`, `/privacy/`, and `/terms/`. Run `npm run build` before pushing to GitHub.

The two CSS files import `/theme.css` automatically; **no React component changes, new dependencies, or HTML edits are necessary to restyle the pages**.

If your existing `src/chai-khapa.css` or `public/legal.css` contains custom work, merge it rather than overwriting it blindly.

## Change the colors next time

All palette decisions live in **`public/theme.css`**:

| Semantic token | Default |
|---|---|
| `--color-bg` | `#313E4B` |
| `--color-surface` | `#41505F` |
| `--color-surface-raised` | `#4B5C6A` |
| `--color-text` | `#F4F5F3` |
| `--color-muted` | `#CBD3DA` |
| `--color-accent` | `#DC9D75` |
| `--color-accent-hover` | `#F0B58F` |
| `--color-on-accent` | `#25313A` |

Future Chai Khapa components should use `var(--color-surface)`, `var(--color-muted)`, etc. and avoid inline literal colors. For additional themes, put a new `[data-theme="name"]` block into this one file; it will apply to screens where the attribute is set.

**Optional PWA/browser-chrome polish:** Existing `<meta name="theme-color">` tags may still have the previous dark color. Set them to `#313E4B` in `index.html`, `public/privacy/index.html`, and `public/terms/index.html` if you want the browser bar to match. Those metadata values do not affect page styling. Later, a runtime theme switcher can update the meta tag automatically.

This patch does not rewrite any legal text or change placeholders. Publish legal pages only after confirming the content and support contact details are accurate.
