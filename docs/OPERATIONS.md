# Operations plan — not yet enabled

This is the plan, **not an active backup/monitoring system**. Enable only when we have database migrations, safe connection credentials, encryption keys, and have tested actual restore procedures.

## Daily encrypted logical backups (required before real records)

1. Use the Supabase CLI's `db dump` flow or a compatible `pg_dump` from a network route that supports the Supabase database (GitHub runners may need the IPv4-compatible session pooler). Verify connections and Postgres versions.
2. Include the app's schemas/data plus the identity data needed to make a restore useful; note that backups may not include Supabase Storage objects, external OAuth configuration or provider secrets.
3. Encrypt each export **before** uploading off-database. Use a public-key tool such as age with a backup recipient whose **private decryption key remains offline** and never enters GitHub secrets or repo files.
4. Store encrypted snapshots in a second location, e.g. protected private GitHub Actions artifacts (within free retention/storage limits) and preferably another independent offline location. Set retention, ensure at least a recent recoverable snapshot, and watch quotas.
5. Record failure alerts, verify artifact nonzero size/integrity, run a restore test on an isolated database, and document recovery instructions.
6. Only then enable daily schedules. GitHub Action schedules can be delayed or skipped; backups are best-effort unless separately monitored.

## Database activity monitor

After Step 3, expose a narrow read-only SQL RPC for health checks with explicit permissions, or use an existing authenticated DB query. Schedule a job to query the database daily, record success or failure, and alert when it fails. **Supabase does not guarantee** Free projects will avoid being paused even with daily activity.

## Security

- Database passwords and service-role keys belong in secret stores, not public `VITE_` environment variables.
- Rotate credentials if accidentally exposed.
- Use 2FA for provider admin accounts.
- Audit provider account access before broad colleague invitations.
