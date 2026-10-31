/** Chai Khapa financial display helpers. Ledger math stays in PostgreSQL paisa. */
export function rupeesToPaisa(input: string): number {
  const value = input.trim()
  if (!/^(0|[1-9]\d*)(?:\.\d{1,2})?$/.test(value)) {
    throw new Error('Enter a valid amount, e.g. 350 or 350.50')
  }
  const [rupees, fraction = ''] = value.split('.')
  const paisa = BigInt(rupees) * 100n + BigInt(fraction.padEnd(2, '0'))
  if (paisa < 1n || paisa > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error('Enter an amount greater than zero and within the supported range')
  }
  return Number(paisa)
}

export function formatPkr(paisa: number | string | bigint, showPaisa = true): string {
  const value = BigInt(paisa)
  const minus = value < 0n ? '−' : ''
  const abs = value < 0n ? -value : value
  const whole = (abs / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  const fraction = (abs % 100n).toString().padStart(2, '0')
  return `Rs. ${minus}${whole}${showPaisa ? `.${fraction}` : ''}`
}

export function allocateShares(total: number, ids: string[]): Record<string, number> {
  if (ids.length === 0) return {}
  const sorted = [...ids].sort()
  const base = Math.floor(total / sorted.length)
  const remainder = total % sorted.length
  return Object.fromEntries(sorted.map((id, i) => [id, base + (i < remainder ? 1 : 0)]))
}

export function displayName(profile: { first_name?: string | null; last_name?: string | null } | null | undefined): string {
  const value = [profile?.first_name, profile?.last_name].filter(Boolean).join(' ').trim()
  return value || 'Colleague'
}

export function initials(name: string): string {
  return name.split(/\s+/).slice(0, 2).map((part) => part[0] || '').join('').toUpperCase() || 'CK'
}

export function relativeDate(input: string): string {
  const d = new Date(input)
  if (Number.isNaN(d.getTime())) return 'Unknown date'
  const day = new Date().toDateString() === d.toDateString()
  return day ? `Today, ${d.toLocaleTimeString('en-PK', { hour: 'numeric', minute: '2-digit' })}`
    : d.toLocaleDateString('en-PK', { day: 'numeric', month: 'short', year: 'numeric' })
}
