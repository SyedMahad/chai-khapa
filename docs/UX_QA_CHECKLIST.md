# Chai Khapa — Page-by-page UI/UX acceptance checklist

Test **desktop 1440×900 and 1280×720**, **mobile 390×844 and 360×800**, and **tablet 768×1024**. Confirm keyboard Tab/Enter behavior at each breakpoint. Also test a real Android PWA and, if possible, iPhone Add to Home Screen. Check that no screen scrolls horizontally or clips a primary action.

## Public landing, Privacy, Terms
- [ ] On a normal desktop viewport the headline, CTA, three steps, and footer fit or scroll naturally without overlap.
- [ ] On mobile the hero and three steps stack into one column and no text is cropped.
- [ ] Google Sign-In returns to the correct origin.
- [ ] Public `/privacy/` and `/terms/` work while signed out (verify in incognito and on Cloudflare).

## Authenticated entry and navigation
- [ ] With exactly one active group, fresh sign-in to `/app` opens `/app/groups/<id>`.
- [ ] With zero groups, opens global overview. With multiple groups, opens global overview.
- [ ] With one active and one archived group, opens the active group.
- [ ] A direct `/join/<token>` is not hijacked by automatic single-group redirect.
- [ ] Explicit Overview navigation stays on Overview; browser Back works.
- [ ] Keyboard focus is visible. Sidebar and mobile bottom navigation are usable.

## Overview and Groups
- [ ] All owned/joined groups appear as full-card clickable targets; long group names wrap or truncate safely.
- [ ] Empty state has a working Create Group path.
- [ ] Balances match signed-in identity and stay separate by group.
- [ ] Hover only changes interactive areas on desktop. Mobile does not rely on hover.
- [ ] Loading and error states do not show stale previous-user data after account switch.

## Group details: Overview / People / Settings
- [ ] Tabs align across the full group page, with content starting on the same baseline.
- [ ] Active group stats do not overflow on a 360px screen.
- [ ] Record Session is prominent. Recent session rows open Activity.
- [ ] Invitation controls appear on Overview; generating an invite auto-copies when clipboard permission allows.
- [ ] Copy Again works. WhatsApp opens a **prefilled** invite message that has the correct public URL.
- [ ] Local URLs visibly warn when there is no production override.
- [ ] People and balances align names, avatars, and money. Only group members are visible.
- [ ] Rename/transfer/archive use inline confirmation or clear actions; delete/leave appear under Settings only.
- [ ] Group deletion remains server-blocked when financial history exists.

## Record Session / Activity
- [ ] Amount input is first and opens the numeric keyboard on mobile.
- [ ] 'Same as last time' attendees are preselected for the same group only.
- [ ] Payer is included; shares add up to bill in paisa, including non-divisible bills.
- [ ] Save displays busy state and does not duplicate requests on retry.
- [ ] After saving a session, user returns to the group page; newly saved session and balances are current.
- [ ] Activity expands an expense and clearly lists each participant's share.

## Settlements
- [ ] Current net balance and finalized month-end transfers are visually distinct.
- [ ] Previous month is shown in Asia/Karachi timezone; closing is currently **manual**.
- [ ] Close Month uses in-page confirmation; cancel leaves records unchanged.
- [ ] All / To pay / To receive filters display appropriate rows and empty states.
- [ ] Mark as Paid requires an explicit confirmation that funds were already transferred externally.
- [ ] Recipient sees a pending claim and can Confirm Received or Not Received.
- [ ] Only confirmed receipts clear obligations; rejection leaves amount outstanding.
- [ ] Accurate paisa values are preserved even when rounded cash amounts are recorded.
- [ ] One account cannot act for another or close a group it does not own.

## Notifications / Profile / PWA
- [ ] Unread counter, notification rows, Mark Read, and Mark All Read align on desktop and mobile.
- [ ] New expense and settlement notifications appear after refresh and open the relevant screen.
- [ ] Name editing refreshes group displays without a stale 'Colleague' placeholder.
- [ ] Profile form and completion card have balanced spacing; no awkward blank areas.
- [ ] PWA manifest and icon load; Android install prompt appears where supported; iPhone shows Add to Home Screen instructions.
- [ ] Service worker does not cache authenticated ledger data as if it were current while offline.

## Release blockers
- [ ] `npm run build` passes locally.
- [ ] Login and expense entry tested with **two real Google accounts**.
- [ ] RLS multi-user authorization tests completed on a **local** Supabase test database.
- [ ] Read/write permissions verified after settlement migrations.
- [ ] No secret keys or invite tokens committed to GitHub.
- [ ] Production pages, callback URLs, WhatsApp links, and PWA installation tested from the Cloudflare site.
