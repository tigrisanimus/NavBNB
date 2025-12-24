# NavBNB v2 Spec

## Summary
NavBNB v2 is a BNB-denominated NAV token on BSC. Shares represent a claim on **net assets**:

```
netAssets = totalAssets - totalObligations
NAV = netAssets / totalSupply
```

`totalAssets` includes vault-held BNB plus any assets reported by an optional yield strategy. `totalObligations` includes queued redemption liabilities and claimable credits from failed sends.

## Architecture

- **Vault**: `NavBNBv2` (`src/NavBNBv2.sol`) issues shares, tracks obligations, and processes redemptions through a FIFO queue.
- **Roles**:
  - **guardian**: pause/unpause, adjust liquidity buffer, configure exit fees, manage strategy proposals and activation.
  - **recovery**: can sweep untracked surplus BNB via `recoverSurplus`.
- **Strategy (optional)**: any contract implementing `IBNBYieldStrategy` can hold assets on behalf of the vault.

## Parameters (as implemented)

- `MINT_FEE_BPS = 25` (0.25%).
- `REDEEM_FEE_BPS = 25` (0.25%).
- `EMERGENCY_FEE_BPS = 1000` (10%).
- `CAP_BPS = 1000` (10%). **Not enforced** in redemption/claim flows (see Daily Throttling).
- `DEFAULT_MAX_STEPS = 32` for queue processing.
- `liquidityBufferBPS = 1000` (10%) default.
- `strategyTimelockSeconds = 1 days` default, `MAX_STRATEGY_TIMELOCK_SECONDS = 7 days`.
- Exit fee config: `minExitSeconds`, `fullExitSeconds`, `maxExitFeeBps` (seconds and bps).

## Assets, Obligations, and NAV

- **totalAssets**: `address(this).balance + strategy.totalAssets()` (if set).
- **totalObligations**: `totalLiabilitiesBNB + totalClaimableBNB`.
- **NAV**:
  - `totalSupply == 0`: NAV is `1e18`.
  - `totalAssets <= totalObligations`: NAV is `0`.
  - Else `NAV = (totalAssets - totalObligations) * 1e18 / totalSupply`.

## Deposits

- `deposit(minSharesOut)` mints shares at NAV after subtracting `MINT_FEE_BPS`.
- Insolvency guard: if `totalAssets <= totalObligations`, deposits revert.
- First-deposit protection: if the vault already has assets and `totalSupply == 0`, shares are minted to `recovery` to prevent free capture.

## Redemptions, Queue, and Claims

- `redeem(tokenAmount, minBnbOut)` burns shares and attempts immediate payment.
- If liquidity is insufficient, the remainder is queued (`totalLiabilitiesBNB`).
- **FIFO queue**: entries are paid in order; queue processing is bounded by `maxSteps`.
- **Failed transfer handling**: if a queued payout fails, the unpaid amount is moved to `claimableBNB` and tracked in `totalClaimableBNB`.
- `claim()` / `claim(maxSteps)` advances the queue and pays as much as possible.
- `withdrawClaimable(minOut)` lets users pull `claimableBNB` (subject to solvency and liquidity).

## Emergency Redeem

- `emergencyRedeem(tokenAmount, minBnbOut)` bypasses the queue.
- Requires `totalAssets >= totalObligations` and only pays from reserves (`reserveBNB = totalAssets - totalObligations`).
- Fee is `EMERGENCY_FEE_BPS` with rounding up on remainder.

## Liquidity Buffer and Strategy

- The vault targets a buffer of `liquidityBufferBPS` of total assets.
- Excess BNB is deposited into the active strategy via `deposit()`.
- `_ensureLiquidity` withdraws from the strategy when on-vault balance is insufficient.

## Strategy / LST Integration

`IBNBYieldStrategy` defines the interface:

```
function deposit() external payable;
function withdraw(uint256 bnbAmount) external returns (uint256 received);
function withdrawAllToVault() external returns (uint256 received);
function totalAssets() external view returns (uint256);
```

Safety constraints:

- Existing strategy must report `totalAssets() == 0` before replacement.
- New strategy must be a contract and report `totalAssets() == 0` at activation.
- Strategy changes are timelocked via `proposeStrategy` and `activateStrategy` unless timelock is disabled.

## Daily Throttling / Pacing (Current Behavior)

The vault includes cap helper functions and storage (`capForDay`, `capRemainingToday`, `spentToday`, `capBaseBNB`), but **does not currently apply a daily cap in redemption or claim processing**. This is **not yet implemented** throttling.

## Safety Invariants

- Redemptions/claims require `totalAssets >= totalObligations`.
- Queued liabilities and claimables are always tracked in obligations.
- NAV is derived from net assets; if net assets are zero, NAV is zero.
- Strategy switching is only allowed when both old and new strategies are empty.

## Threat Model / Known Limitations

- Strategies are external dependencies and can fail or lose value.
- No guaranteed yield; NAV can decrease if strategy assets lose value.
- Queue processing is bounded; large queues may take multiple transactions to clear.
- Daily throttling data exists but is not enforced.

## Notes on V1

`src/NavBNB.sol` is a prior version preserved for testing/reference. The documentation above reflects **NavBNB v2** behavior only.
