# Opaque — Confidential Credit Protocol

> **Zama Developer Program Mainnet Season 2 — Builder Track Submission**

A fully onchain credit scoring system where financial inputs stay encrypted forever and only the final score is revealed — powered by Fully Homomorphic Encryption (FHE) via the Zama Protocol.

---

## The Problem

Every lending protocol on Ethereum today forces a choice between two bad options:

- **Overcollateralized** (Aave, Compound): You lock up more than you borrow. Capital-inefficient. No real credit assessment happens.
- **Social trust models** (Goldfinch, TrueFi): KYC-heavy, privacy-destroying, gated by institutions.

For DeFi to serve real credit demand — especially in underbanked markets — you need a third option: **prove you're creditworthy without showing anyone why.**

FHE makes this possible for the first time. That's Opaque.

---

## What Opaque Does

1. **User encrypts** five financial signals in-browser using the Zama Relayer SDK — nothing readable leaves the device
2. **Contract computes** a weighted FICO-like score (300–850) entirely on encrypted values — no plaintext ever produced
3. **Decryption oracle** reveals only the final score number — raw inputs remain sealed permanently onchain

The contract never sees your data. The FHE coprocessor handles arithmetic on ciphertexts. The KMS signs the decryption result. Nobody can tamper with it or read the inputs.

---

## Architecture

```
User's browser
│
├── Sliders (wallet age, tx count, repayment %, collateral ratio, defaults)
│
├── @zama-fhe/relayer-sdk → encrypt(values) → [ct1, ct2, ct3, ct4, ct5, inputProof]
│
└── submitProfile(ct1..ct5, inputProof)
         │
         ▼
OpaqueCredit.sol (Sepolia Testnet)
│
├── FHE.fromExternal() × 5          ← Deserialise + verify input attestation
├── FHE.allowThis() × 5             ← ACL: grant contract persistent ciphertext access
├── FHE.allow() × 5                 ← ACL: grant user read access to own inputs
│
├── _computeScore()                  ← Full score formula on encrypted values:
│   ├── FHE.mul, FHE.div, FHE.min   ← Weighted component arithmetic
│   ├── FHE.add × 4                  ← Accumulate score components
│   ├── FHE.gt, FHE.select           ← Encrypted conditional (default penalty)
│   └── FHE.max, FHE.min             ← Hard clamp to 300–850 range
│
├── encComputedScore (euint64)       ← Encrypted score stored onchain
│
└── requestScoreDecryption()
         │
         ▼
FHE.requestDecryption()
         │
         ▼
DecryptionOracle → KMS → scoreDecryptionCallback(requestId, cleartexts, proof)
         │
         ▼
FHE.checkSignatures()               ← Verify KMS signature on decryption
publicScore    = uint64             ← Score revealed (300–850)
scoreTier      = string             ← "Poor" / "Fair" / "Good" / "Excellent"
```

---

## Smart Contract

**File:** `OpaqueCredit.sol`

**Inherits:** `SepoliaConfig` (from `@fhevm/solidity/config/ZamaConfig.sol`)

**Key FHEVM v0.7 features used:**

| Feature | Usage |
|---------|-------|
| `externalEuint64` | Encrypted user inputs with client-side attestation |
| `FHE.fromExternal()` | Input deserialisation + proof verification |
| `FHE.allowThis()` | Grant contract ACL over ciphertexts |
| `FHE.allow()` | Grant user ACL to read their own inputs |
| `FHE.mul`, `FHE.div`, `FHE.add`, `FHE.sub` | Weighted score arithmetic on ciphertexts |
| `FHE.min`, `FHE.max` | Component capping + hard floor/ceiling |
| `FHE.gt`, `FHE.select` | Encrypted conditional logic (default penalty) |
| `FHE.requestDecryption()` | Async oracle decryption request |
| `FHE.checkSignatures()` | KMS signature verification in callback |

**Score formula — all operations run on encrypted values:**

```
base  = 300 (encrypted constant)

repayPoints  = min(repaymentBps × 7 / 200,        350)  // 35% weight · max 350 pts
collPoints   = min(min(collBps, 10000) × 3 / 100,  300)  // 30% weight · max 300 pts
agePoints    = min(min(ageDays, 3650) × 3 / 73,    150)  // 15% weight · max 150 pts
txPoints     = min(min(txCount, 1000) / 20,          50)  // 10% weight · max  50 pts

penalty      = min(defaultCount, 27) × 20                 // −20 pts per default
score        = select(score > penalty, score − penalty, 300)

score        = max(score, 300)  // hard floor
score        = min(score, 850)  // hard ceiling
```

**Output range:** 300–850 (FICO-inspired)

**Score tiers:**

| Range | Tier |
|-------|------|
| 300–579 | Poor |
| 580–669 | Fair |
| 670–739 | Good |
| 740–850 | Excellent |

---

## Setup & Deployment

### Prerequisites

```bash
node >= 18
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npm install @fhevm/solidity
```

### Install

```bash
git clone https://github.com/YOUR_USERNAME/opaque
cd opaque
npm install
```

### Configure

