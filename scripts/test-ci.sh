#!/usr/bin/env bash
set -euo pipefail

echo "=== TOOLCHAIN ==="
forge --version
cast --version || true

echo "=== CONFIG ==="
echo "FOUNDRY_PROFILE=${FOUNDRY_PROFILE:-}"
cat foundry.toml

echo "=== CLEAN ==="
rm -rf out cache

echo "=== FORMAT ==="
FOUNDRY_PROFILE=ci forge fmt --check

echo "=== BUILD ==="
FOUNDRY_PROFILE=ci forge build

echo "=== TEST (CI PARITY) ==="
rm -rf out cache
FOUNDRY_PROFILE=ci forge test -vvv

rm -rf out cache
FOUNDRY_PROFILE=ci forge test -vvv --fuzz-runs 5000
