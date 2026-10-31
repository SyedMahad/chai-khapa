/** One active group opens directly only on initial entry, not on explicit navigation. */
export function singleGroupEntryDestination(
  pathname: string,
  groups: ReadonlyArray<{ id: string; archived_at?: string | null }>,
): string | null {
  if (!['/', '/app', '/app/dashboard'].includes(pathname)) return null
  const active = groups.filter(group => !group.archived_at)
  return active.length === 1 ? `/app/groups/${encodeURIComponent(active[0].id)}` : null
}
