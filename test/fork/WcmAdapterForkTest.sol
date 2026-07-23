// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {WcmAdapter} from "../../src/adapters/WcmAdapter.sol";
import {CoreAdapter} from "../../src/adapters/CoreAdapter.sol";
import {GeneralAdapter1} from "../../src/adapters/GeneralAdapter1.sol";
import {IWcmAdapter} from "../../src/interfaces/IWcmAdapter.sol";
import {Bundler3, Call} from "../../src/Bundler3.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

import {Id, IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";

contract WcmAdapterForkTest is Test {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    address internal constant MORPHO = 0x18120312A7cf44DcfEc6dCe5632a431579ED9100;
    address internal constant WORLD_SWAP_ROUTER = 0x94b6706FA26a4F3DCF501Ff25E1e4628B75AdC69;
    address internal constant USDM = 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7;
    address internal constant WITRY = 0x15B271D9012b5820FC42b1c495B4C1e206547De5;
    address internal constant ORACLE = 0x5D15337913F6A2C29ecf37Af9E812d81dD77888d;
    address internal constant OLD_ORACLE = 0xEebB019a6C66826f8BA8A583177E0dd5feEd0F22;
    address internal constant IRM = 0x56875764185548B0ca72A1877b3aE15E44e8A323;
    bytes32 internal constant WORLD_SWAP_ROUTER_CODE_HASH =
        0x4fd3bfa5a8737b3e7411a83d8968153870956c17e0caac728dbfdc3399ba8a66;
    bytes4 internal constant WORLD_SWAP_SLIPPAGE_ERROR = 0x2256e4c8;

    uint256 internal constant LLTV = 770000000000000000;
    uint256 internal constant MEGAETH_CHAIN_ID = 4326;
    bytes32 internal constant MARKET_ID = 0xa9e57f86cc877f38f2daf080df6638f01afe017eaed59fa3b2f688f6e6d4bf19;
    uint256 internal constant FORK_BLOCK = 21_959_976;
    uint256 internal constant USDM_WORLD_TICK = 1e14;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal receiver = makeAddr("receiver");

    Bundler3 internal bundler3;
    GeneralAdapter1 internal generalAdapter1;
    WcmAdapter internal wcmAdapter;
    MarketParams internal marketParams;

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL_4326");
        assertEq(vm.parseUint(vm.toString(vm.rpc(rpcUrl, "eth_chainId", "[]"))), MEGAETH_CHAIN_ID, "rpc chain id");
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        vm.chainId(MEGAETH_CHAIN_ID);
        assertEq(block.chainid, MEGAETH_CHAIN_ID, "chain id");
        assertEq(WORLD_SWAP_ROUTER.codehash, WORLD_SWAP_ROUTER_CODE_HASH, "router codehash");

        bundler3 = new Bundler3();
        generalAdapter1 = new GeneralAdapter1(address(bundler3), MORPHO, address(1));
        wcmAdapter = new WcmAdapter(
            address(bundler3),
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

        marketParams = MarketParams({loanToken: USDM, collateralToken: WITRY, oracle: ORACLE, irm: IRM, lltv: LLTV});
        assertEq(Id.unwrap(marketParams.id()), MARKET_ID, "target market id");
    }

    function testTargetMarketTupleMatchesMorphoRegistration() public view {
        MarketParams memory registered = IMorpho(MORPHO).idToMarketParams(Id.wrap(MARKET_ID));

        assertEq(registered.loanToken, USDM, "loan token");
        assertEq(registered.collateralToken, WITRY, "collateral token");
        assertEq(registered.oracle, ORACLE, "oracle");
        assertEq(registered.irm, IRM, "irm");
        assertEq(registered.lltv, LLTV, "lltv");
        assertEq(Id.unwrap(registered.id()), MARKET_ID, "registered market id");
    }

    function testBuyMorphoDebtRejectsOldMarketTuple() public {
        MarketParams memory oldMarket =
            MarketParams({loanToken: USDM, collateralToken: WITRY, oracle: OLD_ORACLE, irm: IRM, lltv: LLTV});
        deal(WITRY, address(wcmAdapter), 700e18);

        Call[] memory calls = new Call[](1);
        calls[0] = _wcmBuyMorphoDebt(WITRY, oldMarket, 700e18, borrower, receiver);

        vm.expectRevert(ErrorsLib.InvalidMorphoMarket.selector);
        vm.prank(borrower);
        bundler3.multicall(calls);
    }

    function testSellThroughWorldRouterForwardsBalanceDelta() public {
        uint256 amountIn = 600e18;
        uint256 minAmountOut = 12e18;

        deal(WITRY, address(wcmAdapter), amountIn);

        uint256 receiverBefore = IERC20(USDM).balanceOf(receiver);

        Call[] memory calls = new Call[](1);
        calls[0] = _wcmSell(WITRY, USDM, amountIn, minAmountOut, false, receiver);
        bundler3.multicall(calls);

        uint256 received = IERC20(USDM).balanceOf(receiver) - receiverBefore;
        assertGe(received, minAmountOut, "receiver USDm delta");
        assertEq(IERC20(USDM).balanceOf(address(wcmAdapter)), 0, "adapter USDm");
        assertEq(IERC20(WITRY).balanceOf(address(wcmAdapter)), 0, "adapter wiTRY");
        assertEq(IERC20(WITRY).allowance(address(wcmAdapter), WORLD_SWAP_ROUTER), 0, "router allowance");
    }

    function testBuyThroughWorldRouterForwardsBalanceDelta() public {
        uint256 amountOut = 600e18;
        uint256 maxAmountIn = 15e18;

        deal(USDM, address(wcmAdapter), maxAmountIn);

        uint256 receiverBefore = IERC20(WITRY).balanceOf(receiver);

        Call[] memory calls = new Call[](2);
        calls[0] = _wcmBuy(USDM, WITRY, amountOut, maxAmountIn, receiver);
        calls[1] = _erc20Transfer(wcmAdapter, USDM, receiver, type(uint256).max);
        bundler3.multicall(calls);

        uint256 received = IERC20(WITRY).balanceOf(receiver) - receiverBefore;
        assertGe(received, amountOut, "receiver wiTRY delta");
        assertEq(IERC20(WITRY).balanceOf(address(wcmAdapter)), 0, "adapter wiTRY");
        assertEq(IERC20(USDM).balanceOf(address(wcmAdapter)), 0, "adapter USDm");
        assertEq(IERC20(USDM).allowance(address(wcmAdapter), WORLD_SWAP_ROUTER), 0, "router allowance");
    }

    function testBuyMorphoDebtThroughWorldRouterForwardsRoundedDebt() public {
        _createFreshMorphoPosition();

        uint256 debt = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams, borrower);
        uint256 roundedDebt = _roundUpToUsdmWorldTick(debt);
        uint256 maxAmountIn = 700e18;

        assertGe(debt, 12e18, "debt too small");
        assertLe(debt, 15e18, "debt too large");

        deal(WITRY, address(wcmAdapter), maxAmountIn);

        uint256 receiverBefore = IERC20(USDM).balanceOf(receiver);

        Call[] memory calls = new Call[](2);
        calls[0] = _wcmBuyMorphoDebt(WITRY, marketParams, maxAmountIn, borrower, receiver);
        calls[1] = _erc20Transfer(wcmAdapter, WITRY, receiver, type(uint256).max);
        vm.prank(borrower);
        bundler3.multicall(calls);

        uint256 received = IERC20(USDM).balanceOf(receiver) - receiverBefore;
        assertGe(received, roundedDebt, "receiver USDm delta");
        assertEq(IERC20(USDM).balanceOf(address(wcmAdapter)), 0, "adapter USDm");
        assertEq(IERC20(WITRY).balanceOf(address(wcmAdapter)), 0, "adapter wiTRY");
        assertEq(IERC20(WITRY).allowance(address(wcmAdapter), WORLD_SWAP_ROUTER), 0, "router allowance");
    }

    function testBuyMorphoDebtCanFundMorphoRepay() public {
        _createFreshMorphoPosition();

        uint256 maxAmountIn = 700e18;
        deal(WITRY, address(wcmAdapter), maxAmountIn);

        Call[] memory calls = new Call[](6);
        calls[0] = _wcmBuyMorphoDebt(WITRY, marketParams, maxAmountIn, borrower, address(generalAdapter1));
        calls[1] = _morphoRepay(0, type(uint256).max, borrower);
        calls[2] = _erc20Transfer(generalAdapter1, USDM, receiver, type(uint256).max);
        calls[3] = _morphoWithdrawAllCollateral(receiver);
        calls[4] = _erc20Transfer(wcmAdapter, WITRY, receiver, type(uint256).max);
        calls[5] = _erc20Transfer(generalAdapter1, WITRY, receiver, type(uint256).max);
        vm.prank(borrower);
        bundler3.multicall(calls);

        uint256 debtAfter = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams, borrower);
        assertEq(debtAfter, 0, "remaining debt");
        assertEq(IMorpho(MORPHO).position(marketParams.id(), borrower).collateral, 0, "remaining collateral");
        assertEq(IERC20(USDM).balanceOf(address(wcmAdapter)), 0, "adapter USDm");
        assertEq(IERC20(WITRY).balanceOf(address(wcmAdapter)), 0, "adapter wiTRY");
        assertEq(IERC20(USDM).balanceOf(address(generalAdapter1)), 0, "general adapter USDm");
        assertEq(IERC20(WITRY).balanceOf(address(generalAdapter1)), 0, "general adapter wiTRY");
        assertEq(IERC20(WITRY).allowance(address(wcmAdapter), WORLD_SWAP_ROUTER), 0, "router allowance");
    }

    function testSellUnderfillRevertsThroughWorldRouter() public {
        deal(WITRY, address(wcmAdapter), 600e18);

        Call[] memory calls = new Call[](1);
        calls[0] = _wcmSell(WITRY, USDM, 600e18, 100e18, false, receiver);

        vm.expectRevert(WORLD_SWAP_SLIPPAGE_ERROR);
        bundler3.multicall(calls);
    }

    function testBuyMaxSpendRevertsThroughWorldRouter() public {
        deal(USDM, address(wcmAdapter), 1e18);

        Call[] memory calls = new Call[](1);
        calls[0] = _wcmBuy(USDM, WITRY, 600e18, 1e18, receiver);

        vm.expectRevert(WORLD_SWAP_SLIPPAGE_ERROR);
        bundler3.multicall(calls);
    }

    function _createFreshMorphoPosition() internal {
        deal(USDM, lender, 200e18);
        vm.startPrank(lender);
        IERC20(USDM).forceApprove(MORPHO, 200e18);
        IMorpho(MORPHO).supply(marketParams, 200e18, 0, lender, hex"");
        vm.stopPrank();

        deal(WITRY, borrower, 1000e18);
        vm.startPrank(borrower);
        IERC20(WITRY).forceApprove(MORPHO, 1000e18);
        IMorpho(MORPHO).setAuthorization(address(generalAdapter1), true);
        IMorpho(MORPHO).supplyCollateral(marketParams, 1000e18, borrower, hex"");
        IMorpho(MORPHO).borrow(marketParams, 12e18, 0, borrower, borrower);
        vm.stopPrank();
    }

    function _call(address to, bytes memory data) internal pure returns (Call memory) {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }

    function _call(CoreAdapter to, bytes memory data) internal pure returns (Call memory) {
        return _call(address(to), data);
    }

    function _erc20Transfer(CoreAdapter adapter, address token, address to, uint256 amount)
        internal
        pure
        returns (Call memory)
    {
        return _call(adapter, abi.encodeCall(CoreAdapter.erc20Transfer, (token, to, amount)));
    }

    function _morphoRepay(uint256 assets, uint256 shares, address onBehalf) internal view returns (Call memory) {
        return _call(
            generalAdapter1,
            abi.encodeCall(
                GeneralAdapter1.morphoRepay, (marketParams, assets, shares, type(uint256).max, onBehalf, hex"")
            )
        );
    }

    function _morphoWithdrawAllCollateral(address to) internal view returns (Call memory) {
        return _call(
            generalAdapter1,
            abi.encodeCall(GeneralAdapter1.morphoWithdrawCollateral, (marketParams, type(uint256).max, to))
        );
    }

    function _wcmSell(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bool sellEntireBalance,
        address to
    ) internal view returns (Call memory) {
        return _call(
            wcmAdapter,
            abi.encodeCall(
                IWcmAdapter.sell,
                (tokenIn, tokenOut, amountIn, minAmountOut, sellEntireBalance, to, block.timestamp + 1 hours)
            )
        );
    }

    function _wcmBuy(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxAmountIn, address to)
        internal
        view
        returns (Call memory)
    {
        return _call(
            wcmAdapter,
            abi.encodeCall(IWcmAdapter.buy, (tokenIn, tokenOut, amountOut, maxAmountIn, to, block.timestamp + 1 hours))
        );
    }

    function _wcmBuyMorphoDebt(
        address tokenIn,
        MarketParams memory _marketParams,
        uint256 maxAmountIn,
        address onBehalf,
        address to
    ) internal view returns (Call memory) {
        return _call(
            wcmAdapter,
            abi.encodeCall(
                IWcmAdapter.buyMorphoDebt,
                (tokenIn, _marketParams, maxAmountIn, onBehalf, to, block.timestamp + 1 hours)
            )
        );
    }

    function _roundUpToUsdmWorldTick(uint256 amount) internal pure returns (uint256) {
        uint256 ticks = amount / USDM_WORLD_TICK;
        if (amount % USDM_WORLD_TICK != 0) ++ticks;
        return ticks * USDM_WORLD_TICK;
    }
}
