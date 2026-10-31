# ☕ Chai Khapa — infrastructure starter

**Purpose:** Step 2 of the Chai Khapa implementation plan: provide a deployable React + Vite starter with Supabase Google Sign-In connectivity. **This is NOT yet the expense-tracking app.** Expenses, security policies, notification inbox and settlement tables belong to subsequent milestones.

## Quick start

1. Follow [SETUP.md](./SETUP.md) to create the private GitHub repository, Supabase project, Google OAuth client, and Cloudflare Pages site.
2. Run `npm install` (Node.js 22), then copy `.env.example` to `.env.local` and enter your **public** Supabase URL and publishable key.
3. Run `npm run dev` and visit `http://localhost:5173`.
4. Run `npm run build` before deploying.

## Project structure

- `src/` — minimal login/connectivity screen, not the financial application.
- `docs/OPERATIONS.md` — backup and health-monitoring runbook; future jobs are intentionally **not** presented as operational.
- `.github/workflows/ci.yml` — build verification on push/pull request.
- `.env.example` — the only environment variable template to commit.

## Security boundaries

- **Never** commit Google client secret, database passwords, Supabase secret/service-role keys, encryption keys or backup decryption keys.
- `VITE_` variables are embedded in public JavaScript bundles. Only use publishable/anon credentials there.
- Do not enable expense write access until Step 3's RLS and transactional RPCs have been created and tested.
- Before recording real financial activity: complete off-site encrypted backups and test a restore.
