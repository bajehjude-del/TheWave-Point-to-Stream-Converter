// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Merkle proof verifier (compatible with OpenZeppelin's tree format).
library MerkleProof {
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf)
        internal
        pure
        returns (bool)
    {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            // Sort pair so the tree is order-independent
            computed = computed <= proofElement
                ? keccak256(abi.encodePacked(computed, proofElement))
                : keccak256(abi.encodePacked(proofElement, computed));
        }
        return computed == root;
    }
}
