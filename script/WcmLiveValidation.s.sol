// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "../lib/forge-std/src/Script.sol";

import {Bundler3, Call} from "../src/Bundler3.sol";
import {CoreAdapter} from "../src/adapters/CoreAdapter.sol";
import {GeneralAdapter1} from "../src/adapters/GeneralAdapter1.sol";
import {WcmAdapter} from "../src/adapters/WcmAdapter.sol";
import {IWcmAdapter} from "../src/interfaces/IWcmAdapter.sol";

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Id, Position} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

interface IWcmQuoteRouter {
    function priceByAmountIn(uint256 orderParams) external returns (uint256);
    function priceByAmountOut(uint256 orderParams) external returns (uint256);
}

abstract contract WcmLiveBase is Script {
    using MarketParamsLib for MarketParams;

    address internal constant BUNDLER3 = 0xf53D4c8f0f83F697CD6bB303567400cCf411aA63;
    address internal constant GENERAL_ADAPTER1 = 0x74d3cbc721613C8461df92658d0a20dF275Ca31b;
    address internal constant MORPHO = 0x18120312A7cf44DcfEc6dCe5632a431579ED9100;
    address internal constant WORLD_SWAP_ROUTER = 0x94b6706FA26a4F3DCF501Ff25E1e4628B75AdC69;
    address internal constant USDM = 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7;
    address internal constant WITRY = 0x15B271D9012b5820FC42b1c495B4C1e206547De5;
    address internal constant ORACLE = 0xEebB019a6C66826f8BA8A583177E0dd5feEd0F22;
    address internal constant IRM = 0x56875764185548B0ca72A1877b3aE15E44e8A323;
    bytes32 internal constant WORLD_SWAP_ROUTER_CODE_HASH =
        0x4fd3bfa5a8737b3e7411a83d8968153870956c17e0caac728dbfdc3399ba8a66;
    bytes32 internal constant WCM_ADAPTER_CODE_HASH =
        0x420c6d7f76359c0c7d0bdfa8261abf00d2e986db45d76881b170d0a5a3e46c9c;

    address internal constant BORROWER = 0x40E4471293383e6e38Cb5Ce1E2C2Cd996742Cc0B;
    address internal constant LENDER = 0xa12dC13D9F3bE78E786E8cAd76F6289358448745;
    address internal constant LIQUIDATION = 0xe6F2c3e1d0378F714272131a5e8250bDa1342987;
    address internal constant EXECUTOR = 0xA0e8B3794C85DEFdA1f6567Ed3999D00c9da08b0;

    uint256 internal constant LLTV = 770000000000000000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDM_WORLD_TICK = 1e14;
    uint256 internal constant USDM_POSITION_SCALE = 1e14;
    uint256 internal constant WITRY_POSITION_SCALE = 1e15;
    uint256 internal constant BPS = 10_000;
    uint32 internal constant WITRY_TOKEN_ID = 9;
    uint256 internal constant MEGAETH_CHAIN_ID = 4326;
    uint256 internal constant DEFAULT_DEADLINE_TTL = 2 minutes;
    uint256 internal constant MAX_DEADLINE_TTL = 5 minutes;
    uint256 internal constant MAX_LIVE_SLIPPAGE_BPS = 500;

    function marketParams() internal pure returns (MarketParams memory) {
        return MarketParams({loanToken: USDM, collateralToken: WITRY, oracle: ORACLE, irm: IRM, lltv: LLTV});
    }

    function _borrowerPk() internal view returns (uint256 pk) {
        pk = vm.envUint("MEGAETH_TEST_BORROWER_PRIVATE_KEY");
        require(vm.addr(pk) == BORROWER, "wrong borrower private key");
    }

    function _wcmAdapter() internal view returns (address adapter) {
        _requireMegaEth();
        adapter = vm.envAddress("WCM_ADAPTER_ADDRESS");
        require(adapter != address(0), "missing WCM_ADAPTER_ADDRESS");
        _validateWcmAdapter(adapter, _wcmAdapterCodeHash());
    }

    function _slippageBps() internal view returns (uint256) {
        uint256 value = vm.envOr("WCM_SLIPPAGE_BPS", uint256(300));
        require(value <= MAX_LIVE_SLIPPAGE_BPS, "invalid slippage");
        return value;
    }

    function _deadline() internal view returns (uint256) {
        uint256 ttl = vm.envOr("WCM_DEADLINE_TTL", DEFAULT_DEADLINE_TTL);
        require(ttl != 0 && ttl <= MAX_DEADLINE_TTL, "invalid deadline ttl");
        return block.timestamp + ttl;
    }

    function _buyWitryAmountOut() internal view returns (uint256) {
        return vm.envOr("WCM_BUY_WITRY_OUT", uint256(600e18));
    }

    function _sellWitryAmountIn() internal view returns (uint256) {
        return vm.envOr("WCM_SELL_WITRY_IN", uint256(500e18));
    }

    function _openInitialCollateral() internal view returns (uint256) {
        return vm.envOr("WCM_OPEN_INITIAL_COLLATERAL", uint256(1000e18));
    }

    function _openBorrowAmount() internal view returns (uint256) {
        return vm.envOr("WCM_OPEN_BORROW_USDM", uint256(12e18));
    }

    function _marketId() internal pure returns (Id) {
        return marketParams().id();
    }

    function _quoteExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 slippageBps)
        internal
        returns (uint256 minAmountOut)
    {
        require(_isSupportedPair(tokenIn, tokenOut), "unsupported quote pair");

        bool isBuy = tokenIn == USDM && tokenOut == WITRY;
        uint256 inputScale = tokenIn == USDM ? USDM_POSITION_SCALE : WITRY_POSITION_SCALE;
        uint256 outputScale = tokenOut == USDM ? USDM_POSITION_SCALE : WITRY_POSITION_SCALE;
        uint64 amountInPosition = _toPositionAmount(amountIn, inputScale);
        uint256 quote = IWcmQuoteRouter(WORLD_SWAP_ROUTER)
            .priceByAmountIn(_packSwapInputAmountIn(amountInPosition, 0, type(uint64).max, WITRY_TOKEN_ID, isBuy));
        uint64 amountOutPosition = uint64(quote >> 64);
        require(amountOutPosition != 0, "zero exact-in quote");

        uint256 minOutPosition = uint256(amountOutPosition) * (BPS - slippageBps) / BPS;
        require(minOutPosition != 0, "zero min output");
        minAmountOut = minOutPosition * outputScale;
    }

    function _quoteExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 slippageBps)
        internal
        returns (uint256 maxAmountIn)
    {
        require(_isSupportedPair(tokenIn, tokenOut), "unsupported quote pair");

        bool isBuy = tokenIn == USDM && tokenOut == WITRY;
        uint256 inputScale = tokenIn == USDM ? USDM_POSITION_SCALE : WITRY_POSITION_SCALE;
        uint256 outputScale = tokenOut == USDM ? USDM_POSITION_SCALE : WITRY_POSITION_SCALE;
        uint64 amountOutPosition = _toPositionAmountUp(amountOut, outputScale);
        uint256 quote = IWcmQuoteRouter(WORLD_SWAP_ROUTER)
            .priceByAmountOut(
                _packSwapInputAmountOut(amountOutPosition, type(uint64).max, type(uint64).max, WITRY_TOKEN_ID, isBuy)
            );
        uint64 amountInPosition = uint64(quote >> 128);
        require(amountInPosition != 0, "zero exact-out quote");

        uint256 maxInPosition = _mulDivUp(uint256(amountInPosition), BPS + slippageBps, BPS);
        require(maxInPosition <= type(uint64).max, "max input overflow");
        maxAmountIn = maxInPosition * inputScale;
    }

    function _roundUpToUsdmWorldTick(uint256 amount) internal pure returns (uint256) {
        return _mulDivUp(amount, 1, USDM_WORLD_TICK) * USDM_WORLD_TICK;
    }

    function _toPositionAmount(uint256 rawAmount, uint256 scale) internal pure returns (uint64 positionAmount) {
        require(rawAmount % scale == 0, "amount not world aligned");
        uint256 value = rawAmount / scale;
        require(value != 0, "amount below world precision");
        require(value <= type(uint64).max, "position overflow");
        positionAmount = uint64(value);
    }

    function _toPositionAmountUp(uint256 rawAmount, uint256 scale) internal pure returns (uint64 positionAmount) {
        uint256 value = _mulDivUp(rawAmount, 1, scale);
        require(value != 0, "amount below world precision");
        require(value <= type(uint64).max, "position overflow");
        positionAmount = uint64(value);
    }

    function _requireMegaEth() internal view {
        require(block.chainid == MEGAETH_CHAIN_ID, "wrong chain");
        require(WORLD_SWAP_ROUTER.codehash == WORLD_SWAP_ROUTER_CODE_HASH, "wrong router codehash");
    }

    function _wcmAdapterCodeHash() internal pure returns (bytes32) {
        return WCM_ADAPTER_CODE_HASH;
    }

    function _validateWcmAdapter(address adapter, bytes32 expectedCodeHash) internal view {
        require(adapter.code.length != 0, "wcm adapter has no code");
        require(adapter.codehash == expectedCodeHash, "wrong adapter codehash");

        _validateWcmAdapterImmutables(adapter);
    }

    function _validateWcmAdapterImmutables(address adapter) internal view {
        WcmAdapter wcmAdapter = WcmAdapter(payable(adapter));
        require(wcmAdapter.BUNDLER3() == BUNDLER3, "wrong adapter bundler");
        require(address(wcmAdapter.MORPHO()) == MORPHO, "wrong adapter morpho");
        require(address(wcmAdapter.ROUTER()) == WORLD_SWAP_ROUTER, "wrong adapter router");
        require(wcmAdapter.CHAIN_ID() == MEGAETH_CHAIN_ID, "wrong adapter chainid");
        require(wcmAdapter.ROUTER_CODE_HASH() == WORLD_SWAP_ROUTER_CODE_HASH, "wrong adapter router codehash");
        require(wcmAdapter.USDM() == USDM, "wrong adapter usdm");
        require(wcmAdapter.WITRY() == WITRY, "wrong adapter witry");
        require(wcmAdapter.MARKET_ORACLE() == ORACLE, "wrong adapter oracle");
        require(wcmAdapter.MARKET_IRM() == IRM, "wrong adapter irm");
        require(wcmAdapter.MARKET_LLTV() == LLTV, "wrong adapter lltv");
    }

    function _useMaxApprovals() internal view returns (bool) {
        uint256 value = vm.envOr("WCM_ALLOW_MAX_APPROVALS", uint256(0));
        require(value <= 1, "invalid max approval flag");
        return value == 1;
    }

    function _approveIfNeeded(address token, uint256 amount, string memory label) internal {
        uint256 allowance = IERC20(token).allowance(BORROWER, GENERAL_ADAPTER1);
        if (allowance == amount) return;

        if (allowance != 0) require(IERC20(token).approve(GENERAL_ADAPTER1, 0), "zero approve failed");
        require(IERC20(token).approve(GENERAL_ADAPTER1, amount), label);
    }

    function _packSwapInputAmountIn(uint64 amountIn, uint64 amountOutMin, uint64 deadline, uint32 tokenId, bool isBuy)
        internal
        pure
        returns (uint256 packed)
    {
        packed = uint256(amountIn) | (uint256(amountOutMin) << 64) | (uint256(deadline) << 128)
            | (uint256(tokenId) << 192) | (uint256(isBuy ? 1 : 0) << 224);
    }

    function _packSwapInputAmountOut(uint64 amountOut, uint64 amountInMax, uint64 deadline, uint32 tokenId, bool isBuy)
        internal
        pure
        returns (uint256 packed)
    {
        packed = uint256(amountOut) | (uint256(amountInMax) << 64) | (uint256(deadline) << 128)
            | (uint256(tokenId) << 192) | (uint256(isBuy ? 1 : 0) << 224);
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        if (x == 0 || y == 0) return 0;
        return (x * y - 1) / d + 1;
    }

    function _isSupportedPair(address tokenIn, address tokenOut) internal pure returns (bool) {
        return (tokenIn == USDM && tokenOut == WITRY) || (tokenIn == WITRY && tokenOut == USDM);
    }

    function _call(address to, bytes memory data) internal pure returns (Call memory) {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }

    function _erc20Transfer(address adapter, address token, address receiver, uint256 amount)
        internal
        pure
        returns (Call memory)
    {
        return _call(adapter, abi.encodeCall(CoreAdapter.erc20Transfer, (token, receiver, amount)));
    }

    function _erc20TransferFrom(address token, address receiver, uint256 amount) internal pure returns (Call memory) {
        return _call(GENERAL_ADAPTER1, abi.encodeCall(GeneralAdapter1.erc20TransferFrom, (token, receiver, amount)));
    }

    function _morphoSupplyCollateral(uint256 assets, address onBehalf) internal pure returns (Call memory) {
        return _call(
            GENERAL_ADAPTER1,
            abi.encodeCall(GeneralAdapter1.morphoSupplyCollateral, (marketParams(), assets, onBehalf, hex""))
        );
    }

    function _morphoBorrow(uint256 assets, address receiver) internal pure returns (Call memory) {
        return
            _call(
                GENERAL_ADAPTER1, abi.encodeCall(GeneralAdapter1.morphoBorrow, (marketParams(), assets, 0, 0, receiver))
            );
    }

    function _morphoRepayAll(address onBehalf) internal pure returns (Call memory) {
        return _call(
            GENERAL_ADAPTER1,
            abi.encodeCall(
                GeneralAdapter1.morphoRepay, (marketParams(), 0, type(uint256).max, type(uint256).max, onBehalf, hex"")
            )
        );
    }

    function _morphoWithdrawAllCollateral(address receiver) internal pure returns (Call memory) {
        return _call(
            GENERAL_ADAPTER1,
            abi.encodeCall(GeneralAdapter1.morphoWithdrawCollateral, (marketParams(), type(uint256).max, receiver))
        );
    }

    function _wcmBuy(address wcmAdapter, uint256 amountOut, uint256 maxAmountIn) internal view returns (Call memory) {
        return _call(
            wcmAdapter, abi.encodeCall(IWcmAdapter.buy, (USDM, WITRY, amountOut, maxAmountIn, BORROWER, _deadline()))
        );
    }

    function _wcmSell(address wcmAdapter, uint256 amountIn, uint256 minAmountOut) internal view returns (Call memory) {
        return _call(
            wcmAdapter,
            abi.encodeCall(
                IWcmAdapter.sell, (USDM, WITRY, amountIn, minAmountOut, false, GENERAL_ADAPTER1, _deadline())
            )
        );
    }

    function _wcmBuyMorphoDebt(address wcmAdapter, uint256 maxAmountIn) internal view returns (Call memory) {
        return _call(
            wcmAdapter,
            abi.encodeCall(
                IWcmAdapter.buyMorphoDebt, (WITRY, marketParams(), maxAmountIn, BORROWER, GENERAL_ADAPTER1, _deadline())
            )
        );
    }

    function _logTokenBalances(string memory label, address account) internal view {
        console2.log(label);
        console2.log("  account", account);
        console2.log("  ETH", account.balance);
        console2.log("  USDm", IERC20(USDM).balanceOf(account));
        console2.log("  wiTRY", IERC20(WITRY).balanceOf(account));
    }

    function _logBorrowerPosition() internal view {
        Position memory p = IMorpho(MORPHO).position(_marketId(), BORROWER);
        uint256 debt = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams(), BORROWER);
        console2.log("Borrower Morpho position");
        console2.log("  supplyShares", p.supplyShares);
        console2.log("  borrowShares", p.borrowShares);
        console2.log("  expectedDebt", debt);
        console2.log("  collateral", uint256(p.collateral));
    }

    function _requireNoBorrowerPosition() internal view {
        Position memory p = IMorpho(MORPHO).position(_marketId(), BORROWER);
        uint256 debt = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams(), BORROWER);
        require(p.borrowShares == 0, "borrower has pre-existing borrow shares");
        require(debt == 0, "borrower has pre-existing debt");
        require(p.collateral == 0, "borrower has pre-existing collateral");
    }

    function _logAdapterState(address wcmAdapter) internal view {
        console2.log("WCM adapter", wcmAdapter);
        console2.log("  USDm balance", IERC20(USDM).balanceOf(wcmAdapter));
        console2.log("  wiTRY balance", IERC20(WITRY).balanceOf(wcmAdapter));
        console2.log("  USDm router allowance", IERC20(USDM).allowance(wcmAdapter, WORLD_SWAP_ROUTER));
        console2.log("  wiTRY router allowance", IERC20(WITRY).allowance(wcmAdapter, WORLD_SWAP_ROUTER));
        console2.log("GeneralAdapter1");
        console2.log("  USDm balance", IERC20(USDM).balanceOf(GENERAL_ADAPTER1));
        console2.log("  wiTRY balance", IERC20(WITRY).balanceOf(GENERAL_ADAPTER1));
    }

    function _assertWcmClean(address wcmAdapter) internal view {
        require(IERC20(USDM).balanceOf(wcmAdapter) == 0, "wcm usdm stranded");
        require(IERC20(WITRY).balanceOf(wcmAdapter) == 0, "wcm witry stranded");
        require(IERC20(USDM).allowance(wcmAdapter, WORLD_SWAP_ROUTER) == 0, "wcm usdm approval");
        require(IERC20(WITRY).allowance(wcmAdapter, WORLD_SWAP_ROUTER) == 0, "wcm witry approval");
    }

    function _assertGeneralAdapterClean() internal view {
        require(IERC20(USDM).balanceOf(GENERAL_ADAPTER1) == 0, "general usdm stranded");
        require(IERC20(WITRY).balanceOf(GENERAL_ADAPTER1) == 0, "general witry stranded");
    }
}

