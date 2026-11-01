import assert from 'node:assert/strict'
import test from 'node:test'

// Arithmetic invariants for the SQL migration. These are NOT a substitute
// for the LOCAL Supabase SQL integration test included in the package.
function netAfterReservedEarly(net, early) {
 const output = new Map(net)
 for (const {debtor, creditor, paisa} of early) {
   output.set(debtor, output.get(debtor) + paisa)
   output.set(creditor, output.get(creditor) - paisa)
 }
 return output
}

test('early claims reserve current-month obligations before final settlement', () => {
  const net = new Map([['payer', 5001], ['friend', -5001]])
  const residual = netAfterReservedEarly(net, [{debtor:'friend',creditor:'payer',paisa:5001}])
  assert.equal(residual.get('payer'), 0)
  assert.equal(residual.get('friend'), 0)
  assert.equal([...residual.values()].reduce((a,b)=>a+b,0),0)
})

test('partial reservation leaves only the unallocated amount for month-close', () => {
  const net = new Map([['payer', 10301], ['friend', -10301]])
  const residual = netAfterReservedEarly(net, [{debtor:'friend',creditor:'payer',paisa:5000}])
  assert.equal(residual.get('payer'), 5301)
  assert.equal(residual.get('friend'), -5301)
})

test('rounded payment never changes exact obligation', () => {
  const duePaisa = 5001
  const transferredPaisa = Math.ceil(duePaisa/100)*100
  assert.equal(transferredPaisa, 5100)
  assert.equal(transferredPaisa-duePaisa,99)
})

test('19:05 UTC is 00:05 next day in Karachi including month boundary', () => {
  const stamp = new Date('2026-10-31T19:05:00.000Z')
  const fmt = new Intl.DateTimeFormat('en-GB',{ timeZone:'Asia/Karachi', year:'numeric',month:'2-digit', day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'})
  const p=Object.fromEntries(fmt.formatToParts(stamp).map(x=>[x.type,x.value]))
  assert.deepEqual([p.year,p.month,p.day,p.hour,p.minute],['2026','11','01','00','05'])
})
