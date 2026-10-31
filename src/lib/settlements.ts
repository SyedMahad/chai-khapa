/** Provisional netting only: NOT an authoritative financial obligation or payment. */
export type BalanceLike = { user_id: string; net_paisa: number | string }
export type SuggestedTransfer = { from: string; to: string; amountPaisa: number }
export function computeTransfers(input: BalanceLike[]): SuggestedTransfer[] {
  const rows = input.map(r => ({ id: r.user_id, value: BigInt(r.net_paisa) }))
  const debtors = rows.filter(r => r.value < 0n).map(r => ({ id: r.id, remain: -r.value })).sort((a,b) => a.id.localeCompare(b.id))
  const creditors = rows.filter(r => r.value > 0n).map(r => ({ id: r.id, remain: r.value })).sort((a,b) => a.id.localeCompare(b.id))
  const sum = rows.reduce((t,r)=>t+r.value,0n)
  if (sum !== 0n) throw new Error('Group balances do not sum to zero; cannot suggest transfers')
  const results: SuggestedTransfer[] = []
  let i = 0, j = 0
  while (i < debtors.length && j < creditors.length) {
    const from = debtors[i], to = creditors[j]
    const amount = from.remain < to.remain ? from.remain : to.remain
    if (amount > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Transfer too large to display safely')
    if (amount > 0n) results.push({ from: from.id, to: to.id, amountPaisa: Number(amount) })
    from.remain -= amount; to.remain -= amount
    if (from.remain === 0n) i++
    if (to.remain === 0n) j++
  }
  return results
}
