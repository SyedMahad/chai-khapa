import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY

export const hasSupabaseConfig = Boolean(
  url && publishableKey && !url.includes('YOUR_PROJECT_REF') &&
    !publishableKey.includes('YOUR_SUPABASE_PUBLISHABLE_KEY'),
)

// Only publishable/anon credentials are ever placed in frontend code.
// Financial writes in Step 3 must be through locked-down database RPCs and RLS.
export const supabase = hasSupabaseConfig
  ? createClient(url!, publishableKey!, {
      auth: { autoRefreshToken: true, persistSession: true, detectSessionInUrl: true },
    })
  : null
