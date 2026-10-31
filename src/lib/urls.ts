/** Resolve UI origin from the running site, not a hardcoded pages.dev domain.
 * Optional VITE_PUBLIC_APP_URL is for copying production invitations from localhost.
 */
function originOf(input: string): string | null {
  try {
    const u = new URL(input)
    if (u.protocol !== 'https:' && !(u.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(u.hostname))) return null
    return u.origin
  } catch { return null }
}
export function getActiveOrigin(): string {
  return typeof window === 'undefined' ? '' : window.location.origin
}
export function chooseInviteOrigin(currentOrigin: string, configuredOverride?: string): string {
  const host = currentOrigin ? new URL(currentOrigin).hostname : ''
  // Production always follows its real domain, even after moving to a new hostname.
  if (host && !['localhost', '127.0.0.1'].includes(host)) return currentOrigin
  return (configuredOverride && originOf(configuredOverride)) || currentOrigin
}
export function publicInviteOrigin(): string {
  return chooseInviteOrigin(getActiveOrigin(), (import.meta.env.VITE_PUBLIC_APP_URL ?? '').trim())
}
export function invitationUrl(token: string): string {
  // token is an opaque high-entropy token, encoded as a URL path segment
  return `${publicInviteOrigin()}/join/${encodeURIComponent(token)}`
}
export function oauthReturnUrl(path: string): string {
  // OAuth must return to current site (localhost / preview / new domain), not shared-invite override.
  return new URL(path, getActiveOrigin()).toString()
}
