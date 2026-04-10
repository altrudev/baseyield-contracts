// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BaseYieldManager} from "../src/BaseYieldManager.sol";

/// @notice Deploy BaseYieldManager to Base Mainnet
///
/// ⚠️  PRE-DEPLOYMENT CHECKLIST — DO NOT SKIP:
///   [ ] Professional audit completed and report published
///   [ ] All audit findings resolved
///   [ ] Testnet deployment tested thoroughly
///   [ ] Constructor addresses verified on basescan.org
///   [ ] Fee recipient address confirmed correct
///   [ ] Using hardware wallet (--ledger flag) for mainnet
///   [ ] Sufficient ETH in deployer for gas
///
/// @dev Run with:
///      forge script script/Deploy.s.sol \
///        --rpc-url base_mainnet \
///        --broadcast \
///        --verify \
///        --ledger \
///        -vvvv
contract Deploy is Script {

    // ── Base Mainnet contract addresses ───────────────────────────────────────
    // Verify each address at basescan.org before deploying.
    // Cross-reference with official documentation.

    /// @dev Aerodrome Slipstream NonfungiblePositionManager on Base Mainnet
    /// Source: aerodrome.finance/docs — verify against basescan.org
    address constant SLIPSTREAM_NPM_MAINNET = address(0); // SET BEFORE DEPLOYING

    /// @dev Gelato Automate on Base Mainnet
    /// Source: docs.gelato.network/developer-services/automate/contract-addresses
    address constant GELATO_AUTOMATE_MAINNET = address(0); // SET BEFORE DEPLOYING

    function run() external {
        // Load fee recipient from .env
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");

        // Hard stops — never deploy with zero addresses
        require(SLIPSTREAM_NPM_MAINNET  != address(0), "Set SLIPSTREAM_NPM_MAINNET");
        require(GELATO_AUTOMATE_MAINNET != address(0), "Set GELATO_AUTOMATE_MAINNET");
        require(feeRecipient            != address(0), "Set FEE_RECIPIENT_ADDRESS in .env");

        // Final confirmation prompt
        console.log("");
        console.log("======================================================");
        console.log("  BASE MAINNET DEPLOYMENT — POINT OF NO RETURN");
        console.log("======================================================");
        console.log("  Fee Recipient:   ", feeRecipient);
        console.log("  Slipstream NPM:  ", SLIPSTREAM_NPM_MAINNET);
        console.log("  Gelato Automate: ", GELATO_AUTOMATE_MAINNET);
        console.log("  Audit complete?   [ ] Confirm before proceeding");
        console.log("======================================================");
        console.log("");

        // For mainnet: use hardware wallet (--ledger flag)
        // vm.startBroadcast() with no key = uses msg.sender (ledger)
        vm.startBroadcast();

        BaseYieldManager manager = new BaseYieldManager(
            SLIPSTREAM_NPM_MAINNET,
            GELATO_AUTOMATE_MAINNET,
            feeRecipient
        );

        vm.stopBroadcast();

        console.log("BaseYieldManager deployed at:", address(manager));
        console.log("Verify: https://basescan.org/address/", address(manager));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Verify source code on BaseScan");
        console.log("2. Update README.md with deployed address");
        console.log("3. Update PWA frontend with contract address");
        console.log("4. Register Gelato tasks for beta users");
        console.log("5. Post deployment announcement");
    }
}
