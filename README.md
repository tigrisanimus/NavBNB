# NavBNB v2

NavBNB v2 is a BNB-denominated NAV token on BSC. The vault tracks net assets (total assets minus obligations) and mints/burns shares against that NAV. Redemptions are processed through a FIFO queue with bounded processing, and the vault can optionally allocate assets to a yield strategy that implements `IBNBYieldStrategy`.

## Architecture

- **Vault**: `NavBNBv2` (`src/NavBNBv2.sol`) is the ERC20-like vault that issues shares, accounts for obligations, and orchestrates redemptions.
- **Roles**:
  - **guardian**: can pause/unpause, configure exit fees, set the liquidity buffer, and manage strategy proposals/activation.
  - **recovery**: can sweep untracked surplus BNB via `recoverSurplus`.
- **Strategy (optional)**: `IBNBYieldStrategy` implementations (e.g., `AnkrBNBYieldStrategy`) can hold assets for yield. The vault counts strategy assets in `totalAssets()` and maintains a configurable on-vault liquidity buffer.

## NAV, Assets, and Obligations

- **Total assets**: `totalAssets()` = vault BNB balance + `strategy.totalAssets()` (if set).
- **Total obligations**: `totalLiabilitiesBNB` (queued redemptions) + `totalClaimableBNB` (claimable credits from failed sends).
- **Net assets (NAV basis)**: `totalAssets - totalObligations`.
- **NAV**:
  - If `totalSupply == 0`, NAV is `1e18`.
  - Otherwise `NAV = (totalAssets - totalObligations) / totalSupply`.

## Deposits

- `deposit(minSharesOut)` mints shares based on NAV after deducting the mint fee.
- Fees: `MINT_FEE_BPS = 25` (0.25%).
- First deposit protection: if the vault already holds assets when `totalSupply == 0`, the contract mints shares to `recovery` to prevent free capture of pre-existing assets.
- Deposit fails if the vault is insolvent (`totalAssets <= totalObligations`).

## Redemptions, Queueing, and Claims

- **Redemption flow**: `redeem(tokenAmount, minBnbOut)` burns shares and attempts to pay BNB immediately.
- **FIFO queue**: if immediate liquidity is insufficient, the unpaid amount is queued in FIFO order.
- **Bounded processing**: queue processing uses `DEFAULT_MAX_STEPS = 32` to limit per-call work.
- **Minimum queue entry**: queued amounts must meet `minQueueEntryWei` (guardian-configurable) to prevent dust queue spam.
- **Claimable fallback**: if a queue payout transfer fails, the unpaid amount becomes `claimableBNB` for that user and is counted in obligations (`totalClaimableBNB`). Users can withdraw it via `withdrawClaimable(minOut)`.
- **Claiming**: `claim()` / `claim(maxSteps)` advances the queue and pays out as much as possible, bounded by `maxSteps`.
- **No hard daily cap**: cap helpers exist, but claims/redemptions do not enforce a daily limit.

## Liquidity Buffer and Strategy Behavior

- **Liquidity buffer**: `liquidityBufferBPS` (default `1000` = 10%) keeps a minimum BNB balance in the vault; excess is deposited into the strategy via `_investExcess()`.
- **Liquidity on demand**: `_ensureLiquidity()` withdraws from the strategy to satisfy redemptions/claims; it reverts if the withdrawal is insufficient.

## Strategy / LST Integration

The vault supports any `IBNBYieldStrategy`:

```solidity
interface IBNBYieldStrategy {
    function deposit() external payable;
    function withdraw(uint256 bnbAmount) external returns (uint256 received);
    function withdrawAllToVault() external returns (uint256 received);
    function totalAssets() external view returns (uint256);
}
```