contract WcmPreflightLive is WcmLiveBase {
    function run() external view {
        _requireMegaEth();
        console2.log("block", block.number);
        _logTokenBalances("borrower", BORROWER);
        _logTokenBalances("lender", LENDER);
        _logTokenBalances("liquidation", LIQUIDATION);
        _logTokenBalances("executor", EXECUTOR);
        _logBorrowerPosition();
        console2.log("Borrower authorizes GeneralAdapter1", IMorpho(MORPHO).isAuthorized(BORROWER, GENERAL_ADAPTER1));
        console2.log("Borrower USDm allowance to GeneralAdapter1", IERC20(USDM).allowance(BORROWER, GENERAL_ADAPTER1));
        console2.log("Borrower wiTRY allowance to GeneralAdapter1", IERC20(WITRY).allowance(BORROWER, GENERAL_ADAPTER1));

        address wcmAdapter = vm.envOr("WCM_ADAPTER_ADDRESS", address(0));
        if (wcmAdapter != address(0)) _logAdapterState(wcmAdapter);
    }
}

contract WcmDeployLive is WcmLiveBase {
    function run() external returns (address deployed) {
        _requireMegaEth();
        uint256 pk = _borrowerPk();
        vm.startBroadcast(pk);
        WcmAdapter adapter = new WcmAdapter(
            BUNDLER3,
            MORPHO,
            WORLD_SWAP_ROUTER,
            MEGAETH_CHAIN_ID,
            WORLD_SWAP_ROUTER_CODE_HASH,
            USDM,
            WITRY,
            ORACLE,
            IRM,
            LLTV
        );
        deployed = address(adapter);
        vm.stopBroadcast();

        console2.log("WCM adapter deployed", deployed);
        console2.log("WCM adapter codehash");
        console2.logBytes32(deployed.codehash);
        _validateWcmAdapterImmutables(deployed);
    }
}

