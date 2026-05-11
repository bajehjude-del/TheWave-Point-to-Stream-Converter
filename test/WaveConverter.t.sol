// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WaveConverter, IDrips, StreamReceiver} from "../src/WaveConverter.sol";
import {MerkleProof} from "../src/lib/MerkleProof.sol";

// ─── Mock Drips ───────────────────────────────────────────────────────────────

contract MockDrips {
    uint32 public nextDriverId = 1;
    uint160 public constant AMT_PER_SEC_MULTIPLIER = 1_000_000_000;
    uint160 public constant minAmtPerSec = 1;

    mapping(uint32 => address) public drivers;

    // Tracks setStreams calls for assertions
    struct StreamsCall {
        uint256 accountId;
        address token;
        int128 balanceDelta;
        uint256 receiverAccountId;
    }

    StreamsCall[] internal _streamsCalls;

    function streamsCalls(uint256 i) external view returns (StreamsCall memory) {
        return _streamsCalls[i];
    }

    function registerDriver(address driverAddr) external returns (uint32 driverId) {
        driverId = nextDriverId++;
        drivers[driverId] = driverAddr;
    }

    function setStreams(
        uint256 accountId,
        IERC20 erc20,
        StreamReceiver[] calldata, /* currReceivers */
        int128 balanceDelta,
        StreamReceiver[] calldata newReceivers,
        uint32, /* maxEndHint1 */
        uint32 /* maxEndHint2 */
    ) external returns (int128) {
        // Pull tokens from the caller (WaveConverter)
        if (balanceDelta > 0) {
            erc20.transferFrom(msg.sender, address(this), uint128(balanceDelta));
        }
        _streamsCalls.push(
            StreamsCall({
                accountId: accountId,
                token: address(erc20),
                balanceDelta: balanceDelta,
                receiverAccountId: newReceivers.length > 0 ? newReceivers[0].accountId : 0
            })
        );
        return balanceDelta;
    }

    function streamsState(uint256, IERC20)
        external
        pure
        returns (bytes32, bytes32, uint32, uint128, uint32)
    {
        return (bytes32(0), bytes32(0), 0, 0, 0);
    }

    function lastCall() external view returns (StreamsCall memory) {
        return _streamsCalls[_streamsCalls.length - 1];
    }

    function callCount() external view returns (uint256) {
        return _streamsCalls.length;
    }
}

// ─── Mock ERC-20 ─────────────────────────────────────────────────────────────

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─── Merkle helpers ───────────────────────────────────────────────────────────

/// @dev Builds a 2-leaf Merkle tree and returns root + proofs.
///      Leaves: keccak256(abi.encodePacked(addr, points))
library MerkleHelper {
    function twoLeafTree(address a, uint32 pa, address b, uint32 pb)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        bytes32 leafA = keccak256(abi.encodePacked(a, pa));
        bytes32 leafB = keccak256(abi.encodePacked(b, pb));

        // Sort so the tree is deterministic
        bytes32 left = leafA <= leafB ? leafA : leafB;
        bytes32 right = leafA <= leafB ? leafB : leafA;
        root = keccak256(abi.encodePacked(left, right));

        proofA = new bytes32[](1);
        proofA[0] = leafB;

        proofB = new bytes32[](1);
        proofB[0] = leafA;
    }

    function singleLeafTree(address a, uint32 pa)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        root = keccak256(abi.encodePacked(a, pa));
        proof = new bytes32[](0);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

