# UltraERC721

> A gas-optimized ERC-721 implementation combining ERC721A lazy initialization with bitmap scanning for ~256× faster `ownerOf()` lookups.

```
ERC721A (lazy init) × ERC721Psi (bitmap scan) = UltraERC721
```

---

## Overview

Standard ERC721A finds the owner of a token by scanning backwards through storage slots one-by-one — O(n) in the worst case. For a batch of 1,000 tokens, `ownerOf(999)` can cost **1,000 SLOADs**.

UltraERC721 replaces that sequential scan with a bitmap. Each `uint256` bucket covers 256 tokens simultaneously, so the same lookup costs **~4 SLOADs** regardless of batch size.

| Metric | UltraERC721 | ERC721A |
|--------|-------------|---------|
| Batch mint storage writes | **1** | 1 |
| `ownerOf` worst case | **O(n/256)** | O(n) |
| `ownerOf` (1000-token batch) | **~4 SLOADs** | ~1000 SLOADs |
| Single transfer | **O(1)** | O(1) |
| Full ERC721 interface | **✓** | ✓ |
| EIP-2981 royalty built-in | **✓** | ✗ |

---

## How It Works

### Lazy Initialization

When you mint a batch of N tokens, only the **first token** in the batch gets an explicit owner written to storage. All other tokens in the batch are "lazily" initialized — their owner is determined at read-time by scanning backwards.

```
Mint 5 tokens to Alice (IDs 0–4)
_owners: { 0: Alice }          ← only one write
_batchHead: bit 0 = 1          ← marks the batch start

ownerOf(3) → _owners[3] is zero → scan bitmap → find bit 0 → return _owners[0] = Alice
```

### Bitmap Scanning

The `_batchHead` bitmap marks which token IDs are the start of a batch (or have been individually transferred). Each `uint256` slot covers 256 consecutive token IDs.

```solidity
uint256 bucket = tokenId >> 8;        // which 256-slot bucket
uint256 bitPos  = tokenId & 0xff;     // position within bucket
uint256 mask    = (1 << bitPos) - 1;  // bits below tokenId in bucket
uint256 data    = _batchHead._data[bucket] & mask;

// _highestBitSet(data) → position of the nearest batch head
// one SLOAD per bucket instead of one SLOAD per token
```

### O(1) MSB via Yul Assembly

Finding the highest set bit uses a branch-free binary search — 8 shift operations, no loop:

```solidity
assembly {
    r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
    r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
    r := or(r, shl(5, lt(0xffffffff,         shr(r, x))))
    r := or(r, shl(4, lt(0xffff,             shr(r, x))))
    r := or(r, shl(3, lt(0xff,               shr(r, x))))
    r := or(r, shl(2, lt(0xf,                shr(r, x))))
    r := or(r, shl(1, lt(0x3,                shr(r, x))))
    r := or(r,        lt(0x1,                shr(r, x)))
}
```

---

## Installation

### Foundry

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

Place `UltraERC721.sol` in your `src/` directory and import it:

```solidity
import "./UltraERC721.sol";
```

### Hardhat / npm

```bash
npm install @openzeppelin/contracts
```

---

## Usage

