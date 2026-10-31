# Chai Khapa — public legal pages and dark-mode update

Prepared 31 October 2026. This is a **drop-in update for the Step 2 React/Vite starter**, not a live website update.

## Before publishing (required)

1. Open `public/privacy/index.html` and `public/terms/index.html` and replace **every** `SUPPORT_EMAIL_HERE` with a real, monitored support email. It should match the support/contact address used in Google Auth Platform. The editable source drafts are in `docs/` and should be updated too if you plan to maintain them.
2. **Review policy statements against actual app behavior.** The document describes current Google sign-in and planned group/settlement features as conditional. Confirm processors and any optional payment data, analytics, tracking, backups, retention and deletion handling before publishing. A policy must be true, not merely present.
3. Consider identifying the operating person or legal entity in the policy and terms as appropriate to your jurisdiction. These are templates, **not legal advice**.

## Apply to your existing repository

1. Unzip this update package into a temporary folder.
2. Copy the package's `public/` directory into your existing `chai-khapa` repository (create `public/` if missing).
3. **Optional visual update:** If your source is still the Step 2 starter, copy `src/App.tsx`, `src/index.css`, and `index.html` to the same locations. These files change the whole sign-in/landing page to the new dark style; **do not overwrite your files blindly if you have already built more app functionality**. Instead, copy the privacy/terms links into your current public homepage and footer.
4. Commit the files to `main` and push. Cloudflare Pages should deploy automatically from GitHub.
5. Visit the deployed URLs **in a private/incognito window** (without logging in):
   - `https://YOUR-ACTUAL-HOST/`
   - `https://YOUR-ACTUAL-HOST/privacy/`
   - `https://YOUR-ACTUAL-HOST/terms/`
6. Check direct navigation and reloading of `/privacy/` and `/terms/`. They are **standalone static HTML pages**, intentionally not guarded by React or Supabase authentication.

## Google Auth Platform — Branding links

In Google Cloud Console > Google Auth Platform > Branding, use the **actual working** HTTPS URLs above for:
- Application home page
- Privacy policy
- Terms of service

Ensure the home page itself has a product description and links to both documents (the optional `src/App.tsx` update includes these). In the OAuth client, keep Supabase's exact redirect URI and configure the actual app origin in authorized JS origins if required.

For branding verification, Google can require **Search Console verification for the domain used on these URLs**. A `pages.dev` address is a hosted subdomain; do not assume Google will accept it as a verified domain you control. Try verifying the exact deployed site via Search Console if permitted, or plan for a custom domain if Google's checks require domain ownership. Publishing basic-scopes OAuth is not a guarantee of verified branding.

## Future additions

The drafts must be revised before collecting optional wallet/Raast numbers, implementing email or push delivery with new processors, or changing data retention behavior.

## Verification

Run `npm run build` in your app repository and check that `dist/privacy/index.html`, `dist/terms/index.html` and `dist/legal.css` are emitted. If your deployment differs from the Step 2 starter, check Cloudflare Pages configuration and static asset routing.