contract WaveConverterTest is Test {
    MockDrips drips;
    MockERC20 token;
    WaveConverter converter;

    address manager = address(0xA11CE);
    address alice = address(0xA1);
    address bob = address(0xB0B);

    uint128 constant CAPACITY = 1_000e18;
    uint32 constant DURATION = 30 days;
    uint32 constant TOTAL_POINTS = 100;

    function setUp() public {
        drips = new MockDrips();
        token = new MockERC20();
        converter = new WaveConverter(IDrips(address(drips)), manager);

        // Fund manager
        token.mint(manager, CAPACITY);
        vm.prank(manager);
        token.approve(address(converter), CAPACITY);
    }

    // ── Construction ──────────────────────────────────────────────────────

    function test_constructor_registersDriver() public view {
        // driverId should be 1 (first registered)
        assertEq(converter.driverId(), 1);
        assertEq(converter.manager(), manager);
    }

    function test_constructor_accountId() public view {
        uint256 expected = (uint256(1) << 224) | uint160(address(converter));
        assertEq(converter.accountId(), expected);
    }

    // ── newSprint ─────────────────────────────────────────────────────────

    function test_newSprint_basic() public {
        (bytes32 root,) = MerkleHelper.singleLeafTree(alice, 50);

        vm.prank(manager);
        uint256 sprintId = converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, TOTAL_POINTS);

        assertEq(sprintId, 0);
        assertEq(converter.sprintCount(), 1);
        assertEq(token.balanceOf(address(converter)), CAPACITY);
    }

    function test_newSprint_revertsIfNotManager() public {
        (bytes32 root,) = MerkleHelper.singleLeafTree(alice, 50);
        vm.expectRevert(WaveConverter.NotManager.selector);
        converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, TOTAL_POINTS);
    }

    function test_newSprint_incrementsSprintCount() public {
        (bytes32 root,) = MerkleHelper.singleLeafTree(alice, 50);

        token.mint(manager, CAPACITY * 2);
        vm.startPrank(manager);
        token.approve(address(converter), CAPACITY * 3);
        converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, TOTAL_POINTS);
        converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, TOTAL_POINTS);
        vm.stopPrank();

        assertEq(converter.sprintCount(), 2);
    }

    // ── claim ─────────────────────────────────────────────────────────────

    function test_claim_singleContributor() public {
        (bytes32 root, bytes32[] memory proof) = MerkleHelper.singleLeafTree(alice, 100);

        vm.prank(manager);
        uint256 sprintId = converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, 100);

        vm.prank(alice);
        converter.claim(sprintId, proof, 100);

        assertTrue(converter.claimed(sprintId, alice));
        assertEq(drips.callCount(), 1);

        MockDrips.StreamsCall memory call = drips.lastCall();
        assertEq(call.token, address(token));
        // Alice gets 100% of capacity
        assertEq(call.balanceDelta, int128(CAPACITY));
        // Receiver is alice's address-based account ID
        assertEq(call.receiverAccountId, uint256(uint160(alice)));
    }

    function test_claim_twoContributors_proportional() public {
        // Alice: 40 points, Bob: 60 points, total: 100
        (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB) =
            MerkleHelper.twoLeafTree(alice, 40, bob, 60);

        vm.prank(manager);
        uint256 sprintId = converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, 100);

        vm.prank(alice);
        converter.claim(sprintId, proofA, 40);

        vm.prank(bob);
        converter.claim(sprintId, proofB, 60);

        assertEq(drips.callCount(), 2);

        // Alice: 40% of 1000e18 = 400e18
        MockDrips.StreamsCall memory callA = drips.streamsCalls(0);
        assertEq(callA.balanceDelta, int128(uint128(400e18)));

        // Bob: 60% of 1000e18 = 600e18
        MockDrips.StreamsCall memory callB = drips.streamsCalls(1);
        assertEq(callB.balanceDelta, int128(uint128(600e18)));
    }

    function test_claim_revertsOnDoubleClaim() public {
        (bytes32 root, bytes32[] memory proof) = MerkleHelper.singleLeafTree(alice, 100);

        vm.prank(manager);
        uint256 sprintId = converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, 100);

        vm.startPrank(alice);
        converter.claim(sprintId, proof, 100);
        vm.expectRevert(WaveConverter.AlreadyClaimed.selector);
        converter.claim(sprintId, proof, 100);
        vm.stopPrank();
    }

    function test_claim_revertsOnInvalidProof() public {
        (bytes32 root,) = MerkleHelper.singleLeafTree(alice, 100);

        vm.prank(manager);
        uint256 sprintId = converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, 100);

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = bytes32(uint256(0xDEAD));

        vm.prank(alice);
        vm.expectRevert(WaveConverter.InvalidProof.selector);
        converter.claim(sprintId, badProof, 100);
    }

    function test_claim_revertsOnWrongPoints() public {
        (bytes32 root, bytes32[] memory proof) = MerkleHelper.singleLeafTree(alice, 100);

        vm.prank(manager);
        uint256 sprintId = converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, 100);

        // Correct proof but wrong points value → leaf mismatch
        vm.prank(alice);
        vm.expectRevert(WaveConverter.InvalidProof.selector);
        converter.claim(sprintId, proof, 50);
    }

    function test_claim_revertsOnZeroPoints() public {
        (bytes32 root, bytes32[] memory proof) = MerkleHelper.singleLeafTree(alice, 0);

        vm.prank(manager);
        uint256 sprintId = converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, 100);

        vm.prank(alice);
        vm.expectRevert(WaveConverter.ZeroPoints.selector);
        converter.claim(sprintId, proof, 0);
    }

    function test_claim_revertsOnClosedSprint() public {
        (bytes32 root, bytes32[] memory proof) = MerkleHelper.singleLeafTree(alice, 100);

        vm.prank(manager);
        uint256 sprintId = converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, 100);

        vm.prank(manager);
        converter.closeSprint(sprintId);

        vm.prank(alice);
        vm.expectRevert(WaveConverter.SprintNotActive.selector);
        converter.claim(sprintId, proof, 100);
    }

    // ── closeSprint ───────────────────────────────────────────────────────

    function test_closeSprint_revertsIfNotManager() public {
        (bytes32 root,) = MerkleHelper.singleLeafTree(alice, 100);
        vm.prank(manager);
        uint256 sprintId = converter.newSprint(root, IERC20(address(token)), CAPACITY, DURATION, 100);

        vm.expectRevert(WaveConverter.NotManager.selector);
        converter.closeSprint(sprintId);
    }

    // ── recoverTokens ─────────────────────────────────────────────────────

    function test_recoverTokens() public {
        token.mint(address(converter), 500e18);

        uint256 before = token.balanceOf(manager);
        vm.prank(manager);
        converter.recoverTokens(IERC20(address(token)), 500e18);

        assertEq(token.balanceOf(manager), before + 500e18);
    }

    function test_recoverTokens_revertsIfNotManager() public {
        vm.expectRevert(WaveConverter.NotManager.selector);
        converter.recoverTokens(IERC20(address(token)), 1);
    }

    // ── transferManager ───────────────────────────────────────────────────

    function test_transferManager() public {
        address newMgr = address(0xBEEF);
        vm.prank(manager);
        converter.transferManager(newMgr);
        assertEq(converter.manager(), newMgr);
    }

    function test_transferManager_revertsIfNotManager() public {
        vm.expectRevert(WaveConverter.NotManager.selector);
        converter.transferManager(address(0xBEEF));
    }

    // ── MerkleProof library ───────────────────────────────────────────────

    function test_merkleProof_singleLeaf() public pure {
        address a = address(0xA1);
        bytes32 leaf = keccak256(abi.encodePacked(a, uint32(100)));
        bytes32[] memory proof = new bytes32[](0);
        assertTrue(MerkleProof.verify(proof, leaf, leaf));
    }

    function test_merkleProof_twoLeaves() public pure {
        address a = address(0xA1);
        address b = address(0xB0B);
        bytes32 leafA = keccak256(abi.encodePacked(a, uint32(40)));
        bytes32 leafB = keccak256(abi.encodePacked(b, uint32(60)));

        bytes32 left = leafA <= leafB ? leafA : leafB;
        bytes32 right = leafA <= leafB ? leafB : leafA;
        bytes32 root = keccak256(abi.encodePacked(left, right));

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        assertTrue(MerkleProof.verify(proofA, root, leafA));

        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafA;
        assertTrue(MerkleProof.verify(proofB, root, leafB));
    }

    function test_merkleProof_invalidProof() public pure {
        bytes32 root = keccak256("root");
        bytes32 leaf = keccak256("leaf");
        bytes32[] memory proof = new bytes32[](0);
        assertFalse(MerkleProof.verify(proof, root, leaf));
    }
}
