// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MerkleProof} from "./lib/MerkleProof.sol";

// ─── Drips protocol interfaces ────────────────────────────────────────────────

/// @dev Packed stream config: streamId(32)|amtPerSec(160)|start(32)|duration(32)
type StreamConfig is uint256;

struct StreamReceiver {
    uint256 accountId;
    StreamConfig config;
}

interface IDrips {
    function registerDriver(address driverAddr) external returns (uint32 driverId);
    function AMT_PER_SEC_MULTIPLIER() external view returns (uint160);
    function minAmtPerSec() external view returns (uint160);

    function setStreams(
        uint256 accountId,
        IERC20 erc20,
        StreamReceiver[] calldata currReceivers,
        int128 balanceDelta,
        StreamReceiver[] calldata newReceivers,
        uint32 maxEndHint1,
        uint32 maxEndHint2
    ) external returns (int128 realBalanceDelta);

    function streamsState(uint256 accountId, IERC20 erc20)
        external
        view
        returns (
            bytes32 streamsHash,
            bytes32 streamsHistoryHash,
            uint32 updateTime,
            uint128 balance,
            uint32 maxEnd
        );
}

// ─── Minimal SafeERC20 ────────────────────────────────────────────────────────

library SafeTransfer {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TransferFrom failed");
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.approve, (spender, amount)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Approve failed");
    }
}

// ─── WaveConverter ────────────────────────────────────────────────────────────

/**
 * @title  WaveConverter
 * @notice Converts Wave contributor points into proportional Drips streams.
 *
 * Flow:
 *  1. Manager calls `newSprint` with a Merkle root of (address → points),
 *     the total points, the ERC-20 token, total capacity, and stream duration.
 *  2. Each contributor calls `claim` with their Merkle proof.
 *     The contract sets a Drips stream from its own account to the contributor's
 *     address-based account ID at a rate proportional to their share of points.
 *
 * Stream rate formula:
 *   amtPerSec (scaled) = (userPoints × totalCapacity × AMT_PER_SEC_MULTIPLIER)
 *                        / (totalPoints × streamDuration)
 */
