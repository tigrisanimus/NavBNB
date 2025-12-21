# NavBNB Spec (MVP)

## Summary
NavBNB is a BNB-backed NAV token on BSC.
NAV = reserveBNB / totalSupply.

## Immutable Parameters
- Mint fee: 25 bps (0.25%)
- Redeem fee: 25 bps (0.25%)
- Daily instant redemption cap: 100 bps (1.00%) of reserves/day
- Queue: pro-rata
- Transfers: open
- Admin: none (no pause, no parameter changes)
- No reserve withdrawals (only user redemptions/claims)

## Core Functions
- deposit() payable
- redeem(uint256 tokenAmount)
- claim()
- nav() view

## Queue Accounting Invariants
- queuedTotalOwedBNB == sum(userOwedBNB[...])
- user can never claim more than owed
- spentToday[day] <= capPerDay
