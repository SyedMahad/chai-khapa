# Phase 3.9 accounting invariants

- Expense payment/contribution and settlement payment are separate ledger events.
- A month's consumption is netted by group and month; individual sessions are explanation-only.
- For each settlement transfer: `original = applied + remaining`, with `remaining >= 0`.
- One pending claim per transfer at a time. No direct table writes by browser.
- Approved claim adds `applied_paisa` to the original transfer **once**; rejection adds zero.
- Status `confirmed` only when `applied_paisa = amount_paisa`; a partial transfer has status `unpaid` (or `awaiting_confirmation` when a claim is waiting).
- Extra paisa from optional rounding is kept in `rounding_adjustment_paisa`; the obligation decreases only by the exact applied amount.
- An early payment creates a transfer against that group's current month, and the full early transfer amount is excluded from month-end residual transfer generation even before the recipient confirms. If rejected, that early transfer remains payable; it is not recreated by month-close.
- Concurrent batch submissions lock transfers by UUID order; duplicate `request_id` returns the existing claim IDs (or errors on altered request details).
- Historic expense shares, contributors, finalized periods, and original transfer amounts are never rewritten by Phase 3.9. Only new accounting fields are backfilled.

## Explicit caveat about overall balances

`get_group_balances` was updated to account for *all confirmed claim amounts* via `settlement_transfers.applied_paisa`, not only fully confirmed transfers. The UI's cross-month outstanding summary is based on outstanding net obligations; unfinalized past months are flagged rather than silently approximated as finalized debts.
