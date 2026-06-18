// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {WcmAdapter} from "../src/adapters/WcmAdapter.sol";
import {CoreAdapter} from "../src/adapters/CoreAdapter.sol";
import {IWcmAdapter} from "../src/interfaces/IWcmAdapter.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {Bundler3, Call} from "../src/Bundler3.sol";

import {Id, IMorpho, Market, MarketParams} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoStorageLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoStorageLib.sol";

import {ERC20Mock} from "./helpers/mocks/ERC20Mock.sol";
import {WcmRouterMock} from "./helpers/mocks/WcmRouterMock.sol";
import "../lib/forge-std/src/Test.sol";

contract MorphoDebtMock {
    using MarketParamsLib for MarketParams;

    mapping(Id => Market) public market;
    mapping(Id => mapping(address => uint256)) public borrowShares;
    mapping(bytes32 => bytes32) internal extSlot;

    function setDebt(MarketParams memory marketParams, address onBehalf, uint256 debt) external {
        Id id = marketParams.id();
        market[id] = Market({
            totalSupplyAssets: 0,
            totalSupplyShares: 0,
            totalBorrowAssets: uint128(debt),
            totalBorrowShares: uint128(debt),
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        borrowShares[id][onBehalf] = debt;
        extSlot[MorphoStorageLib.positionBorrowSharesAndCollateralSlot(id, onBehalf)] = bytes32(uint256(uint128(debt)));
    }

    function extSloads(bytes32[] memory slots) external view returns (bytes32[] memory res) {
        res = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            res[i] = extSlot[slots[i]];
        }
    }
}

contract WcmAdapterLocalTest is Test {
    using MarketParamsLib for MarketParams;

    address internal immutable RECEIVER = makeAddr("Receiver");

    Bundler3 internal bundler3;
    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    WcmAdapter internal wcmAdapter;
    WcmRouterMock internal wcmRouter;
    MorphoDebtMock internal morpho;
    Call[] internal bundle;

    MarketParams internal marketParams;

    address internal constant ORACLE = address(1);
    address internal constant IRM = address(2);
    uint256 internal constant USDM_WORLD_TICK = 1e14;
    uint256 internal constant LLTV = 0.8 ether;

    function setUp() public {
        bundler3 = new Bundler3();
        loanToken = new ERC20Mock("loan", "B");
        collateralToken = new ERC20Mock("collateral", "C");
        morpho = new MorphoDebtMock();
        wcmRouter = new WcmRouterMock();
        wcmAdapter = new WcmAdapter(
            address(bundler3),
            address(morpho),
            address(wcmRouter),
            block.chainid,
            address(wcmRouter).codehash,
            address(loanToken),
            address(collateralToken),
            ORACLE,
            IRM,
            LLTV
        );

        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: ORACLE,
            irm: IRM,
            lltv: LLTV
        });
    }

    function testConstructor() public {
        address rdmAddress = address(1);
        uint256 chainId = block.chainid;
        bytes32 routerCodeHash = bytes32(uint256(1));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new WcmAdapter(
            address(0),
            rdmAddress,
            rdmAddress,
            chainId,
            routerCodeHash,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            LLTV
        );

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new WcmAdapter(
            rdmAddress,
            address(0),
            rdmAddress,
            chainId,
            routerCodeHash,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            LLTV
        );

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new WcmAdapter(
            rdmAddress,
            rdmAddress,
            address(0),
            chainId,
            routerCodeHash,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            LLTV
        );

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        new WcmAdapter(
            rdmAddress, rdmAddress, rdmAddress, 0, routerCodeHash, rdmAddress, rdmAddress, rdmAddress, rdmAddress, LLTV
        );

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        new WcmAdapter(
            rdmAddress,
            rdmAddress,
            rdmAddress,
            chainId,
            bytes32(0),
            rdmAddress,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            LLTV
        );

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new WcmAdapter(
            rdmAddress,
            rdmAddress,
            rdmAddress,
            chainId,
            routerCodeHash,
            address(0),
            rdmAddress,
            rdmAddress,
            rdmAddress,
            LLTV
        );

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new WcmAdapter(
            rdmAddress,
            rdmAddress,
            rdmAddress,
            chainId,
            routerCodeHash,
            rdmAddress,
            address(0),
            rdmAddress,
            rdmAddress,
            LLTV
        );

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new WcmAdapter(
            rdmAddress,
            rdmAddress,
            rdmAddress,
            chainId,
            routerCodeHash,
            rdmAddress,
            rdmAddress,
            address(0),
            rdmAddress,
            LLTV
        );

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new WcmAdapter(
            rdmAddress,
            rdmAddress,
            rdmAddress,
            chainId,
            routerCodeHash,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            address(0),
            LLTV
        );

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        new WcmAdapter(
            rdmAddress,
            rdmAddress,
            rdmAddress,
            chainId,
            routerCodeHash,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            0
        );

        vm.expectRevert(ErrorsLib.InvalidWcmPair.selector);
        new WcmAdapter(
            rdmAddress,
            rdmAddress,
            rdmAddress,
            chainId,
            routerCodeHash,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            rdmAddress,
            LLTV
        );
    }

    function testSellUnauthorized(address sender) public {
        vm.assume(sender != address(bundler3));

        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        vm.prank(sender);
        wcmAdapter.sell(address(collateralToken), address(loanToken), 1, 1, false, RECEIVER, block.timestamp);
    }

    function testBuyUnauthorized(address sender) public {
        vm.assume(sender != address(bundler3));

        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        vm.prank(sender);
        wcmAdapter.buy(address(collateralToken), address(loanToken), 1, 1, RECEIVER, block.timestamp);
    }

    function testBuyMorphoDebtUnauthorized(address sender) public {
        vm.assume(sender != address(bundler3));

        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        vm.prank(sender);
        wcmAdapter.buyMorphoDebt(address(collateralToken), marketParams, 1, address(this), RECEIVER, block.timestamp);
    }

    function testSellZeroAmount() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(address(bundler3));
        wcmAdapter.sell(address(collateralToken), address(loanToken), 0, 1, false, RECEIVER, block.timestamp);
    }

    function testSellZeroMinAmount() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(address(bundler3));
        wcmAdapter.sell(address(collateralToken), address(loanToken), 1, 0, false, RECEIVER, block.timestamp);
    }

    function testBuyZeroAmount() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(address(bundler3));
        wcmAdapter.buy(address(collateralToken), address(loanToken), 0, 1, RECEIVER, block.timestamp);
    }

    function testBuyZeroMaxAmount() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(address(bundler3));
        wcmAdapter.buy(address(collateralToken), address(loanToken), 1, 0, RECEIVER, block.timestamp);
    }

    function testReceiverZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(address(bundler3));
        wcmAdapter.sell(address(collateralToken), address(loanToken), 1, 1, false, address(0), block.timestamp);
    }

    function testReceiverAdapter() public {
        vm.expectRevert(ErrorsLib.AdapterAddress.selector);
        vm.prank(address(bundler3));
        wcmAdapter.buy(address(collateralToken), address(loanToken), 1, 1, address(wcmAdapter), block.timestamp);
    }

    function testDeadlineExpired() public {
        vm.warp(1 days);

        vm.expectRevert(ErrorsLib.DeadlineExpired.selector);
        vm.prank(address(bundler3));
        wcmAdapter.sell(address(collateralToken), address(loanToken), 1, 1, false, RECEIVER, block.timestamp - 1);
    }

    function testInvalidPair() public {
        vm.expectRevert(ErrorsLib.InvalidWcmPair.selector);
        vm.prank(address(bundler3));
        wcmAdapter.sell(address(loanToken), address(loanToken), 1, 1, false, RECEIVER, block.timestamp);
    }

    function testInvalidChainId() public {
        wcmAdapter = new WcmAdapter(
            address(bundler3),
            address(morpho),
            address(wcmRouter),
            block.chainid + 1,
            address(wcmRouter).codehash,
            address(loanToken),
            address(collateralToken),
            ORACLE,
            IRM,
            LLTV
        );

        deal(address(collateralToken), address(wcmAdapter), 1);

        vm.expectRevert(ErrorsLib.InvalidChainId.selector);
        bundle.push(_wcmSell(address(collateralToken), address(loanToken), 1, 1, false, RECEIVER));
        bundler3.multicall(bundle);
    }

    function testInvalidRouterCodeHash() public {
        wcmAdapter = new WcmAdapter(
            address(bundler3),
            address(morpho),
            address(wcmRouter),
            block.chainid,
            bytes32(uint256(1)),
            address(loanToken),
            address(collateralToken),
            ORACLE,
            IRM,
            LLTV
        );

        deal(address(collateralToken), address(wcmAdapter), 1);

        vm.expectRevert(ErrorsLib.InvalidWcmRouter.selector);
        bundle.push(_wcmSell(address(collateralToken), address(loanToken), 1, 1, false, RECEIVER));
        bundler3.multicall(bundle);
    }

    function testSellNoAdjustment() public {
        uint256 amount = 10e18;
        uint256 extra = 3e18;

        deal(address(collateralToken), address(wcmAdapter), amount + extra);

        bundle.push(_wcmSell(address(collateralToken), address(loanToken), amount, amount, false, RECEIVER));
        bundle.push(_erc20Transfer(address(collateralToken), address(this), type(uint256).max));

        bundler3.multicall(bundle);

        assertEq(loanToken.balanceOf(RECEIVER), amount, "receiver loan");
        assertEq(collateralToken.balanceOf(address(this)), extra, "source skim");
        assertEq(loanToken.balanceOf(address(wcmAdapter)), 0, "adapter loan");
        assertEq(collateralToken.balanceOf(address(wcmAdapter)), 0, "adapter collateral");
        assertEq(collateralToken.allowance(address(wcmAdapter), address(wcmRouter)), 0, "router allowance");
    }

    function testSellEntireBalance() public {
        uint256 amount = 10e18;

        deal(address(collateralToken), address(wcmAdapter), amount);

        bundle.push(_wcmSell(address(collateralToken), address(loanToken), 1, amount, true, RECEIVER));

        bundler3.multicall(bundle);

        assertEq(loanToken.balanceOf(RECEIVER), amount, "receiver loan");
        assertEq(collateralToken.balanceOf(address(wcmAdapter)), 0, "adapter collateral");
        assertEq(collateralToken.allowance(address(wcmAdapter), address(wcmRouter)), 0, "router allowance");
    }

    function testBuyForwardsDeltaAndRefundsUnspentSource() public {
        uint256 amount = 10e18;
        uint256 extra = 3e18;

        deal(address(collateralToken), address(wcmAdapter), amount + extra);

        bundle.push(_wcmBuy(address(collateralToken), address(loanToken), amount, amount + extra, RECEIVER));

        bundler3.multicall(bundle);

        assertEq(loanToken.balanceOf(RECEIVER), amount, "receiver loan");
        assertEq(collateralToken.balanceOf(RECEIVER), extra, "receiver source refund");
        assertEq(loanToken.balanceOf(address(wcmAdapter)), 0, "adapter loan");
        assertEq(collateralToken.balanceOf(address(wcmAdapter)), 0, "adapter collateral");
        assertEq(collateralToken.allowance(address(wcmAdapter), address(wcmRouter)), 0, "router allowance");
    }

    function testSellForwardsReceivedDeltaOnly() public {
        uint256 initialOutputDust = 7e18;
        uint256 amount = 10e18;

        deal(address(loanToken), address(wcmAdapter), initialOutputDust);
        deal(address(collateralToken), address(wcmAdapter), amount);

        bundle.push(_wcmSell(address(collateralToken), address(loanToken), amount, amount, false, RECEIVER));

        bundler3.multicall(bundle);

        assertEq(loanToken.balanceOf(RECEIVER), amount, "receiver loan");
        assertEq(loanToken.balanceOf(address(wcmAdapter)), initialOutputDust, "adapter output dust");
        assertEq(collateralToken.balanceOf(address(wcmAdapter)), 0, "adapter collateral");
    }

    function testSellUnderfillReverts() public {
        uint256 amount = 10e18;

        deal(address(collateralToken), address(wcmAdapter), amount);
        wcmRouter.setToGive(amount - 1);

        vm.expectRevert(ErrorsLib.BuyAmountTooLow.selector);
        bundle.push(_wcmSell(address(collateralToken), address(loanToken), amount, amount, false, RECEIVER));
        bundler3.multicall(bundle);
    }

    function testSellPartialSpendReverts() public {
        uint256 amount = 10e18;

        deal(address(collateralToken), address(wcmAdapter), amount);
        wcmRouter.setToTake(amount - 1);

        vm.expectRevert(ErrorsLib.SellAmountTooLow.selector);
        bundle.push(_wcmSell(address(collateralToken), address(loanToken), amount, amount - 1, false, RECEIVER));
        bundler3.multicall(bundle);
    }

    function testBuyUnderfillReverts() public {
        uint256 amount = 10e18;

        deal(address(collateralToken), address(wcmAdapter), amount);
        wcmRouter.setToGive(amount - 1);

        vm.expectRevert(ErrorsLib.BuyAmountTooLow.selector);
        bundle.push(_wcmBuy(address(collateralToken), address(loanToken), amount, amount, RECEIVER));
        bundler3.multicall(bundle);
    }

    function testBuyMorphoDebtZeroDebt() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundle.push(_wcmBuyMorphoDebt(address(collateralToken), marketParams, 1, address(this), RECEIVER));
        bundler3.multicall(bundle);
    }

    function testBuyMorphoDebtRequiresInitiatorOnBehalf() public {
        address other = makeAddr("other");

        vm.expectRevert(ErrorsLib.UnexpectedOwner.selector);
        bundle.push(_wcmBuyMorphoDebt(address(collateralToken), marketParams, 1, other, RECEIVER));
        bundler3.multicall(bundle);
    }

    function testBuyMorphoDebtInvalidMarket() public {
        MarketParams memory invalidMarketParams = MarketParams({
            loanToken: address(collateralToken),
            collateralToken: address(loanToken),
            oracle: address(1),
            irm: address(0),
            lltv: LLTV
        });

        vm.expectRevert(ErrorsLib.InvalidWcmPair.selector);
        bundle.push(_wcmBuyMorphoDebt(address(collateralToken), invalidMarketParams, 1, address(this), RECEIVER));
        bundler3.multicall(bundle);
    }

    function testBuyMorphoDebtInvalidPinnedMarket() public {
        MarketParams memory invalidMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(3),
            irm: IRM,
            lltv: LLTV
        });

        vm.expectRevert(ErrorsLib.InvalidMorphoMarket.selector);
        bundle.push(_wcmBuyMorphoDebt(address(collateralToken), invalidMarketParams, 1, address(this), RECEIVER));
        bundler3.multicall(bundle);
    }

    function testBuyMorphoDebtRoundsUpAndForwards() public {
        uint256 debtShares = 1e18 + 1;

        morpho.setDebt(marketParams, address(this), debtShares);

        uint256 debtAmount =
            MorphoBalancesLib.expectedBorrowAssets(IMorpho(address(morpho)), marketParams, address(this));
        uint256 roundedDebt = _roundUpToUsdmWorldTick(debtAmount);
        assertGt(roundedDebt, debtAmount, "debt should round up");

        deal(address(collateralToken), address(wcmAdapter), roundedDebt);

        bundle.push(_wcmBuyMorphoDebt(address(collateralToken), marketParams, roundedDebt, address(this), RECEIVER));

        bundler3.multicall(bundle);

        assertEq(loanToken.balanceOf(RECEIVER), roundedDebt, "receiver loan");
        assertEq(loanToken.balanceOf(address(wcmAdapter)), 0, "adapter loan");
        assertEq(collateralToken.balanceOf(address(wcmAdapter)), 0, "adapter collateral");
        assertEq(collateralToken.allowance(address(wcmAdapter), address(wcmRouter)), 0, "router allowance");
    }

    function testBuyMorphoDebtRefundsUnspentSourceToOnBehalf() public {
        uint256 debtShares = 10e18 + 1;
        uint256 extraSource = 3e18;

        morpho.setDebt(marketParams, address(this), debtShares);

        uint256 debtAmount =
            MorphoBalancesLib.expectedBorrowAssets(IMorpho(address(morpho)), marketParams, address(this));
        uint256 roundedDebt = _roundUpToUsdmWorldTick(debtAmount);
        uint256 maxAmountIn = roundedDebt + extraSource;

        deal(address(collateralToken), address(wcmAdapter), maxAmountIn);

        bundle.push(_wcmBuyMorphoDebt(address(collateralToken), marketParams, maxAmountIn, address(this), RECEIVER));

        bundler3.multicall(bundle);

        assertEq(loanToken.balanceOf(RECEIVER), roundedDebt, "receiver loan");
        assertEq(collateralToken.balanceOf(address(this)), extraSource, "onBehalf source refund");
        assertEq(collateralToken.balanceOf(RECEIVER), 0, "receiver source");
        assertEq(loanToken.balanceOf(address(wcmAdapter)), 0, "adapter loan");
        assertEq(collateralToken.balanceOf(address(wcmAdapter)), 0, "adapter collateral");
        assertEq(collateralToken.allowance(address(wcmAdapter), address(wcmRouter)), 0, "router allowance");
    }

    function _call(address to, bytes memory data) internal pure returns (Call memory) {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }

    function _call(CoreAdapter to, bytes memory data) internal pure returns (Call memory) {
        return _call(address(to), data);
    }

    function _erc20Transfer(address token, address receiver, uint256 amount) internal view returns (Call memory) {
        return _call(wcmAdapter, abi.encodeCall(CoreAdapter.erc20Transfer, (token, receiver, amount)));
    }

    function _wcmSell(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bool sellEntireBalance,
        address receiver
    ) internal view returns (Call memory) {
        return _call(
            wcmAdapter,
            abi.encodeCall(
                IWcmAdapter.sell,
                (tokenIn, tokenOut, amountIn, minAmountOut, sellEntireBalance, receiver, block.timestamp)
            )
        );
    }

    function _wcmBuy(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxAmountIn, address receiver)
        internal
        view
        returns (Call memory)
    {
        return _call(
            wcmAdapter,
            abi.encodeCall(IWcmAdapter.buy, (tokenIn, tokenOut, amountOut, maxAmountIn, receiver, block.timestamp))
        );
    }

    function _wcmBuyMorphoDebt(
        address tokenIn,
        MarketParams memory _marketParams,
        uint256 maxAmountIn,
        address onBehalf,
        address receiver
    ) internal view returns (Call memory) {
        return _call(
            wcmAdapter,
            abi.encodeCall(
                IWcmAdapter.buyMorphoDebt, (tokenIn, _marketParams, maxAmountIn, onBehalf, receiver, block.timestamp)
            )
        );
    }

    function _roundUpToUsdmWorldTick(uint256 amount) internal pure returns (uint256) {
        uint256 ticks = amount / USDM_WORLD_TICK;
        if (amount % USDM_WORLD_TICK != 0) ++ticks;
        return ticks * USDM_WORLD_TICK;
    }
}