contract WcmPrepareLive is WcmLiveBase {
    function run() external {
        _requireMegaEth();
        uint256 pk = _borrowerPk();
        uint256 slippageBps = _slippageBps();
        bool useMaxApprovals = _useMaxApprovals();

        uint256 usdmApproval =
            useMaxApprovals ? type(uint256).max : _quoteExactOut(USDM, WITRY, _buyWitryAmountOut(), slippageBps);

        uint256 debtBefore = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams(), BORROWER);
        uint256 estimatedCloseDebt = _roundUpToUsdmWorldTick(debtBefore + _openBorrowAmount());
        uint256 estimatedCloseMaxIn = _quoteExactOut(WITRY, USDM, estimatedCloseDebt, slippageBps);
        uint256 witryApproval = useMaxApprovals ? type(uint256).max : _openInitialCollateral() + estimatedCloseMaxIn;

        vm.startBroadcast(pk);
        if (!IMorpho(MORPHO).isAuthorized(BORROWER, GENERAL_ADAPTER1)) {
            IMorpho(MORPHO).setAuthorization(GENERAL_ADAPTER1, true);
        }
        _approveIfNeeded(USDM, usdmApproval, "usdm approve failed");
        _approveIfNeeded(WITRY, witryApproval, "witry approve failed");
        vm.stopBroadcast();

        console2.log("Max approvals enabled", useMaxApprovals);
        console2.log("Target USDm allowance to GeneralAdapter1", usdmApproval);
        console2.log("Target wiTRY allowance to GeneralAdapter1", witryApproval);
        console2.log("Borrower authorizes GeneralAdapter1", IMorpho(MORPHO).isAuthorized(BORROWER, GENERAL_ADAPTER1));
        console2.log("Borrower USDm allowance to GeneralAdapter1", IERC20(USDM).allowance(BORROWER, GENERAL_ADAPTER1));
        console2.log("Borrower wiTRY allowance to GeneralAdapter1", IERC20(WITRY).allowance(BORROWER, GENERAL_ADAPTER1));
    }
}

