/** All values are exact paisa (integer), never floating-point rupees. */
export function remainingPaisa(total: number, applied: number): number {
  if (!Number.isSafeInteger(total) || total < 0 || !Number.isSafeInteger(applied) || applied < 0 || applied > total) {
    throw new Error('Inconsistent settlement ledger amount')
  }
  return total - applied
}
export function wholeRupeeRoundUp(paisa: number): number {
  if (!Number.isSafeInteger(paisa) || paisa < 0 || paisa > Number.MAX_SAFE_INTEGER - 99) throw new Error('Invalid paisa amount')
  return Math.ceil(paisa / 100) * 100
}
export function totalOutstanding(transfers: {debtor_user_id: string;amount_paisa: number;applied_paisa: number}[], suggestions: {debtor_user_id: string;amount_paisa: number}[], userId: string): number {
  return transfers.filter(t=>t.debtor_user_id===userId).reduce((sum,t)=>sum+remainingPaisa(Number(t.amount_paisa), Number(t.applied_paisa)),0)+
    suggestions.filter(s=>s.debtor_user_id===userId).reduce((sum,s)=>sum+Number(s.amount_paisa),0)
}
