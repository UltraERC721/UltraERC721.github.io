// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/structs/BitMaps.sol";

/// @title UltraERC721
/// @author Based on ERC721A (Chiru Labs) + ERC721Psi (BoundLabs) concepts
/// @notice A gas-optimized ERC721 combining lazy initialization with bitmap scanning.
///         Batch minting is O(1) storage writes.
///         ownerOf() is O(n/256) vs ERC721A's O(n) — ~256x faster in the worst case.
///         Single transfers are O(1).
abstract contract UltraERC721 {
    using BitMaps for BitMaps.BitMap;

    // =========================================================================
    // Storage
    // =========================================================================

    string public name;
    string public symbol;

    uint256 public totalSupply;

    // Explicit ownership: only set for batch heads and transferred tokens
    mapping(uint256 => address) internal _owners;

    // Token balance per address
    mapping(address => uint256) internal _balances;

    // Single-token approvals
    mapping(uint256 => address) private _tokenApprovals;

    // Operator approvals (owner => operator => approved)
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // Marks the first token of each batch mint (and each individually transferred token)
    BitMaps.BitMap private _batchHead;

    // =========================================================================
    // Custom Errors
    // =========================================================================

    error NotOwnerOrApproved();
    error TransferToZeroAddress();
    error MintToZeroAddress();
    error MintZeroQuantity();
    error TransferFromIncorrectOwner();
    error OwnerQueryForNonexistentToken();
    error ApproveToCaller();
    error ApprovalToCurrentOwner();
    error TransferToNonERC721ReceiverImplementer();

    // =========================================================================
    // Events (ERC721 standard)
    // =========================================================================

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    // =========================================================================
    // ERC165
    // =========================================================================

    /// @notice Query if this contract implements an interface.
    /// @dev Supports ERC165 (0x01ffc9a7) and ERC721 (0x80ac58cd).
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165
            interfaceId == 0x80ac58cd || // ERC721
            interfaceId == 0x5b5e139f;   // ERC721Metadata
    }

    // =========================================================================
    // ERC721 View Functions
    // =========================================================================

    /// @notice Returns the number of tokens owned by `owner`.
    function balanceOf(address owner) public view returns (uint256) {
        return _balances[owner];
    }

    /// @notice Returns the owner of `tokenId`.
    /// @dev Uses bitmap scanning to find the nearest batch head in O(n/256) time.
    ///      This is ~256x faster than ERC721A's sequential backward scan.
    function ownerOf(uint256 tokenId) public view virtual returns (address) {
        if (tokenId >= totalSupply) revert OwnerQueryForNonexistentToken();

        // Fast path: token has been explicitly initialized (batch head or transferred)
        address owner = _owners[tokenId];
        if (owner != address(0)) {
            return owner;
        }

        // Slow path: scan backward through the bitmap to find the nearest batch head.
        // Each bucket covers 256 tokens, so we skip 256 sequential SLOADs at a time.
        uint256 bucket = tokenId >> 8;
        uint256 bitPos = tokenId & 0xff;

        // Build a mask for all bits strictly before `bitPos` in the current bucket
        // (i.e., tokens with smaller IDs in the same bucket).
        if (bitPos > 0) {
            uint256 mask = (1 << bitPos) - 1;
            uint256 bucketData = _batchHead._data[bucket] & mask;
            if (bucketData != 0) {
                uint256 msb = _highestBitSet(bucketData);
                return _owners[(bucket << 8) | msb];
            }
        }

        // Scan previous buckets until we find a set bit
        while (bucket > 0) {
            unchecked { bucket--; }
            uint256 bucketData = _batchHead._data[bucket];
            if (bucketData != 0) {
                uint256 msb = _highestBitSet(bucketData);
                return _owners[(bucket << 8) | msb];
            }
        }

        revert OwnerQueryForNonexistentToken();
    }

    /// @notice Returns the approved address for `tokenId`, or the zero address if none.
    function getApproved(uint256 tokenId) public view returns (address) {
        if (tokenId >= totalSupply) revert OwnerQueryForNonexistentToken();
        return _tokenApprovals[tokenId];
    }

    /// @notice Returns true if `operator` is approved to manage all tokens of `owner`.
    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    // =========================================================================
    // ERC721 Approval Functions
    // =========================================================================

    /// @notice Approve `to` to transfer token `tokenId`.
    function approve(address to, uint256 tokenId) public virtual {
        address owner = ownerOf(tokenId);
        if (to == owner) revert ApprovalToCurrentOwner();
        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender)) {
            revert NotOwnerOrApproved();
        }
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    /// @notice Approve or revoke `operator` to manage all of the caller's tokens.
    function setApprovalForAll(address operator, bool approved) public virtual {
        if (operator == msg.sender) revert ApproveToCaller();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    // =========================================================================
    // ERC721 Transfer Functions
    // =========================================================================

    /// @notice Transfer token `tokenId` from `from` to `to`.
    function transferFrom(address from, address to, uint256 tokenId) public virtual {
        address owner = ownerOf(tokenId);
        if (owner != from) revert TransferFromIncorrectOwner();
        if (to == address(0)) revert TransferToZeroAddress();
        if (!_isApprovedOrOwner(msg.sender, tokenId, owner)) revert NotOwnerOrApproved();

        _transfer(from, to, tokenId, owner);
    }

    /// @notice Safe transfer — reverts if `to` is a contract that doesn't implement
    ///         ERC721Receiver.
    function safeTransferFrom(address from, address to, uint256 tokenId) public virtual {
        safeTransferFrom(from, to, tokenId, "");
    }

    /// @notice Safe transfer with additional `data` passed to the receiver.
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public virtual {
        transferFrom(from, to, tokenId);
        if (!_checkOnERC721Received(from, to, tokenId, data)) {
            revert TransferToNonERC721ReceiverImplementer();
        }
    }

    // =========================================================================
    // Metadata (override in your collection contract)
    // =========================================================================

    /// @notice Returns the metadata URI for `tokenId`.
    function tokenURI(uint256 tokenId) public view virtual returns (string memory);

    // =========================================================================
    // Internal Mint
    // =========================================================================

    /// @notice Batch-mints `quantity` tokens to `to`.
    /// @dev Only one storage write per batch regardless of quantity.
    function _mint(address to, uint256 quantity) internal virtual {
        if (to == address(0)) revert MintToZeroAddress();
        if (quantity == 0) revert MintZeroQuantity();

        uint256 startTokenId = totalSupply;

        unchecked {
            _balances[to] += quantity;
            totalSupply += quantity;
        }

        // Lazy init: only the first token of the batch stores an owner
        _owners[startTokenId] = to;
        _batchHead.set(startTokenId);

        // Emit Transfer events (required by ERC721 standard)
        for (uint256 i = 0; i < quantity; ) {
            emit Transfer(address(0), to, startTokenId + i);
            unchecked { ++i; }
        }
    }

    /// @notice Safe batch-mint — checks ERC721Receiver on contracts.
    function _safeMint(address to, uint256 quantity) internal virtual {
        _safeMint(to, quantity, "");
    }

    function _safeMint(address to, uint256 quantity, bytes memory data) internal virtual {
        _mint(to, quantity);
        // Only check the last token; if receiver handles one it handles all
        if (!_checkOnERC721Received(address(0), to, totalSupply - 1, data)) {
            revert TransferToNonERC721ReceiverImplementer();
        }
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Core transfer logic, shared by transferFrom and safeTransferFrom.
    function _transfer(address from, address to, uint256 tokenId, address owner) private {
        // Clear single-token approval
        delete _tokenApprovals[tokenId];

        unchecked {
            _balances[from] -= 1;
            _balances[to] += 1;
        }

        // Explicitly assign the new owner and mark this token as a batch head
        _owners[tokenId] = to;
        _batchHead.set(tokenId);

        // If the next token was implicitly owned by `from` (i.e., no explicit owner set),
        // initialize it now so it doesn't appear to belong to `to`.
        uint256 nextTokenId = tokenId + 1;
        if (nextTokenId < totalSupply && _owners[nextTokenId] == address(0)) {
            _owners[nextTokenId] = from;
            _batchHead.set(nextTokenId);
        }

        emit Transfer(from, to, tokenId);
    }

    /// @dev Returns true if `spender` is allowed to manage `tokenId`.
    function _isApprovedOrOwner(
        address spender,
        uint256 tokenId,
        address owner
    ) internal view returns (bool) {
        return (
            spender == owner ||
            isApprovedForAll(owner, spender) ||
            getApproved(tokenId) == spender
        );
    }

    /// @dev Calls `onERC721Received` on `to` if it is a contract.
    ///      Returns true if `to` is an EOA or returns the correct selector.
    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) private returns (bool) {
        if (to.code.length == 0) return true; // EOA — always safe

        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (
            bytes4 retval
        ) {
            return retval == IERC721Receiver.onERC721Received.selector;
        } catch {
            return false;
        }
    }

    // =========================================================================
    // Yul — O(1) Most Significant Bit
    // =========================================================================

    /// @dev Returns the position (0-indexed) of the highest set bit in `x`.
    ///      Uses a branch-free binary search in assembly — 8 ops, no loop.
    function _highestBitSet(uint256 x) internal pure returns (uint256 r) {
        require(x > 0);
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
    }
}

// =========================================================================
// Minimal ERC721Receiver interface (avoids an extra import)
// =========================================================================

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}
