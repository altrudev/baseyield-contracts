// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BaseYieldManager} from "../src/BaseYieldManager.sol";

/// @notice Deploy BaseYieldManager to Base Sepolia testnet
/// @dev Run with:
///      forge script script/DeployTestnet.s.sol \
///        --rpc-url base_sepolia \
///        --broadcast \
///        --verify \
///        -vvvv
contract DeployTestnet is Script {

    // ── Base Sepolia contract addresses ───────────────────────────────────────
    // These must be verified before running this script.
    // Check: sepolia.basescan.org

    /// @dev Aerodrome Slipstream NonfungiblePositionManager on Base Sepolia
    /// TODO: Confirm this address at aerodrome.finance/docs or basescan sepolia
    address constant SLIPSTREAM_NPM_SEPOLIA = address(0); // SET BEFORE DEPLOYING

    /// @dev Gelato Automate on Base Sepolia
    /// Find at: docs.gelato.network/developer-services/automate/contract-addresses
    address constant GELATO_AUTOMATE_SEPOLIA = address(0); // SET BEFORE DEPLOYING

    function run() external {
        // Load deployer private key from .env
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // Load fee recipient from .env (your wallet)
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");

        // Validate addresses before spending gas
        require(SLIPSTREAM_NPM_SEPOLIA  != address(0), "Set SLIPSTREAM_NPM_SEPOLIA");
        require(GELATO_AUTOMATE_SEPOLIA != address(0), "Set GELATO_AUTOMATE_SEPOLIA");
        require(feeRecipient            != address(0), "Set FEE_RECIPIENT_ADDRESS in .env");

        console.log("=== BaseYield Testnet Deployment ===");
        console.log("Deployer:        ", deployer);
        console.log("Fee Recipient:   ", feeRecipient);
        console.log("Slipstream NPM:  ", SLIPSTREAM_NPM_SEPOLIA);
        console.log("Gelato Automate: ", GELATO_AUTOMATE_SEPOLIA);
        console.log("Network:          Base Sepolia");
        console.log("=====================================");

        vm.startBroadcast(deployerKey);

        BaseYieldManager manager = new BaseYieldManager(
            SLIPSTREAM_NPM_SEPOLIA,
            GELATO_AUTOMATE_SEPOLIA,
            feeRecipient
        );

        vm.stopBroadcast();

        console.log("BaseYieldManager deployed at:", address(manager));
        console.log("Verify: https://sepolia.basescan.org/address/", address(manager));
        console.log("");
        console.log("=== Verification command ===");
        console.log("forge verify-contract", address(manager));
        console.log("  src/BaseYieldManager.sol:BaseYieldManager");
        console.log("  --chain base-sepolia");
        console.log("  --constructor-args $(cast abi-encode");
        console.log("    'constructor(address,address,address)'");
        console.log("    ", SLIPSTREAM_NPM_SEPOLIA);
        console.log("    ", GELATO_AUTOMATE_SEPOLIA);
        console.log("    ", feeRecipient, ")");
    }
}
