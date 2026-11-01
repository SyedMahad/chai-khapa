/** Supabase/PostgREST may return plain JSON error objects, not Error instances. */
type DbError = { code?: unknown; message?: unknown; details?: unknown; hint?: unknown }

function objectValue(error: unknown): DbError {
  if (error instanceof Error) {
    // Error.message is usually not enumerable. Preserve it explicitly without
    // object spreading, which also causes TS2783 on duplicate `message`.
    const extended = error as Error & DbError
    return {
      code: extended.code,
      message: error.message,
      details: extended.details,
      hint: extended.hint,
    }
  }
  if (error && typeof error === 'object') return error as DbError
  if (typeof error === 'string') return { message: error }
  return {}
}

export function describeAppError(error: unknown): string {
  const { code: rawCode, message: rawMessage } = objectValue(error)
  const code = typeof rawCode === 'string' ? rawCode : ''
  const message = typeof rawMessage === 'string' ? rawMessage : ''
  if (code === 'PGRST202') return 'The requested database operation is not visible to the API (PGRST202). Verify that the database migration was applied and refresh the Supabase API schema cache.'
  if (code === '42883') return `PostgreSQL could not resolve a database function${message ? `: ${message.slice(0, 220)}` : ''} (42883). Check the Phase 3.8.2 migration.`
  if (code === '42501') return 'You do not have permission to record this session. Check your group membership and sign-in.'
  if (code === '23503') return 'One of the selected contributors or attendees is not a valid member of this group.'
  if (code === '23514' || code === '22023') return `${message || 'The session failed validation.'} (${code})`
  if (code === '23505') return `This request conflicts with a record already saved. Refresh the session list before trying again. (${code})`
  if (code === '42P01') return `A required database table was not found. Check the database migrations. (${code})`
  if (message) return `${message.slice(0, 260)}${code ? ` (${code})` : ''}`
  return 'Could not complete the request. Check your connection and try again.'
}

export function diagnosticDetails(error: unknown): { code: string | null; message: string | null; details: string | null; hint: string | null } {
  const source = objectValue(error)
  const read = (v: unknown) => typeof v === 'string' ? v : null
  return { code: read(source.code), message: read(source.message), details: read(source.details), hint: read(source.hint) }
}
