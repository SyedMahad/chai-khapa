import test from 'node:test'
import assert from 'node:assert/strict'
import { remainingPaisa, wholeRupeeRoundUp, totalOutstanding } from '../src/lib/settlementAmounts.ts'

test('partial payment leaves exact remaining balance',()=>{
 assert.equal(remainingPaisa(35000,20000),15000)
 assert.equal(remainingPaisa(35000,35000),0)
 assert.throws(()=>remainingPaisa(35000,35001))
})
test('rejected claim does not affect applied amount',()=>{
 const initial={ debtor_user_id:'debtor',amount_paisa:35000,applied_paisa:20000 }
 assert.equal(totalOutstanding([initial],[],'debtor'),15000)
 // A rejected second claim doesn't add anything to applied_paisa.
 assert.equal(totalOutstanding([initial],[],'debtor'),15000)
})
test('pending and already-paid transfer is not counted twice',()=>{
 const transfers=[{debtor_user_id:'me',amount_paisa:20000,applied_paisa:20000},{debtor_user_id:'me',amount_paisa:14000,applied_paisa:0}]
 const current=[{debtor_user_id:'me',amount_paisa:6000},{debtor_user_id:'other',amount_paisa:9999}]
 assert.equal(totalOutstanding(transfers,current,'me'),20000)
})
test('only optional round-up changes actual transfer, not amount applied',()=>{
 assert.equal(wholeRupeeRoundUp(33334),33400)
 assert.equal(wholeRupeeRoundUp(7000),7000)
 assert.equal(remainingPaisa(33334,10000),23334)
})
