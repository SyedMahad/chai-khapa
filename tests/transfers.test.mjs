import test from 'node:test';
import assert from 'node:assert/strict';
import { computeTransfers } from '../src/lib/settlements.ts';

test('nets two creditors and one debtor exactly in paisa', () => {
  const x = computeTransfers([{user_id:'ali',net_paisa:7000},{user_id:'bilal',net_paisa:7000},{user_id:'hamza',net_paisa:-14000}]);
  assert.deepEqual(x, [{from:'hamza',to:'ali',amountPaisa:7000},{from:'hamza',to:'bilal',amountPaisa:7000}]);
});
test('preserves the smallest paisa', () => {
  assert.deepEqual(computeTransfers([{user_id:'a',net_paisa:1},{user_id:'b',net_paisa:-1}]),[{from:'b',to:'a',amountPaisa:1}]);
});
test('zero balances produce no payment suggestion', () => assert.deepEqual(computeTransfers([{user_id:'a',net_paisa:0}]),[]));
test('refuses inconsistent group totals', () => assert.throws(()=>computeTransfers([{user_id:'a',net_paisa:100}]),/sum to zero/));