contract WcmBuyLive is WcmLiveBase {
    function run() external {
        uint256 pk = _borrowerPk();
        address wcmAdapter = _wcmAdapter();
        uint256 amountOut = _buyWitryAmountOut();
        uint256 maxAmountIn = _quoteExactOut(USDM, WITRY, amountOut, _slippageBps());

        console2.log("buy amountOut wiTRY", amountOut);
        console2.log("buy maxAmountIn USDm", maxAmountIn);
        require(IERC20(USDM).balanceOf(BORROWER) >= maxAmountIn, "borrower usdm too low");
        require(IERC20(USDM).allowance(BORROWER, GENERAL_ADAPTER1) >= maxAmountIn, "usdm allowance too low");

        uint256 borrowerWitryBefore = IERC20(WITRY).balanceOf(BORROWER);

        Call[] memory bundle = new Call[](3);
        bundle[0] = _erc20TransferFrom(USDM, wcmAdapter, maxAmountIn);
        bundle[1] = _wcmBuy(wcmAdapter, amountOut, maxAmountIn);
        bundle[2] = _erc20Transfer(wcmAdapter, USDM, BORROWER, type(uint256).max);

        vm.startBroadcast(pk);
        Bundler3(payable(BUNDLER3)).multicall(bundle);
        vm.stopBroadcast();

        uint256 borrowerWitryDelta = IERC20(WITRY).balanceOf(BORROWER) - borrowerWitryBefore;
        console2.log("buy borrower wiTRY delta", borrowerWitryDelta);
        require(borrowerWitryDelta >= amountOut, "buy underfilled");
        _assertWcmClean(wcmAdapter);
    }
}