- `totalAssets()` is treated as BNB-equivalent value and is included in vault NAV.
- **Strategy switching safety**: the current strategy must report `totalAssets() == 0` before it can be replaced. A new strategy must be a contract and must also report `totalAssets() == 0` on activation.
- **Timelock**: strategy changes use `proposeStrategy()` + `activateStrategy()` with `strategyTimelockSeconds` (default `1 days`, max `7 days`). Direct `setStrategy()` is only allowed when the timelock is explicitly disabled (`strategyTimelockSeconds == 0`).

### AnkrBNB Strategy (optional)

`AnkrBNBYieldStrategy` is an example strategy that stakes BNB into the Ankr staking pool and swaps ankrBNB back to BNB via a router on withdrawals. It includes:

- Guardian-controlled slippage and valuation haircut limits (`maxSlippageBps`, `valuationHaircutBps`).
- A pause mechanism for deposits/withdrawals.
- A restricted token recovery path (only while paused) to the vault or a designated recovery address.

This strategy is included for integration/testing and should be treated as an external dependency with its own risks.

## Fees and Exit Timing

- **Mint fee**: `MINT_FEE_BPS = 25` (0.25%).
- **Redeem fee**: `REDEEM_FEE_BPS = 25` (0.25%).
- **Emergency redeem fee**: `EMERGENCY_FEE_BPS = 1000` (10%).
- **Time-based exit fee**: configured by guardian via `setExitFeeConfig(minExitSeconds, fullExitSeconds, maxFeeBps)`.
  - If `block.timestamp < lastDeposit + minExitSeconds`, users pay `maxFeeBps`.
  - The fee linearly decays to 0 until `fullExitSeconds`.
- Fees remain in the vault and accrue to remaining shareholders (no direct fee recipient).

## Emergency Redeem

`emergencyRedeem(tokenAmount, minBnbOut)` bypasses the queue but:

- Requires `totalAssets >= totalObligations`.
- Pays from current reserves only: `bnbOut <= reserveBNB()` where `reserveBNB = totalAssets - totalObligations`.
- Charges `EMERGENCY_FEE_BPS` (rounded up on remainder) and reverts if payout is zero.

## Daily Throttling / Pacing (Current Behavior)

`NavBNBv2` includes cap tracking helpers (`capForDay`, `capRemainingToday`) and storage (`spentToday`, `capBaseBNB`), but **redemption and claim flows do not currently enforce a daily cap**. These fields are unused in redemption processing and should be treated as **not yet implemented** throttling.

## Safety Invariants

- **Solvency checks**: most external flows require `totalAssets >= totalObligations` to proceed.
- **NAV floor**: NAV is zero if assets are less than or equal to obligations.
- **FIFO queue accounting**: queued amounts are tracked in `totalLiabilitiesBNB`; failed sends are moved to `claimableBNB` and tracked in `totalClaimableBNB`.
- **Strategy switching**: cannot switch strategies if either the current or new strategy holds assets.
- **Liquidity buffer**: investments only occur when vault balance exceeds the buffer target.
- **Direct BNB sends revert**: the vault only accepts BNB from the strategy or WBNB unwraps; forced sends become untracked surplus.

## Threat Model / Known Limitations

- **External strategy risk**: strategy contracts and integrations (DEX/router, staking pool) are external dependencies and can fail or be compromised.
- **No guaranteed yield**: returns depend entirely on external strategy performance; losses reduce NAV.
- **Queue delays**: redemptions can be queued when liquidity is insufficient; claims are processed in bounded steps.
- **Daily throttling not enforced**: cap helpers are present but not wired into redemptions/claims.
- **Forced BNB transfers**: selfdestruct/forced transfers increase `untrackedSurplusBNB` and can only be recovered by `recovery` via `recoverSurplus`.
- **No on-chain governance/timelock beyond strategy changes**: only the guardian can configure key parameters.

## Local Development

### Build

```shell
forge build
```

### Format

```shell
forge fmt
```

### Test

```shell
forge test -vvv
```

### Foundry toolchain

```shell
forge --version
```
