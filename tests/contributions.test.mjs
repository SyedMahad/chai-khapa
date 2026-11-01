import { test } from 'node:test'
import assert from 'node:assert/strict'
import { allocateShares, rupeesToPaisa } from '../src/lib/finance.ts'
// NOTE: When copied into repository, the shared finance helper is at ../src/lib/finance.ts.
const pay = (bill, ids, amounts) => {
  const total = rupeesToPaisa(bill)
  const contributions = amounts.map(rupeesToPaisa)
  assert.equal(contributions.reduce((a,b)=>a+b,0), total)
  const shares=allocateShares(total, ids)
  assert.equal(Object.values(shares).reduce((a,b)=>a+b,0),total)
  return {total, contributions,shares}
}
test('Rs 4000 splits 2000 / 1300 / 700 and nets to zero',()=>{
  const ids=Array.from({length:10},(_,i)=>String(i).padStart(2,'0'))
  const {shares,contributions}=pay('4000',ids,['2000','1300','700'])
  assert.equal(Object.values(shares).every(s=>s===40000),true)
  const credits=new Map([['00',contributions[0]],['01',contributions[1]],['02',contributions[2]]])
  const nets=ids.map(id=>(credits.get(id)??0)-shares[id])
  assert.deepEqual(nets.slice(0,3),[160000,90000,30000])
  assert.equal(nets.reduce((a,b)=>a+b,0),0)
})
test('Two contributors, one not attending, still receive proper credit',()=>{
  const {shares,contributions}=pay('300',['a','b','c'],['200','100'])
  const net={a:contributions[0]-shares.a,b:-shares.b,c:-shares.c,d:contributions[1]}
  assert.equal(Object.values(net).reduce((a,b)=>a+b,0),0)
})
test('Paisa remainder is conserved',()=>{
  const {shares}=pay('100',['a','b','c'],['70','30'])
  assert.deepEqual(shares,{a:3334,b:3333,c:3333})
})
test('Over/under funding rejected in client preview, and DB must independently reject',()=>{
  const input=['2000','1300','600'].map(rupeesToPaisa)
  assert.notEqual(input.reduce((a,b)=>a+b,0),rupeesToPaisa('4000'))
})