### Minimal Collection

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./UltraERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MyNFT is UltraERC721, Ownable {
    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant MINT_PRICE = 0.05 ether;
    string private _baseTokenURI;

    constructor(string memory cid)
        UltraERC721("My NFT", "MNFT")
        Ownable(msg.sender)
    {
        _baseTokenURI = string(abi.encodePacked("ipfs://", cid, "/"));
    }

    function mint(uint256 qty) external payable {
        require(totalSupply + qty <= MAX_SUPPLY, "Max supply exceeded");
        require(msg.value >= MINT_PRICE * qty, "Insufficient payment");
        _safeMint(msg.sender, qty);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        require(id < totalSupply, "Nonexistent token");
        return string(abi.encodePacked(_baseTokenURI, _toString(id), ".json"));
    }

    function withdraw() external onlyOwner {
        (bool ok,) = owner().call{value: address(this).balance}("");
        require(ok);
    }
}
```

### Using the Contract Builder

Open `builder.html` in your browser to configure and generate a complete contract with:

- IPFS or Base URL metadata
- Reveal mechanism with placeholder URI
- EIP-2981 royalty (configurable rate + receiver)
- Public / Allowlist (Merkle) / Owner-only minting
- Pause, Burn, tokensOfOwner options

---

## API Reference

### Core (UltraERC721)

#### `ownerOf(uint256 tokenId) → address`
Returns the owner of `tokenId`. Uses bitmap scanning — ~256× faster than ERC721A for large batches.

#### `balanceOf(address owner) → uint256`
Returns the number of tokens owned by `owner`.

#### `transferFrom(address from, address to, uint256 tokenId)`
Transfers `tokenId` from `from` to `to`. Requires caller to be owner, approved address, or operator.

#### `safeTransferFrom(address from, address to, uint256 tokenId)`
#### `safeTransferFrom(address from, address to, uint256 tokenId, bytes data)`
Safe variants that call `onERC721Received` on contract recipients.

#### `approve(address to, uint256 tokenId)`
Approves `to` to transfer `tokenId`.

#### `setApprovalForAll(address operator, bool approved)`
Grants or revokes `operator` permission to manage all of caller's tokens.

#### `getApproved(uint256 tokenId) → address`
Returns the approved address for `tokenId`.

#### `isApprovedForAll(address owner, address operator) → bool`
Returns whether `operator` is approved for all tokens of `owner`.

#### `supportsInterface(bytes4 interfaceId) → bool`
Supports ERC165, ERC721, ERC721Metadata.

### Internal

#### `_mint(address to, uint256 quantity)`
Batch mints `quantity` tokens to `to`. One storage write regardless of quantity.

#### `_safeMint(address to, uint256 quantity)`
#### `_safeMint(address to, uint256 quantity, bytes data)`
Safe variants of `_mint`.

#### `_highestBitSet(uint256 x) → uint256`
Returns the index of the highest set bit in `x`. Branch-free Yul assembly, O(1).

---

## Security

### Transfer Safety
`transferFrom` enforces `_isApprovedOrOwner(msg.sender, tokenId, owner)` before every transfer. This checks:
1. Caller is the token owner
2. Caller is an approved operator (`isApprovedForAll`)
3. Caller is the individually approved address (`getApproved`)

### Next-Token Initialization
When token `N` is transferred, if token `N+1` has no explicit owner (still lazily pointing to the batch head), it is immediately initialized to the previous owner. This prevents ownership confusion after partial batch transfers.

```solidity
uint256 next = tokenId + 1;
if (next < totalSupply && _owners[next] == address(0)) {
    _owners[next] = from;
    _batchHead.set(next);
}
```

### Known Limitations

| Limitation | Notes |
|-----------|-------|
| `totalSupply` does not decrease on burn | Standard ERC721A behavior. Track burns separately if needed. |
| `ownerOf` is O(n/256), not O(1) | Still orders of magnitude faster than ERC721A for large batches. |
| No built-in enumeration | Add `tokensOfOwner()` via the builder or implement manually. |
| Mint event loop is O(quantity) | Required by the ERC721 standard; cannot be optimized away. |

---

## Gas Estimates

Estimates on Ethereum mainnet at 30 gwei. Values are approximate.

| Operation | UltraERC721 | Standard ERC721 |
|-----------|-------------|-----------------|
| Mint 1 token | ~65k gas | ~65k gas |
| Mint 10 tokens | ~95k gas | ~450k gas |
| Mint 100 tokens | ~300k gas | ~4.2M gas |
| `ownerOf` (batch of 1000, mid-batch) | ~2.5k gas | ~180k gas |
| `transferFrom` | ~55k gas | ~50k gas |

---

## File Structure

```
.
├── UltraERC721.sol      # Base contract (abstract)
├── MyNFT.sol            # Example collection
├── StandardERC721A.sol  # Reference implementation for benchmarking
├── landing.html         # Project landing page
├── builder.html         # Interactive contract generator
├── README.md            # This file
└── audit.pdf            # Security audit report
```

---

## EIP-2981 Royalty

When royalty is enabled (via builder or manually), the contract implements `IERC2981`:

```solidity
function royaltyInfo(uint256 /*tokenId*/, uint256 salePrice)
    external view returns (address receiver, uint256 amount)
{
    return (_royaltyReceiver, (salePrice * ROYALTY_BPS) / 10_000);
}
```

`ROYALTY_BPS` is in basis points: 500 = 5%, 250 = 2.5%, 1000 = 10%.

`supportsInterface` is overridden to include `0x2a55205a` (EIP-2981 interface ID).

---

## Metadata URI Formats

The builder supports two URI suffix formats:

| Format | Example | Use case |
|--------|---------|----------|
| `{id}.json` | `ipfs://Qm.../42.json` | IPFS, static hosting |
| `/{id}` (no extension) | `https://api.example.com/42` | API servers, dynamic metadata |

---

## Acknowledgements

- [ERC721A](https://github.com/chiru-labs/ERC721A) by Chiru Labs — lazy initialization concept
- [ERC721Psi](https://github.com/BoundlessDeveloper/ERC721Psi) by BoundLabs — bitmap scanning concept
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) — BitMaps, Ownable, ReentrancyGuard, MerkleProof

---

## License

MIT
