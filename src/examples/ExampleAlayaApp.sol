// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AlayaApp} from "../sdk/AlayaApp.sol";
import {AlayaOracleTypes as T} from "../libraries/AlayaOracleTypes.sol";

/**
 * @title ExampleAlayaApp — the reference app built on the official SDK.
 *
 * Demonstrates BOTH mandatory integrations end to end:
 *   1. `createTrackedProposition` — the app contract creates a real
 *      proposition in the diamond (submitter == this contract) and registers
 *      itself as the framed finality consumer.
 *   2. `claimEscrow` — after a payer's exact x402 payment settles into the
 *      AuthorityTreasury against this app's appId, the app claims its escrow.
 *
 * Intentionally boring: no proxy, no upgrade path, no hidden admin powers
 * beyond two-step ownership. Treat it as the template admission checks run
 * against; copy it, replace the business logic, keep the protocol shape.
 */
contract ExampleAlayaApp is AlayaApp {
    /// Last proposition this app created (indexed events hold full history).
    uint64 public lastCreatedProposition;
    /// Evidence the framed finality callback actually fired.
    uint64 public lastFinalizedProposition;
    uint8 public lastFinalOutcome;
    bytes32 public lastFinalContentHash;

    event TrackedPropositionCreated(uint64 indexed propositionId, address indexed provider, uint256 deposit);
    event EscrowClaimed(bytes32 indexed billId, uint64 indexed propositionId, uint256 netAmount);
    event FinalityObserved(uint64 indexed propositionId, uint8 outcome, bytes32 contentHash);

    constructor(
        address alayaDiamond_,
        address authorityTreasury_,
        address initialOwner_
    ) AlayaApp(alayaDiamond_, authorityTreasury_, initialOwner_) {}

    /// Create a proposition bound to this app contract and subscribe to its
    /// finality callback. Deposit tokens + exact allowance must already be
    /// arranged (see `authorizeDepositExact`).
    function createTrackedProposition(
        address provider,
        bytes32 cidHash,
        bytes32 contentHash,
        uint64 decidableAfter,
        uint64 deadline,
        uint256 depositAmount
    ) external onlyOwner nonReentrant returns (uint64 propositionId) {
        propositionId = _alayaCreate(
            provider, cidHash, contentHash, T.AnswerSchema.Boolean, decidableAfter, deadline, depositAmount
        );
        lastCreatedProposition = propositionId;
        _alayaRegisterConsumer(propositionId, contentHash);
        emit TrackedPropositionCreated(propositionId, provider, depositAmount);
    }

    /// Claim a settled x402 bill whose fulfillment is this app's proposition.
    /// Permissionless relay: anyone may crank it (like treasury.claim) —
    /// earnings still land on THIS contract and the event is auditable here.
    function claimEscrow(bytes32 billId, uint64 propositionId) external nonReentrant returns (uint256 net) {
        net = _alayaClaim(billId, propositionId);
        emit EscrowClaimed(billId, propositionId, net);
    }

    /// Public lifecycle reads (platform channels also expose these over HTTP).
    function propositionOf(uint64 propositionId) external view returns (T.Proposition memory) {
        return _alayaProposition(propositionId);
    }

    function finalAnswerOf(uint64 propositionId) external view returns (T.Answer memory) {
        return _alayaFinalAnswer(propositionId);
    }

    /// Finality hook: the diamond pushes here with a 50k gas budget, failure
    /// never blocks finalization. Record proof and move on.
    function _onAlayaFinalized(uint64 propositionId, uint8 outcome, bytes32 contentHash) internal override {
        lastFinalizedProposition = propositionId;
        lastFinalOutcome = outcome;
        lastFinalContentHash = contentHash;
        emit FinalityObserved(propositionId, outcome, contentHash);
    }
}
