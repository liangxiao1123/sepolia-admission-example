// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IAlayaApp — the on-chain contract surface every AlayaOracle app exposes.
 * @notice Admission (AppHub listing) requires the primary app contract to
 *         implement this interface AND pass deterministic behavioral
 *         conformance checks. The interface alone is a claim, not proof.
 */
interface IAlayaApp {
    /// Canonical protocol binding an app declares at deployment.
    /// `diamond` and `authorityTreasury` must equal the registry's official
    /// addresses; `sdkVersion` must be a supported release of this SDK.
    struct AlayaProtocolConfig {
        address diamond;
        address authorityTreasury;
        uint32 sdkVersion;
    }

    /// @notice The official AlayaOracle diamond + AuthorityTreasury this app
    ///         is bound to, and the SDK major version it was built with.
    function alayaConfig() external view returns (AlayaProtocolConfig memory);

    /// @notice Current owner (two-step transfer on the base implementation).
    ///         The AppRegistry requires candidate submitters to be this owner.
    function alayaAppOwner() external view returns (address);
}
