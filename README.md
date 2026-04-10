# BaseYield — Smart Contracts

Non-custodial LP automation on Base L2. Users configure safeguard conditions on-chain. Gelato executes rebalances when conditions are met. Developer earns 7.5% of collected trading fees.

## Architecture

```
BaseYieldManager.sol
│
├── setConditions(tokenId, conditions)   — user stores safeguards on-chain
├── activate(tokenId)                    — enables automation for a position
├── pause(tokenId)                       — emergency stop (user only, instant)
├── resume(tokenId)                      — resume after pause
├── deactivate(tokenId)                  — graceful stop
│
├── checkUpkeep(tokenId, owner)          — Gelato resolver (view, gas-free)
└── rebalance(tokenId, owner)            — Gelato execution (onlyGelato)
```

**Key properties:**
- Non-custodial — contract never holds user funds except atomically during rebalance
- Non-upgradeable — no proxy, no admin, immutable after deployment
- User-governed — all conditions set by user, enforced by contract
- 7.5% fee on collected trading fees only — never on principal

## Setup

### Prerequisites

- [Foundry](https://getfoundry.sh) — `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- An [Alchemy](https://alchemy.com) account for Base RPC
- A [BaseScan](https://basescan.org) API key for contract verification

### Install

```bash
git clone https://github.com/altrudev/baseyield-contracts
cd baseyield-contracts

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts

# Copy environment template
cp .env.example .env
# Edit .env and fill in your values
```

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# Run with verbose output
forge test -vvv

# Run a specific test
forge test --match-test testRebalanceHappyPath -vvv

# Run with gas report
forge test --gas-report

# Run fuzz tests with more runs
forge test --fuzz-runs 10000
```

### Coverage

```bash
forge coverage --report lcov
```

## Deployment

### Base Sepolia (testnet)

```bash
# Verify your .env has BASE_SEPOLIA_RPC, DEPLOYER_PRIVATE_KEY,
# SLIPSTREAM_NPM_ADDRESS, GELATO_AUTOMATE_ADDRESS, FEE_RECIPIENT_ADDRESS

forge script script/DeployTestnet.s.sol \
  --rpc-url base_sepolia \
  --broadcast \
  --verify \
  -vvvv
```

### Base Mainnet

```bash
# ⚠️  Do NOT deploy to mainnet without a completed professional audit
# ⚠️  Use a hardware wallet via cast wallet for mainnet deployments

forge script script/Deploy.s.sol \
  --rpc-url base_mainnet \
  --broadcast \
  --verify \
  --ledger \
  -vvvv
```

## Contract Addresses

| Network      | Address | Status |
|---|---|---|
| Base Sepolia | TBD | Not yet deployed |
| Base Mainnet | TBD | Not yet deployed — pending audit |

## Constructor Arguments

| Argument | Description | Source |
|---|---|---|
| `_slipstreamNpm` | Aerodrome Slipstream NonfungiblePositionManager | basescan.org / aerodrome.finance/docs |
| `_gelatoAutomate` | Gelato Automate contract on Base | docs.gelato.network/contract-addresses |
| `_feeRecipient` | Your wallet address to receive protocol fees | Your choice |

## Audit Status

**⚠️ NOT YET AUDITED. DO NOT USE WITH REAL FUNDS.**

A professional smart contract audit is scheduled prior to mainnet deployment. The audit report will be published here when complete.

## Licence

MIT — see [LICENSE](LICENSE)

Copyright (c) 2026 Sean / ALTRU.dev
