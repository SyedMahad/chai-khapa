import test from 'node:test'
import assert from 'node:assert/strict'
import { singleGroupEntryDestination } from '../src/lib/entryRouting.ts'
import { whatsappInviteHref } from '../src/lib/sharing.ts'
const one = [{ id: '123', archived_at: null }]
test('one active group opens directly after login', () => {
  assert.equal(singleGroupEntryDestination('/', one), '/app/groups/123')
  assert.equal(singleGroupEntryDestination('/app', one), '/app/groups/123')
})
test('explicit overview navigation does not trigger automatic redirect', () => {
  assert.equal(singleGroupEntryDestination('/app/groups', one), null)
  assert.equal(singleGroupEntryDestination('/join/abc', one), null)
  assert.equal(singleGroupEntryDestination('/app/notifications', one), null)
})
test('multi-group, no-group, and archived-only users stay on overview', () => {
  assert.equal(singleGroupEntryDestination('/app', []), null)
  assert.equal(singleGroupEntryDestination('/app', [one[0], { id: '456', archived_at: null }]), null)
  assert.equal(singleGroupEntryDestination('/app', [{ id: '123', archived_at: '2026-10-31' }]), null)
})
test('one active group can be opened when another is archived', () => {
  assert.equal(singleGroupEntryDestination('/app', [...one, { id: '456', archived_at: '2026-10-31' }]), '/app/groups/123')
})
test('WhatsApp invite link is URL-encoded and includes bearer invite only in user-initiated share link', () => {
  const link = whatsappInviteHref('Office Chai', 'https://chai-khapa.pages.dev/join/abc')
  const url = new URL(link)
  assert.equal(url.origin, 'https://wa.me')
  assert.equal(url.pathname, '/')
  assert.match(url.searchParams.get('text') ?? '', /Office Chai/)
  assert.match(url.searchParams.get('text') ?? '', /chai-khapa.pages.dev\/join\/abc/)
})