contract WcmSellLive is WcmLiveBase {
    function run() external {
        uint256 pk = _borrowerPk();
        address wcmAdapter = _wcmAdapter();
        uint256 amountIn = _sellWitryAmountIn();
        uint256 minAmountOut = _quoteExactIn(WITRY, USDM, amountIn, _slippageBps());

        console2.log("sell amountIn wiTRY", amountIn);
        console2.log("sell minAmountOut USDm", minAmountOut);
        require(IERC20(WITRY).balanceOf(BORROWER) >= amountIn, "borrower witry too low");
        require(IERC20(WITRY).allowance(BORROWER, GENERAL_ADAPTER1) >= amountIn, "witry allowance too low");

        uint256 borrowerUsdmBefore = IERC20(USDM).balanceOf(BORROWER);

        Call[] memory bundle = new Call[](3);
        bundle[0] = _erc20TransferFrom(WITRY, wcmAdapter, amountIn);
        bundle[1] = _call(
            wcmAdapter,
            abi.encodeCall(IWcmAdapter.sell, (WITRY, USDM, amountIn, minAmountOut, false, BORROWER, _deadline()))
        );
        bundle[2] = _erc20Transfer(wcmAdapter, WITRY, BORROWER, type(uint256).max);

        vm.startBroadcast(pk);
        Bundler3(payable(BUNDLER3)).multicall(bundle);
        vm.stopBroadcast();

        uint256 borrowerUsdmDelta = IERC20(USDM).balanceOf(BORROWER) - borrowerUsdmBefore;
        console2.log("sell borrower USDm delta", borrowerUsdmDelta);
        require(borrowerUsdmDelta >= minAmountOut, "sell underfilled");
        _assertWcmClean(wcmAdapter);
    }
}

