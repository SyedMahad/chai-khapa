import test from 'node:test'
import assert from 'node:assert/strict'
import { chooseInviteOrigin } from '../src/lib/urls.ts'

test('localhost without override shares local link for development', () => {
  assert.equal(chooseInviteOrigin('http://localhost:5173'),'http://localhost:5173')
})
test('localhost with override shares production link', () => {
  assert.equal(chooseInviteOrigin('http://localhost:5173','https://chai-khapa.pages.dev'), 'https://chai-khapa.pages.dev')
})
test('deployment follows new domain regardless of stale override', () => {
  assert.equal(chooseInviteOrigin('https://chai.example.com','https://old.pages.dev'), 'https://chai.example.com')
})
test('unsafe override cannot inject a different URL protocol', () => {
  assert.equal(chooseInviteOrigin('http://localhost:5173','javascript:alert(1)'), 'http://localhost:5173')
})
