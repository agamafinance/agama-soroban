// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AbfRegistry} from "../src/AbfRegistry.sol";
import {AbfKyc} from "../src/AbfKyc.sol";
import {AbfOracle} from "../src/AbfOracle.sol";
import {AbfMasterVault} from "../src/AbfMasterVault.sol";
import {AbfMatchingEngine} from "../src/AbfMatchingEngine.sol";
import {IAbfRegistry} from "../src/IAbfRegistry.sol";

/// @title Deploy the counterparty replica to an EVM testnet
/// @notice TESTNET ONLY, and one thing about it is unlike production in a way that matters: the deployer
///         takes the partner's operator and strategic roles as well as Agama's side of the trade. On testnet
///         there is nobody else to play the counterparty, so one key both posts the orders and settles them.
///         In production those are different parties and the settlement role is theirs alone, which is the
///         whole reason capital is in flight for a period rather than a block. Nothing here may be used to
///         install a role on a production deployment.
/// @dev The asset is Circle's real Sepolia USDC, not a mock. That is deliberate: it is what CCTP mints when
///      USDC arrives from Stellar, so the amount that lands is depositable as it arrives with nothing in
///      between that has to be priced. The partner's production vault takes Agora AUSD, and bridging into
///      that would add a swap, which is the one step in this whole route where a keeper would have to touch
///      a price. Choosing USDC here removes that step rather than simulating it.
contract DeployTestnet is Script {
    /// @dev Circle's real USDC, per chain, 6 decimals on both. Verified against `decimals()` and `symbol()`
    ///      on chain, and each is the token that chain's CCTP TokenMessengerV2 actually mints.
    ///
    ///      Base Sepolia rather than Ethereum Sepolia, and not by preference. Contract creation from the
    ///      deployer fails on Ethereum Sepolia and consumes the entire gas limit whatever that limit is:
    ///      measured with a five byte initcode (`0x60016000f3`, a contract whose runtime is one STOP) at
    ///      limits of 100k, 120k and 3M, each burned in full with status 0, across three endpoints that
    ///      accepted the send. The identical five bytes deploy on Base Sepolia for 53,279 gas with status 1.
    ///      So the fault is that chain and not this code, and Base Sepolia is equivalent for every purpose
    ///      here: CCTP has it as domain 6, the Stellar minter has domain 6 registered as a remote with the
    ///      same TokenMessengerV2 address it has for domain 0, and the inbound leg has already been run
    ///      live on it twice. If Ethereum Sepolia starts accepting creations, nothing below changes except
    ///      which branch of `_usdc` is taken.
    address internal constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant USDC_ETHEREUM_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    /// @dev 300 seconds, the same period the partner runs on their own staging deployment, rather than the
    ///      week production uses. A week-long period cannot be exercised end to end on a testnet; 300s makes
    ///      the staleness cliff and the one-update-per-period rule reachable in a single session, and both
    ///      are counted in periods, so the behaviour is identical and only the clock differs.
    uint256 internal constant PERIOD = 300;

    uint256 internal constant CAP = 1_000_000e6;
    uint256 internal constant RATIO = 9_000;
    uint256 internal constant STATIC_FEE = 10;
    uint256 internal constant SPREAD_FEE = 1_000;
    uint256 internal constant KYC_TOKEN_ID = 1;

    function _usdc() internal view returns (address) {
        if (block.chainid == 84532) return USDC_BASE_SEPOLIA;
        if (block.chainid == 11155111) return USDC_ETHEREUM_SEPOLIA;
        revert("no USDC address recorded for this chain");
    }

    function run() external {
        address deployer = msg.sender;
        address usdc = _usdc();
        vm.startBroadcast();

        AbfRegistry registry = new AbfRegistry(deployer);
        AbfKyc kyc = new AbfKyc(deployer);
        AbfOracle oracle = new AbfOracle(deployer, address(registry), PERIOD, block.timestamp);
        AbfMasterVault vault =
            new AbfMasterVault(deployer, address(registry), usdc, "ABF USD Testnet", "abfUSD-T", CAP, RATIO);
        AbfMatchingEngine engine = new AbfMatchingEngine(deployer, address(registry), STATIC_FEE, SPREAD_FEE);

        registry.setContractAddress(uint8(IAbfRegistry.ContractType.KYC), address(kyc));
        registry.setContractAddress(uint8(IAbfRegistry.ContractType.ORACLE), address(oracle));
        registry.setContractAddress(uint8(IAbfRegistry.ContractType.MATCHING_ENGINE), address(engine));
        registry.setContractAddress(uint8(IAbfRegistry.ContractType.TREASURY), deployer);
        registry.setContractAddress(uint8(IAbfRegistry.ContractType.VAULT_FUND_RECEIVERS), deployer);
        registry.setVaultType(address(vault), IAbfRegistry.VaultType.MASTER_VAULT);

        // See the contract note: one key on both sides of the trade, testnet only.
        kyc.setOperator(deployer, kyc.OPERATOR_ROLE(), true);
        oracle.setOperator(deployer, oracle.OPERATOR_ROLE(), true);
        engine.setOperator(deployer, engine.OPERATOR_ROLE(), true);
        engine.setOperator(deployer, engine.STRATEGIC_ROLE(), true);
        vault.setOperator(deployer, vault.OPERATOR_ROLE(), true);
        vault.setOperator(deployer, vault.STRATEGIC_ROLE(), true);
        registry.setOperator(deployer, registry.STRATEGIC_ROLE(), true);

        engine.setPaymentToken(usdc, true);
        // The credential goes to the address that will hold the shares, which on this testnet is the same
        // key. In production it is Agama's Safe, and the depositor on Stellar never appears on this chain.
        kyc.mint(deployer, KYC_TOKEN_ID);

        vm.stopBroadcast();

        console2.log("registry      ", address(registry));
        console2.log("kyc           ", address(kyc));
        console2.log("oracle        ", address(oracle));
        console2.log("masterVault   ", address(vault));
        console2.log("matchingEngine", address(engine));
        console2.log("usdc          ", usdc);
        console2.log("chainId       ", block.chainid);
        console2.log("operator      ", deployer);
    }
}