contract WcmOpenLive is WcmLiveBase {
    function run() external {
        uint256 pk = _borrowerPk();
        address wcmAdapter = _wcmAdapter();
        uint256 initialCollateral = _openInitialCollateral();
        uint256 borrowAmount = _openBorrowAmount();
        uint256 minAmountOut = _quoteExactIn(USDM, WITRY, borrowAmount, _slippageBps());

        uint256 debtBefore = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams(), BORROWER);
        uint256 estimatedCloseDebt = _roundUpToUsdmWorldTick(debtBefore + borrowAmount);
        uint256 estimatedCloseMaxIn = _quoteExactOut(WITRY, USDM, estimatedCloseDebt, _slippageBps());
        uint256 borrowerWitryBefore = IERC20(WITRY).balanceOf(BORROWER);

        console2.log("open initialCollateral wiTRY", initialCollateral);
        console2.log("open borrowAmount USDm", borrowAmount);
        console2.log("open minAmountOut wiTRY", minAmountOut);
        console2.log("estimated close maxIn wiTRY", estimatedCloseMaxIn);

        require(IMorpho(MORPHO).isAuthorized(BORROWER, GENERAL_ADAPTER1), "missing morpho authorization");
        _requireNoBorrowerPosition();
        require(borrowerWitryBefore >= initialCollateral + estimatedCloseMaxIn, "not enough free wiTRY for open+close");
        require(
            IERC20(WITRY).allowance(BORROWER, GENERAL_ADAPTER1) >= initialCollateral + estimatedCloseMaxIn,
            "witry allowance too low"
        );

        Position memory positionBefore = IMorpho(MORPHO).position(_marketId(), BORROWER);

        Call[] memory bundle = new Call[](9);
        bundle[0] = _erc20TransferFrom(WITRY, GENERAL_ADAPTER1, initialCollateral);
        bundle[1] = _morphoSupplyCollateral(initialCollateral, BORROWER);
        bundle[2] = _morphoBorrow(borrowAmount, wcmAdapter);
        bundle[3] = _wcmSell(wcmAdapter, borrowAmount, minAmountOut);
        bundle[4] = _morphoSupplyCollateral(type(uint256).max, BORROWER);
        bundle[5] = _erc20Transfer(wcmAdapter, USDM, BORROWER, type(uint256).max);
        bundle[6] = _erc20Transfer(wcmAdapter, WITRY, BORROWER, type(uint256).max);
        bundle[7] = _erc20Transfer(GENERAL_ADAPTER1, USDM, BORROWER, type(uint256).max);
        bundle[8] = _erc20Transfer(GENERAL_ADAPTER1, WITRY, BORROWER, type(uint256).max);

        vm.startBroadcast(pk);
        Bundler3(payable(BUNDLER3)).multicall(bundle);
        vm.stopBroadcast();

        Position memory positionAfter = IMorpho(MORPHO).position(_marketId(), BORROWER);
        uint256 debtAfter = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams(), BORROWER);
        console2.log("open collateral delta", uint256(positionAfter.collateral) - uint256(positionBefore.collateral));
        console2.log("open debt before", debtBefore);
        console2.log("open debt after", debtAfter);
        require(debtAfter > debtBefore, "debt did not increase");
        require(positionAfter.collateral > positionBefore.collateral, "collateral did not increase");
        _assertWcmClean(wcmAdapter);
        _assertGeneralAdapterClean();
    }
}

