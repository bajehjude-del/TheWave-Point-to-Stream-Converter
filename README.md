# The Wave Point-to-Stream Converter

A Solidity smart contract that bridges [Drips Wave](https://drips.network) sprint cycles with the Drips streaming protocol. At the end of each sprint, a Wave manager uploads a Merkle root of contributor point allocations. Contributors then claim a continuous ERC-20 token stream proportional to their points — ensuring compensation flows over time rather than arriving as a lump sum.

---

## Overview

In a Drips Wave, contributors earn **Points** during a sprint by completing work. This contract solves the distribution problem: instead of paying everyone at once when the sprint ends, it converts each contributor's point share into a **Drip** — a per-second token stream that runs for a configurable duration.

The result is that contributors are paid continuously and proportionally, while the manager retains control over sprint lifecycle and can recover unclaimed funds.

---

## How It Works

### 1. Sprint Setup (Manager)

The Wave manager calls `newSprint`, providing:

- A **Merkle root** of the sprint's point allocations (leaves: `keccak256(abi.encodePacked(contributorAddress, points))`)
- The **ERC-20 token** to distribute
- The **total capacity** — the total token amount to stream across all contributors
- The **stream duration** — how many seconds each contributor's stream runs
- The **total points** — the sum of all contributor point allocations

The manager transfers `totalCapacity` tokens into the contract at this step.

### 2. Claiming a Stream (Contributor)

Each contributor calls `claim` with:

- The `sprintId`
- Their **Merkle proof** (generated off-chain from the same tree the manager committed to)
- Their **point allocation**

The contract verifies the proof, computes the contributor's proportional stream rate, and calls `drips.setStreams` to start a live token stream from the contract's Drips account to the contributor's address.

### 3. Receiving Funds

Once the stream is active, the contributor's Drips balance accrues per-second. They can collect it at any time through the standard Drips protocol flow (`receiveStreams` → `split` → `collect`).

---

## Stream Rate Formula

Each contributor's per-second stream rate is calculated as:

```
amtPerSec (scaled) = (userPoints × totalCapacity × AMT_PER_SEC_MULTIPLIER)
                     / (totalPoints × streamDuration)
```

Where `AMT_PER_SEC_MULTIPLIER = 1_000_000_000` is the fixed-point scaling factor used by the Drips protocol to allow sub-token-per-second precision.

**Example:** A contributor with 40 out of 100 total points, in a sprint with 1,000 USDC capacity over 30 days, receives:

```
share     = 40 / 100 = 40%
capacity  = 400 USDC
rate      = 400 USDC / (30 × 86400 seconds) ≈ 0.000154 USDC/sec
```

---

## Architecture

```
src/
├── WaveConverter.sol      # Main contract
└── lib/
    └── MerkleProof.sol    # Minimal Merkle verifier

test/
└── WaveConverter.t.sol    # 20 Foundry tests (mock Drips + ERC-20)

script/
└── Deploy.s.sol           # Deployment script
```

### WaveConverter

Registers itself as a **Drips driver** on deployment, giving it a unique `driverId` and a deterministic `accountId`. All streams originate from this account.

Key state:

| Variable | Description |
|---|---|
| `drips` | The Drips protocol contract |
| `driverId` | This contract's registered Drips driver ID |
| `accountId` | This contract's Drips account ID (`driverId \| 0x00...00 \| address`) |
| `manager` | Address authorised to create/close sprints |
| `sprints` | Mapping of sprint ID → Sprint struct |
| `claimed` | Double-claim guard: `sprintId → contributor → bool` |

### Sprint struct

```solidity
struct Sprint {
    bytes32 merkleRoot;    // commitment to the point allocations
    IERC20  token;         // token being streamed
    uint128 totalCapacity; // total tokens deposited for this sprint
    uint32  streamDuration;// seconds each stream runs
    uint32  totalPoints;   // sum of all contributor points
    bool    active;        // false after closeSprint is called
}
```

### MerkleProof

A minimal, self-contained Merkle verifier compatible with the standard sorted-pair tree format (same as OpenZeppelin's `MerkleProof`). Leaves are sorted before hashing at each level, making the tree order-independent.

---

## Contract Interface

### Manager functions

```solidity
// Create a new sprint and deposit tokens
function newSprint(
    bytes32 merkleRoot,
    IERC20  token,
    uint128 totalCapacity,
    uint32  streamDuration,
    uint32  totalPoints
) external returns (uint256 sprintId);

// Prevent further claims on a sprint
function closeSprint(uint256 sprintId) external;

// Withdraw tokens not consumed by streams
function recoverTokens(IERC20 token, uint256 amount) external;

// Hand off manager role
function transferManager(address newManager) external;
```

### Contributor function

```solidity
// Verify proof and start a proportional Drips stream
function claim(
    uint256   sprintId,
    bytes32[] calldata proof,
    uint32    points
) external;
```

### Custom errors

| Error | Condition |
|---|---|
| `NotManager` | Caller is not the current manager |
| `SprintNotActive` | Sprint has been closed |
| `AlreadyClaimed` | Contributor already claimed this sprint |
| `InvalidProof` | Merkle proof does not verify |
| `ZeroPoints` | Points value is zero |
| `StreamRateTooLow` | Computed rate is below Drips' `minAmtPerSec` |
| `CapacityOverflow` | Contributor's token share exceeds `int128` max |

---

## Off-chain: Building the Merkle Tree

The Merkle tree must be built with the same leaf encoding the contract uses:

```js
// Node.js example using @openzeppelin/merkle-tree
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

const entries = [
  ["0xAlice...", 40],
  ["0xBob...",   60],
];

const tree = StandardMerkleTree.of(entries, ["address", "uint32"]);
console.log("Root:", tree.root);

// Generate proof for Alice (index 0)
const proof = tree.getProof(0);
```

> The leaf encoding in the contract is `keccak256(abi.encodePacked(address, uint32))`. Ensure your off-chain library uses the same packed encoding (not ABI-encoded with padding).

---

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```shell
forge build
```

### Test

```shell
forge test -v
```

All 20 tests pass against a mock Drips contract and mock ERC-20, covering:

- Constructor (driver registration, account ID derivation)
- `newSprint` (basic flow, access control, sprint counter)
- `claim` (single contributor, two contributors proportional split, double-claim, invalid proof, wrong points, zero points, closed sprint)
- `closeSprint`, `recoverTokens`, `transferManager` (access control)
- `MerkleProof` library (single leaf, two leaves, invalid proof)

### Format

```shell
forge fmt
```

---

## Deployment

Set environment variables and run the deployment script:

```shell
export DRIPS_ADDRESS=<drips_contract_address>   # see drips-network/contracts/deployments/
export MANAGER_ADDRESS=<your_manager_address>

forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### Drips contract addresses

| Network | Address |
|---|---|
| Ethereum mainnet | See [deployments/ethereum.json](https://github.com/drips-network/contracts/blob/main/deployments/ethereum.json) |
| Sepolia | See [deployments/sepolia.json](https://github.com/drips-network/contracts/blob/main/deployments/sepolia.json) |
| Optimism | See [deployments/optimism.json](https://github.com/drips-network/contracts/blob/main/deployments/optimism.json) |
| Optimism Sepolia | See [deployments/optimism-sepolia.json](https://github.com/drips-network/contracts/blob/main/deployments/optimism-sepolia.json) |

---

## Security Considerations

- **Merkle root is immutable per sprint.** Once `newSprint` is called, the point allocations are fixed. A new sprint must be created to change them.
- **Claims are one-per-address per sprint.** The `claimed` mapping prevents double-claiming.
- **Receiver account ID uses `driverId=0` as a placeholder.** In production, the real `AddressDriver.driverId()` should be used so contributors can collect via the standard AddressDriver flow. Update `_addressAccountId` accordingly after deployment.
- **`recoverTokens` is unrestricted in token type.** The manager can recover any token held by the contract, including tokens deposited for active sprints. Ensure the manager is a trusted, ideally multisig-controlled address.
- **Stream rate precision.** Very small point allocations relative to `totalPoints` may produce a rate below `minAmtPerSec`, causing the claim to revert with `StreamRateTooLow`. Ensure minimum point thresholds are enforced off-chain when building the Merkle tree.

---

## License

GPL-3.0-only
