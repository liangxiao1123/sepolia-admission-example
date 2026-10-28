// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAlayaApp} from "./IAlayaApp.sol";
import {IOracleConsumer} from "../interfaces/IOracleConsumer.sol";
import {AlayaOracleTypes as T} from "../libraries/AlayaOracleTypes.sol";

/// Minimal stable subset of the diamond the SDK depends on. Apps must NOT
/// hardcode facet addresses or read protocol config from environment files.
interface IAlayaDiamondProtocol {
    function treasury() external view returns (address);
    function usdc() external view returns (address);
}

interface IAlayaOracleProtocol {
    function createProposition(
        address provider,
        bytes32 cidHash,
        bytes32 contentHash,
        T.AnswerSchema schema,
        uint64 decidableAfter,
        uint64 deadline,
        uint256 depositAmount
    ) external returns (uint64 propositionId);
    function registerConsumerContentHash(uint64 propositionId, bytes32 contentHash) external;
    function getProposition(uint64 propositionId) external view returns (T.Proposition memory);
    function getFinalAnswer(uint64 propositionId) external view returns (T.Answer memory);
}

interface IAlayaTreasuryClaims {
    function claim(bytes32 billId, uint64 propositionId) external;
}

/// The payment token the AuthorityTreasury escrows (USDCX on Sepolia).
/// Typed call instead of raw staticcall — no ABI drift, revert propagates.
interface IAuthorityTreasuryPaymentToken {
    function paymentToken() external view returns (address);
}

/**
 * @title AlayaPropositions — pure helpers for AlayaOracle apps.
 * @notice Free-standing wrappers so apps that cannot inherit `AlayaApp`
 *         (unusual layouts) still share ONE canonical appId derivation and
 *         call encoding. Admission checks recognize both usages.
 */
library AlayaPropositions {
    /// @notice Deterministic app identity: keccak256(abi.encode(chainId, appContract)).
    ///         The AppRegistry and every verifier derive the SAME id; user
    ///         input can never choose or squat an appId.
    function computeAppId(uint256 chainId, address appContract) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainId, appContract));
    }
}

/**
 * @title AlayaApp — official base contract for AlayaOracle apps.
 *
 * An app is a set of smart contracts. Inheriting this base implements the two
 * MANDATORY protocol integrations:
 *
 *   M1. x402 escrow/claim through AuthorityTreasury (canonical v2 exact +
 *       EIP-3009). The app contract IS the treasury `runner`; payouts land
 *       here after `claim` verifies the app's proposition on-chain.
 *   M2. Proposition creation in the AlayaOracle diamond: every `_alayaCreate`
 *       records the app contract as `submitter`, so lifecycle and progress
 *       are readable through platform channels forever.
 *
 * Design rules:
 *  - Immutable, non-upgradeable. `alayaDiamond` and `alayaAuthorityTreasury`
 *    are bound at construction and can never be redirected.
 *  - Two-step ownership (OZ Ownable2Step); registry submissions must come
 *    from `owner()`.
 *  - Deposit allowance is EXACT by construction (`authorizeDepositExact`) —
 *    never `type(uint256).max`, matching CHK-CHAIN-04.
 *  - The finality callback entrypoint is fixed; apps override the internal
 *    hook only, so signature/gas behavior cannot drift per app.
 */
