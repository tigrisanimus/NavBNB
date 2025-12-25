# NavBNB v2 Testnet Runbook

This runbook assumes Foundry is installed and `forge`/`cast` are available in your PATH.

## 1) Configure environment

```bash
export RPC_URL="https://bsc-testnet.example"
export PRIVATE_KEY="0x..." # deployer
export GUARDIAN="0x..."
export RECOVERY="0x..."
export STRATEGY_OWNER="0x..." # if strategy has an owner/guardian
```

## 2) Deploy the vault

```bash
forge script script/DeployVault.s.sol:DeployVault \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY"
```

Capture the deployed vault address from the broadcast logs and export it:

```bash
export VAULT="0x..."
```

## 3) Deploy the strategy (optional)

```bash
forge script script/DeployStrategy.s.sol:DeployStrategy \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY"
```

Capture the strategy address and export it:

```bash
export STRATEGY="0x..."
```

## 4) Wire strategy + parameters

```bash
forge script script/WireStrategyAndParams.s.sol:WireStrategyAndParams \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY"
```

## 5) Smoke test deposit / redeem / claim flows

### Deposit

```bash
cast send "$VAULT" \
  "deposit(uint256)" 0 \
  --value 0.5ether \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

### Redeem (may queue if liquidity is low)

```bash
cast send "$VAULT" \
  "redeem(uint256,uint256)" 100000000000000000 0 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

### Claim queue payouts

```bash
cast send "$VAULT" \
  "claim(uint256)" 32 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

### Failed receiver / claimable path

1. Deploy a receiver that reverts on BNB receives.
2. Redeem to queue it, then call `claim` so the send fails and is credited.
3. Withdraw claimable:

```bash
cast send "$VAULT" \
  "withdrawClaimable(uint256)" 0 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

### Emergency redeem path

```bash
cast send "$VAULT" \
  "emergencyRedeem(uint256,uint256)" 100000000000000000 0 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

## 6) Verify balances and queue state

```bash
cast call "$VAULT" "totalAssets()" --rpc-url "$RPC_URL"
cast call "$VAULT" "queueState()" --rpc-url "$RPC_URL"
cast call "$VAULT" "claimableBNB(address)" "$GUARDIAN" --rpc-url "$RPC_URL"
```