contract WaveConverter {
    using SafeTransfer for IERC20;

    // ── State ──────────────────────────────────────────────────────────────

    IDrips public immutable drips;
    uint32 public immutable driverId;
    /// @dev Drips account ID for this contract: driverId(32)|zeros(64)|address(160)
    uint256 public immutable accountId;

    address public manager;

    struct Sprint {
        bytes32 merkleRoot;
        IERC20 token;
        uint128 totalCapacity; // total tokens to stream across all contributors
        uint32 streamDuration; // seconds each stream lasts
        uint32 totalPoints;
        bool active;
    }

    uint256 public sprintCount;
    mapping(uint256 sprintId => Sprint) public sprints;
    /// @dev sprintId → contributor → claimed
    mapping(uint256 sprintId => mapping(address contributor => bool)) public claimed;

    // ── Events ─────────────────────────────────────────────────────────────

    event SprintCreated(uint256 indexed sprintId, bytes32 merkleRoot, IERC20 token, uint128 totalCapacity);
    event Claimed(uint256 indexed sprintId, address indexed contributor, uint32 points, uint160 amtPerSec);
    event ManagerTransferred(address indexed oldManager, address indexed newManager);

    // ── Errors ─────────────────────────────────────────────────────────────

    error NotManager();
    error SprintNotActive();
    error AlreadyClaimed();
    error InvalidProof();
    error ZeroPoints();
    error StreamRateTooLow();
    error CapacityOverflow();

    // ── Constructor ────────────────────────────────────────────────────────

    /**
     * @param drips_   The Drips protocol contract.
     * @param manager_ The initial Wave manager address.
     */
    constructor(IDrips drips_, address manager_) {
        drips = drips_;
        manager = manager_;

        // Register this contract as a Drips driver; receive a unique driverId.
        driverId = drips_.registerDriver(address(this));

        // Our Drips account ID: driverId(32 bits) | zeros(64 bits) | address(160 bits)
        accountId = (uint256(driverId) << 224) | uint160(address(this));
    }

    // ── Manager actions ────────────────────────────────────────────────────

    /**
     * @notice Create a new sprint and deposit the stream capacity.
     * @param merkleRoot_     Root of the Merkle tree: leaves are keccak256(abi.encodePacked(addr, points)).
     * @param token_          ERC-20 token to stream.
     * @param totalCapacity_  Total tokens to distribute across all contributors.
     * @param streamDuration_ How long (seconds) each contributor's stream runs.
     * @param totalPoints_    Sum of all contributor points (used for rate calculation).
     */
    function newSprint(
        bytes32 merkleRoot_,
        IERC20 token_,
        uint128 totalCapacity_,
        uint32 streamDuration_,
        uint32 totalPoints_
    ) external returns (uint256 sprintId) {
        if (msg.sender != manager) revert NotManager();

        sprintId = sprintCount++;
        sprints[sprintId] = Sprint({
            merkleRoot: merkleRoot_,
            token: token_,
            totalCapacity: totalCapacity_,
            streamDuration: streamDuration_,
            totalPoints: totalPoints_,
            active: true
        });

        // Pull the capacity tokens from the manager into this contract,
        // then approve Drips to pull them when setStreams is called.
        token_.safeTransferFrom(msg.sender, address(this), totalCapacity_);
        token_.safeApprove(address(drips), totalCapacity_);

        emit SprintCreated(sprintId, merkleRoot_, token_, totalCapacity_);
    }

    /**
     * @notice Close a sprint (prevents further claims). Unclaimed tokens remain
     *         in the contract and can be recovered via `recoverTokens`.
     */
    function closeSprint(uint256 sprintId) external {
        if (msg.sender != manager) revert NotManager();
        sprints[sprintId].active = false;
    }

    /**
     * @notice Recover tokens not consumed by streams (e.g. after sprint closes).
     */
    function recoverTokens(IERC20 token, uint256 amount) external {
        if (msg.sender != manager) revert NotManager();
        token.safeTransfer(manager, amount);
    }

    function transferManager(address newManager) external {
        if (msg.sender != manager) revert NotManager();
        emit ManagerTransferred(manager, newManager);
        manager = newManager;
    }

    // ── Contributor claim ──────────────────────────────────────────────────

    /**
     * @notice Claim a Drips stream proportional to your points.
     * @param sprintId  The sprint to claim from.
     * @param proof     Merkle proof for (msg.sender, points).
     * @param points    The contributor's point allocation.
     */
    function claim(uint256 sprintId, bytes32[] calldata proof, uint32 points) external {
        Sprint storage sprint = sprints[sprintId];
        if (!sprint.active) revert SprintNotActive();
        if (claimed[sprintId][msg.sender]) revert AlreadyClaimed();
        if (points == 0) revert ZeroPoints();

        // Verify Merkle proof: leaf = keccak256(abi.encodePacked(contributor, points))
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, points));
        if (!MerkleProof.verify(proof, sprint.merkleRoot, leaf)) revert InvalidProof();

        claimed[sprintId][msg.sender] = true;

        // ── Compute stream rate ──────────────────────────────────────────
        // amtPerSec (scaled) = (points × totalCapacity × AMT_PER_SEC_MULTIPLIER)
        //                      / (totalPoints × streamDuration)
        uint160 multiplier = drips.AMT_PER_SEC_MULTIPLIER();
        uint160 amtPerSec = uint160(
            (uint256(points) * uint256(sprint.totalCapacity) * uint256(multiplier))
                / (uint256(sprint.totalPoints) * uint256(sprint.streamDuration))
        );

        if (amtPerSec < drips.minAmtPerSec()) revert StreamRateTooLow();

        // ── Contributor's Drips account ID ───────────────────────────────
        // Uses the same layout as AddressDriver: driverId(32)|zeros(64)|addr(160).
        // driverId=0 is a placeholder; in production supply the real AddressDriver driverId.
        uint256 receiverAccountId = _addressAccountId(msg.sender);

        // ── Build the new single-receiver list ──────────────────────────
        StreamConfig config = _makeConfig(0, amtPerSec, 0, sprint.streamDuration);
        StreamReceiver[] memory newReceivers = new StreamReceiver[](1);
        newReceivers[0] = StreamReceiver({accountId: receiverAccountId, config: config});

        // ── Deposit this contributor's share and start the stream ────────
        uint256 rawCapacity = (uint256(points) * uint256(sprint.totalCapacity)) / uint256(sprint.totalPoints);
        if (rawCapacity > uint256(uint128(type(int128).max))) revert CapacityOverflow();
        // casting is safe: rawCapacity <= type(int128).max is guaranteed above
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 contributorCapacity = int128(uint128(rawCapacity));

        drips.setStreams(
            accountId,
            sprint.token,
            new StreamReceiver[](0), // no prior streams for this sub-account
            contributorCapacity,
            newReceivers,
            0,
            0
        );

        emit Claimed(sprintId, msg.sender, points, amtPerSec);
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    /// @dev Compute an address-based Drips account ID (driverId=0 placeholder).
    function _addressAccountId(address addr) internal pure returns (uint256) {
        return uint256(uint160(addr));
    }

    /// @dev Pack a StreamConfig value.
    function _makeConfig(uint32 streamId_, uint160 amtPerSec_, uint32 start_, uint32 duration_)
        internal
        pure
        returns (StreamConfig)
    {
        uint256 config = streamId_;
        config = (config << 160) | amtPerSec_;
        config = (config << 32) | start_;
        config = (config << 32) | duration_;
        return StreamConfig.wrap(config);
    }
}
