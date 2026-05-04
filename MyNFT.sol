// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./UltraERC721.sol";

contract MyNFT is UltraERC721 {
    uint256 public constant MAX_SUPPLY = 10_000;
    string private _baseTokenURI;

    error MaxSupplyExceeded();

    constructor(string memory baseURI)
        UltraERC721("UltraNFT", "UNFT")
    {
        _baseTokenURI = baseURI;
    }

    function mint(uint256 quantity) external {
        if (totalSupply + quantity > MAX_SUPPLY) revert MaxSupplyExceeded();
        _safeMint(msg.sender, quantity);
    }

    /// @notice Returns the metadata URI for `tokenId`.
    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        if (tokenId >= totalSupply) revert OwnerQueryForNonexistentToken();
        return string(abi.encodePacked(_baseTokenURI, _toString(tokenId), ".json"));
    }

    /// @dev Efficient uint256 → string conversion without SafeMath
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