contract WcmCloseLive is WcmLiveBase {
    function run() external {
        uint256 pk = _borrowerPk();
        address wcmAdapter = _wcmAdapter();

        uint256 debtBefore = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams(), BORROWER);
        uint256 roundedDebt = _roundUpToUsdmWorldTick(debtBefore);
        uint256 maxAmountIn = _quoteExactOut(WITRY, USDM, roundedDebt, _slippageBps());
        uint256 borrowerWitryBefore = IERC20(WITRY).balanceOf(BORROWER);

        console2.log("close debtBefore USDm", debtBefore);
        console2.log("close roundedDebt USDm", roundedDebt);
        console2.log("close maxAmountIn wiTRY", maxAmountIn);

        require(debtBefore != 0, "no debt to close");
        require(IMorpho(MORPHO).isAuthorized(BORROWER, GENERAL_ADAPTER1), "missing morpho authorization");
        require(borrowerWitryBefore >= maxAmountIn, "borrower wiTRY too low");
        require(IERC20(WITRY).allowance(BORROWER, GENERAL_ADAPTER1) >= maxAmountIn, "witry allowance too low");

        Call[] memory bundle = new Call[](7);
        bundle[0] = _erc20TransferFrom(WITRY, wcmAdapter, maxAmountIn);
        bundle[1] = _wcmBuyMorphoDebt(wcmAdapter, maxAmountIn);
        bundle[2] = _morphoRepayAll(BORROWER);
        bundle[3] = _erc20Transfer(wcmAdapter, WITRY, BORROWER, type(uint256).max);
        bundle[4] = _erc20Transfer(GENERAL_ADAPTER1, USDM, BORROWER, type(uint256).max);
        bundle[5] = _morphoWithdrawAllCollateral(BORROWER);
        bundle[6] = _erc20Transfer(GENERAL_ADAPTER1, WITRY, BORROWER, type(uint256).max);

        vm.startBroadcast(pk);
        Bundler3(payable(BUNDLER3)).multicall(bundle);
        vm.stopBroadcast();

        Position memory positionAfter = IMorpho(MORPHO).position(_marketId(), BORROWER);
        uint256 debtAfter = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams(), BORROWER);
        console2.log("close actual wiTRY max sent", maxAmountIn);
        console2.log("close final borrowShares", uint256(positionAfter.borrowShares));
        console2.log("close final expectedDebt", debtAfter);
        console2.log("close final collateral", uint256(positionAfter.collateral));
        require(positionAfter.borrowShares == 0, "borrow shares not zero");
        require(debtAfter == 0, "debt not zero");
        require(positionAfter.collateral == 0, "collateral not zero");
        _assertWcmClean(wcmAdapter);
        _assertGeneralAdapterClean();
    }
}

contract WcmFinalCheckLive is WcmLiveBase {
    function run() external view {
        address wcmAdapter = _wcmAdapter();
        _logTokenBalances("borrower", BORROWER);
        _logBorrowerPosition();
        _logAdapterState(wcmAdapter);

        Position memory p = IMorpho(MORPHO).position(_marketId(), BORROWER);
        uint256 debt = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams(), BORROWER);
        require(p.borrowShares == 0, "borrow shares not zero");
        require(debt == 0, "debt not zero");
        require(p.collateral == 0, "collateral not zero");
        _assertWcmClean(wcmAdapter);
        _assertGeneralAdapterClean();
    }
}