abstract contract AlayaApp is IAlayaApp, IOracleConsumer, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// SDK major version. The registry keeps a supported-set; unsupported
    /// majors are rejected with CHAIN_SDK_UNSUPPORTED.
    uint32 public constant ALAYA_SDK_VERSION = 1;

    address public immutable alayaDiamond;
    address public immutable alayaAuthorityTreasury;

    event AlayaDepositAllowanceSet(address indexed spender, uint256 amount);
    event AlayaBillClaimed(bytes32 indexed billId, uint64 indexed propositionId, uint256 netAmount);
    event AlayaPropositionCreated(uint64 indexed propositionId, address indexed provider, uint256 deposit);
    event EtherReceived(uint256 amount);

    error BadProtocolAddress();
    error NotDiamond();
    error ZeroAmount();

    constructor(address alayaDiamond_, address authorityTreasury_, address initialOwner) Ownable(initialOwner) {
        if (alayaDiamond_ == address(0) || authorityTreasury_ == address(0)) revert BadProtocolAddress();
        // Both must already be deployed contracts — binding to an EOA would
        // let a "config" point at nothing and pass naive address checks.
        if (alayaDiamond_.code.length == 0 || authorityTreasury_.code.length == 0) revert BadProtocolAddress();
        alayaDiamond = alayaDiamond_;
        alayaAuthorityTreasury = authorityTreasury_;
    }

    // ── IAlayaApp ───────────────────────────────────────────────────────

    function alayaConfig() public view returns (AlayaProtocolConfig memory) {
        return AlayaProtocolConfig({
            diamond: alayaDiamond,
            authorityTreasury: alayaAuthorityTreasury,
            sdkVersion: ALAYA_SDK_VERSION
        });
    }

    function alayaAppOwner() external view returns (address) {
        return owner();
    }

    /// ERC-165: the app identity surface, the framed consumer callback, and
    /// ERC-165 itself. Apps extending this should override and OR their own
    /// interface ids rather than replacing the set.
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IAlayaApp).interfaceId
            || interfaceId == type(IOracleConsumer).interfaceId
            || interfaceId == 0x01ffc9a7; // ERC-165
    }

    // ── M2: proposition creation in the official diamond ────────────────

    /// @notice Create a proposition with the APP CONTRACT as submitter.
    ///         Requires an exact deposit allowance (see authorizeDepositExact)
    ///         and app-owned deposit tokens. The diamond pulls the deposit in
    ///         the same transaction — creation IS activation.
    function _alayaCreate(
        address provider,
        bytes32 cidHash,
        bytes32 contentHash,
        T.AnswerSchema schema,
        uint64 decidableAfter,
        uint64 deadline,
        uint256 depositAmount
    ) internal returns (uint64 propositionId) {
        propositionId = IAlayaOracleProtocol(alayaDiamond).createProposition(
            provider, cidHash, contentHash, schema, decidableAfter, deadline, depositAmount
        );
        emit AlayaPropositionCreated(propositionId, provider, depositAmount);
    }

    /// Register this contract as the framed push consumer for a proposition.
    function _alayaRegisterConsumer(uint64 propositionId, bytes32 contentHash) internal {
        IAlayaOracleProtocol(alayaDiamond).registerConsumerContentHash(propositionId, contentHash);
    }

    function _alayaProposition(uint64 propositionId) internal view returns (T.Proposition memory) {
        return IAlayaOracleProtocol(alayaDiamond).getProposition(propositionId);
    }

    function _alayaFinalAnswer(uint64 propositionId) internal view returns (T.Answer memory) {
        return IAlayaOracleProtocol(alayaDiamond).getFinalAnswer(propositionId);
    }

    // ── M1: x402 escrow claim through AuthorityTreasury ─────────────────

    /// @notice Claim a settled x402 bill for work this contract fulfilled.
    ///         The treasury verifies the proposition criteria itself (cidHash
    ///         binding, submitter == this runner, within deadline) before
    ///         paying — no trusted keeper signature involved.
    function _alayaClaim(bytes32 billId, uint64 propositionId) internal returns (uint256 netAmount) {
        uint256 before_ = IERC20(_alayaPaymentToken()).balanceOf(address(this));
        IAlayaTreasuryClaims(alayaAuthorityTreasury).claim(billId, propositionId);
        netAmount = IERC20(_alayaPaymentToken()).balanceOf(address(this)) - before_;
        emit AlayaBillClaimed(billId, propositionId, netAmount);
    }

    // ── funding ─────────────────────────────────────────────────────────

    /// The payment token the AuthorityTreasury escrows (USDCX on Sepolia).
    function _alayaPaymentToken() public view returns (address) {
        return IAuthorityTreasuryPaymentToken(alayaAuthorityTreasury).paymentToken();
    }

    /// @notice Set an EXACT deposit allowance for the diamond's vault.
    ///         Exact-by-name: apps must never grant unlimited approval.
    function authorizeDepositExact(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(IAlayaDiamondProtocol(alayaDiamond).usdc());
        address spender = IAlayaDiamondProtocol(alayaDiamond).treasury();
        token.forceApprove(spender, amount);
        emit AlayaDepositAllowanceSet(spender, amount);
    }

    // ── finality callback (framed) ──────────────────────────────────────

    /// Fixed entrypoint; only the official diamond may call. Override the
    /// `_onAlayaFinalized` hook instead of this function.
    function onPropositionFinalized(uint64 propositionId, uint8 outcome, bytes32 contentHash) external {
        if (msg.sender != alayaDiamond) revert NotDiamond();
        _onAlayaFinalized(propositionId, outcome, contentHash);
    }

    function _onAlayaFinalized(uint64 propositionId, uint8 outcome, bytes32 contentHash) internal virtual {}

    // ── housekeeping ────────────────────────────────────────────────────

    /// Owner sweep for tokens held by the app (earnings, mistaken transfers).
    /// Escrow itself always lives in the AuthorityTreasury, never here.
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
    }

    /// ETH can only arrive by selfdestruct/coinbase force; make it rescuable.
    function withdrawEther(address to, uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert BadProtocolAddress();
        (bool ok,) = to.call{value: amount}("");
        require(ok, "AlayaApp: eth transfer failed");
    }

    receive() external payable {
        emit EtherReceived(msg.value);
    }
}
