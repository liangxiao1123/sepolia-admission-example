// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title AlayaOracleTypes — shared type library for the pure-EVM AlayaOracle.
///
/// Wire-compatible with the Substrate pallet-core semantics where applicable
/// (Outcome encoding locked: NO=0, YES=1, INCONCLUSIVE=2), but all crosschain
/// (ISMP) types are dropped — this version is single-chain autonomous.
library AlayaOracleTypes {
    // ------------------------------------------------------------------
    // Enums
    // ------------------------------------------------------------------

    /// Proposition lifecycle states (mirrors pallet-core PropositionStatus).
    enum Status {
        Initiated,      // created, bill unpaid (EVM: deposit escrowed at creation)
        Active,         // bill paid → awaiting provider answer
        Preliminary,    // answer submitted, challenge window open
        UnderChallenge, // doubt raised, voting
        Finalized,      // terminal, answer authoritative
        Unanswered,     // deadline passed without answer (offence recorded)
        Expired         // reservation swept, deposit refunded
    }

    /// Tri-state oracle outcome. Encoding LOCKED (substrate parity).
    enum Outcome {
        NO,           // 0
        YES,          // 1
        INCONCLUSIVE  // 2
    }

    /// Answer schema — Phase 1 supports Boolean only (substrate AnswerValue).
    enum AnswerSchema {
        Boolean
    }

    // ------------------------------------------------------------------
    // Structs
    // ------------------------------------------------------------------

    /// Dual-hash content integrity (cid addressing + content tamper-proof).
    struct ContentHashPair {
        bytes32 cidHash;
        bytes32 contentHash;
    }

    struct TimeWindow {
        uint64 decidableAfter; // earliest answer time
        uint64 deadline;       // latest answer time
    }

    struct Proposition {
        uint64 id;
        address provider;      // assigned provider (initiator)
        address submitter;     // proposition author (deposit payer)
        bytes32 cidHash;
        bytes32 contentHash;
        AnswerSchema schema;
        uint64 decidableAfter;
        uint64 deadline;
        Status status;
        uint256 creationDeposit; // escrowed USDC amount (6 decimals)
        uint64 createdAt;
    }

    struct Answer {
        Outcome value;
        bytes32 rationaleCidHash;
        bytes32 rationaleContentHash;
        uint64 submittedAt;
    }

    struct Challenge {
        address challenger;
        Outcome claimedValue;
        uint64 openedAt;
        uint256 votesFor;
        uint256 votesTotal;
        bool settled;
        // Snapshot at raise time: later admin parameter changes cannot
        // underflow the unlock or rewrite an open challenge's economics.
        uint256 lockedStake;
        uint256 reward;
        uint32 quorum;
        uint32 flipThresholdPercent;
        uint32 slashPercent;
    }

    struct ProviderInfo {
        uint64 maxConcurrent;
        uint64 currentActive;   // open propositions (created → finalized/unanswered/expired)
        uint32 offenceUnanswered;
        uint32 offenceFlipped;
        uint32 cleanFinals;
        bool registered;
    }

    struct UnstakeRequest {
        uint256 amount;
        uint64 requestTime;
        uint64 coolingEnds;
        bool pending;
    }

    // ------------------------------------------------------------------
    // Constants (mirroring pallet-core)
    // ------------------------------------------------------------------

    uint64 internal constant MIN_PROPOSITION_DURATION = 1 hours;
    uint64 internal constant MAX_PROPOSITION_DURATION = 30 days;
    uint64 internal constant DEFAULT_CHALLENGE_PERIOD = 1 days;
    uint64 internal constant MIN_DELEGATOR_INIT_INTERVAL = 60; // F-15 rate limit

    /// Validation helper: both hashes must be non-zero.
    function isValid(ContentHashPair memory p) internal pure returns (bool) {
        return p.cidHash != bytes32(0) && p.contentHash != bytes32(0);
    }
}