```bash
# Set your Sepolia RPC + deployer credentials in hardhat.config.ts
npx hardhat vars set MNEMONIC
npx hardhat vars set INFURA_API_KEY
npx hardhat vars set ETHERSCAN_API_KEY
```

### Deploy to Sepolia

```bash
npx hardhat deploy --network sepolia
```

The output will print your deployed contract address. Copy it.

### Verify on Etherscan

```bash
npx hardhat verify --network sepolia <CONTRACT_ADDRESS>
```

### Activate the Frontend

Open `index.html` and replace the placeholder address at the top of the script:

```javascript
// Before
const CONTRACT_ADDRESS = "0x0000000000000000000000000000000000000000";

// After
const CONTRACT_ADDRESS = "<YOUR_DEPLOYED_ADDRESS>";
```

Push to GitHub Pages. The site goes live automatically.

---

## Frontend Integration

The frontend (`index.html`) is a **single self-contained file** — no build step, no node_modules, works on GitHub Pages out of the box.

**Stack:** Ethers.js v6.7.1 (CDN) · Vanilla JS · Telegraf + IBM Plex Mono (fonts)

**Features included:**
- MetaMask connection with automatic Sepolia network switching
- Slider-based encrypted input form (wallet age, tx count, repayment rate, collateral ratio, defaults)
- Real-time protocol stats polling from `contract.getStats()` every 12 seconds
- Score gauge with animated arc, tier tabs, and progress bar
- Score history strip (persisted across page refresh via `sessionStorage`)
- Score share card with one-click post to X/Twitter
- Transaction hash links to Sepolia Etherscan after every action
- Public score lookup by wallet address (reads live from chain)
- FAQ accordion with plain-language answers for non-crypto audiences
- `chainChanged` + `accountsChanged` handlers
- Graceful no-MetaMask fallback state

**Replace simulated encryption** with real Relayer SDK calls after deploy:

```javascript
import { createFhevmInstance } from '@zama-fhe/relayer-sdk';

const instance = await createFhevmInstance({
  kmsContractAddress:  '0x...',  // from Zama docs
  aclContractAddress:  '0x...',  // from Zama docs
  network:  window.ethereum,
  chainId:  11155111,            // Sepolia
});

const input = instance.createEncryptedInput(CONTRACT_ADDRESS, userAddress);
input.add64(walletAgeDays);
input.add64(txCount);
input.add64(repaymentRatioBps);   // 0–10000 bps
input.add64(collateralRatioBps);  // 0–50000 bps
input.add64(defaultCount);
const encrypted = await input.encrypt();
```

**Replace simulated tx** with real contract call:

```javascript
const signer   = await provider.getSigner();
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, signer);

const tx = await contract.submitProfile(
  encrypted.handles[0],  // encWalletAge
  encrypted.handles[1],  // encTxCount
  encrypted.handles[2],  // encRepaymentRatio
  encrypted.handles[3],  // encCollateralRatio
  encrypted.handles[4],  // encDefaultCount
  encrypted.inputProof
);

const receipt = await tx.wait();
// receipt.hash → display Etherscan link
```

---

## Why Opaque Wins

| Feature | Opaque | Existing DeFi approaches |
|---------|--------|--------------------------|
| Input privacy | ✓ FHE-encrypted, never revealed onchain | ✗ Wallet data fully public, KYC required |
| Score verifiability | ✓ Onchain computation, KMS-signed | ✗ Off-chain API, trusted third party |
| Computation integrity | ✓ Smart contract logic, auditable | ✗ Black-box scoring engine |
| Composability | ✓ EVM-native, usable by any protocol | ✗ Siloed, not composable |
| Data custodianship | ✓ No custodian — inputs never leave device | ✗ Centralised data store |
| Accessibility | ✓ Any wallet, no KYC, no institution gate | ✗ Invitation-only or geography-locked |

---

## Roadmap

- **v1.1** — Real Zama Relayer SDK integration replacing simulated encryption flow
- **v1.2** — Score NFT as a portable verifiable credential (ERC-5484 soulbound)
- **v1.3** — Integration hooks for undercollateralized lending protocols
- **v1.4** — On-chain data attestation via Chainlink or UMA (proof of reserves, DEX activity)
- **v1.5** — Multi-chain deployment (Base, Ethereum Mainnet post-FHEVM launch)

---

## Project Structure

```
opaque/
├── index.html          # Frontend — single-file dApp, deploy as-is
├── OpaqueCredit.sol    # Smart contract (FHEVM v0.7, Sepolia)
├── README.md           # This file
├── hardhat.config.ts   # Hardhat + Sepolia network config
└── package.json
```

---

## Built With

- [Zama FHEVM v0.7](https://github.com/zama-ai/fhevm) — FHE coprocessor for EVM
- [Zama Relayer SDK](https://github.com/zama-ai/relayer-sdk) — Client-side input encryption
- [Ethers.js v6](https://ethers.org) — Ethereum provider and contract interaction
- Solidity `^0.8.24`
- Hardhat
- Sepolia Testnet

---

## License

BSD-3-Clause-Clear — matching Zama's open-source license

---

*Built for Zama Developer Program Mainnet Season 2 · Builder Track · May 2026*

*Created by [Soch](https://x.com/soch_tweet) ↗*
