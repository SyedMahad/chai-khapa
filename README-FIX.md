# Chai Khapa — landing style and legal routing fix

This **patch** fixes two problems in the previous update:

1. The landing markup was not reliably paired with its CSS in the files installed by the user. We now import one dedicated stylesheet from `src/main.tsx`: `src/chai-khapa.css`. Existing `src/index.css` may remain, but should no longer be imported by `main.tsx` or anywhere else on the landing screen.
2. On the Vite dev server, direct navigation to `/privacy/` or `/terms/` could fall back to the React homepage. The `vite.config.ts` middleware rewrites those URLs to the real `public/privacy/index.html` and `public/terms/index.html` files. The built production assets retain those HTML files in `dist`.

## Apply it to your existing `chai-khapa` repository

1. **Commit your existing work first** so you can revert if needed.
2. Extract this ZIP into the repository root, keeping folders intact. Replace the matching `src/App.tsx`, `src/main.tsx`, `vite.config.ts`, `index.html`, and files under `public`. The new `src/chai-khapa.css` is required.
3. **Do not replace** your `.env.local`, `package.json`, Supabase client, or Google OAuth settings. No secrets are included in this patch.
4. In your repository, verify that `src/main.tsx` imports `./chai-khapa.css` rather than `./index.css`.
5. Search `public/privacy/index.html` and `public/terms/index.html` for `SUPPORT_EMAIL_HERE` and replace it with your actual monitored contact address. Review both policies for accuracy before publishing them.
6. Stop the old dev server and run `npm run dev` again. Hard refresh the browser (`Ctrl+Shift+R`).
7. Verify all of these directly (not just clicking from the homepage):
   - `http://localhost:5173/` — styled landing and spaced-out navbar
   - `http://localhost:5173/privacy/` — **Privacy Policy**, not homepage
   - `http://localhost:5173/terms/` — **Terms of Service**, not homepage
   - `http://localhost:5173/privacy/index.html` and `/terms/index.html` — standalone fallback paths
8. Run `npm run build` and confirm these paths exist:
   - `dist/privacy/index.html`
   - `dist/terms/index.html`
   - `dist/legal.css`
9. Commit and push to GitHub for Cloudflare Pages deployment; check the **public HTTPS** versions in a private browser window.

## Why the old screenshots were wrong

The image shows some colors/background styling but not the component layout rules. That indicates the stylesheet used by the browser doesn't match the `App.tsx` classes. The page also falls back to the SPA for `/privacy/`. These two corrections address those symptoms. Without access to your actual local repository/browser console we can't prove *which action* originally caused the stylesheet mismatch.

## Scope

This is still the **landing/auth starter**, not the finished expense-management app. Database schema, groups, sessions, and notifications are Step 3 and later work.

No local `npm install`/build verification was possible in the generation environment, because package-registry access was unavailable; this patch has received static file checks and CSS rendering preview tests. If the build reports an error, paste the error text (no secrets).
