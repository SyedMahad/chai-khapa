/** The generated invitation is a bearer token. Sharing is an explicit user action. */
export function whatsappInviteHref(groupName: string, url: string): string {
  const text = `☕ Join ${groupName} on Chai Khapa!\n${url}`
  return `https://wa.me/?text=${encodeURIComponent(text)}`
}
