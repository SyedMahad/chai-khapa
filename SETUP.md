# Chai Khapa — Step 2 setup (operator checklist)

> **Accounts and cloud resources are not created by this ZIP.** Follow each provider's dashboard, then paste only safe **public** values into `.env.local` or Cloudflare build settings. Keep passwords, keys and OAuth secrets out of chats, Git and screenshots.

## A. GitHub

1. Create or sign into a project-managed GitHub account or organization. Enable two-factor authentication.
2. At https://github.com/new create a **private** repository named `chai-khapa`. Do not initialize it with a README or .gitignore (they are already in this starter).
3. Extract the starter, open a terminal inside `chai-khapa-starter`, then run:

   ```bash
   git init
   git branch -M main
   git add .
   git commit -m "chore: bootstrap Chai Khapa infrastructure"
   git remote add origin https://github.com/YOUR_USERNAME/chai-khapa.git
   git push -u origin main
   ```

4. Confirm `.env.local` is ignored with `git check-ignore .env.local`. Do not upload `.env.local` to GitHub.

## B. Supabase

1. Open https://supabase.com/dashboard and create a new organization/project named `chai-khapa-prod` on **Free**. Choose the nearest available region (subject to availability). Store the database password in your password manager.
2. In **Project Settings > API**, note the Project URL. In **API Keys**, copy the **publishable** key (or legacy `anon` key if required). The UI names can change.
3. Populate `.env.local` with `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. These are public client credentials, **not** the service-role/secret key.
4. In **Authentication > URL Configuration**, set the Site URL to the exact Cloudflare production URL after first deployment, for example `https://chai-khapa.pages.dev` if assigned.
5. Add allowed redirect URLs `http://localhost:5173/**` and `https://YOUR-ACTUAL-PAGES-SUBDOMAIN.pages.dev/**` (replace placeholders). Prefer an exact `/` production path; only allow broader preview patterns if needed.
6. Do **not** enable financial-table access yet. Database migrations and RLS are Step 3.

## C. Google Sign-In

1. Use a dedicated project-managed Google account, not an unrelated personal account. At https://console.cloud.google.com create a Google Cloud project **Chai Khapa**.
2. Under **Google Auth Platform**, configure Branding (support email) and Audience. For colleagues with personal Gmail accounts select **External**; do not choose Internal unless everyone belongs to the same Google Workspace organization.
3. Request only Google's basic `openid`, `email` and `profile` identity scopes. Publish to **Production** when eligible; skip the logo for launch. Google's separate branding verification requirements may still apply: unverified brand details might not display. Do not promise instant verified brand display.
4. Create OAuth client type **Web application**. Under **Authorized redirect URIs**, enter the **Supabase callback** shown in **Supabase > Authentication > Providers > Google**, typically `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback`. This is **not** the Cloudflare Pages URL.
5. In Supabase **Authentication > Providers > Google**, enable Google and enter the Google OAuth **Client ID** and **Client Secret**. Never put the secret in `.env.local` or source code.
6. Test Sign in with Google at `http://localhost:5173`. Ensure the Supabase URL Configuration includes the browser's return origin. Test again on the production Cloudflare URL.

## D. Cloudflare Pages

1. Open https://dash.cloudflare.com and select **Workers & Pages > Create > Pages > Connect to Git**. Authorize the correct GitHub repository.
2. Pick `chai-khapa` with production branch `main`.
3. Set **Build command** to `npm run build`, **Build output directory** to `dist`, and project name to `chai-khapa` if available.
4. In **Settings > Environment variables**, define `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` for production builds. They are browser-visible publishable client configuration.
5. Deploy, then copy the actual `*.pages.dev` URL into Supabase's Auth URL Configuration as the Site URL and redirect allow-list entry.
6. Test the published page, the Google sign-in round trip, and sign-out on a phone.

## E. Local smoke checks

```bash
node --version   # recommended 22.x
npm install      # creates package-lock.json; commit it
npm run typecheck
npm run build
npm run dev
```

## F. Operational prerequisites before real expenses

- Confirm security policies and atomic write RPCs in Step 3.
- Implement and successfully test an **encrypted off-Supabase** logical backup; keep decryption keys outside GitHub.
- Confirm that the scheduled monitor queries a database-backed endpoint; a status-page ping is not sufficient to demonstrate DB activity. It cannot guarantee the Free plan stays unpaused.
- Never assume a hosted deployment means the financial app is ready.

## Official references

- Cloudflare React: https://developers.cloudflare.com/pages/framework-guides/deploy-a-react-site/
- Supabase Google: https://supabase.com/docs/guides/auth/social-sign-in/auth-google
- Supabase redirect URLs: https://supabase.com/docs/guides/auth/redirect-urls
- Supabase backups: https://supabase.com/docs/guides/platform/backups
- Google brand verification: https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification
