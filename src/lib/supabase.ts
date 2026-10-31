import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
// Accept the starter's publishable key and deployments that used the legacy anon name.
const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY

export const hasSupabaseConfig = Boolean(
  url && publishableKey && !url.includes('YOUR_PROJECT_REF') &&
  !publishableKey.includes('YOUR_SUPABASE_'),
)

// Only public credentials may appear in VITE_* environment variables.
export const supabase = hasSupabaseConfig
  ? createClient(url!, publishableKey!, {
      auth: { autoRefreshToken: true, persistSession: true, detectSessionInUrl: true },
    })
  : null
