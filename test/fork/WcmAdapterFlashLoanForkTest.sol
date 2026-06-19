// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {WcmAdapter} from "../../src/adapters/WcmAdapter.sol";
import {CoreAdapter} from "../../src/adapters/CoreAdapter.sol";
import {GeneralAdapter1} from "../../src/adapters/GeneralAdapter1.sol";
import {IWcmAdapter} from "../../src/interfaces/IWcmAdapter.sol";
import {Bundler3, Call} from "../../src/Bundler3.sol";

import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";

contract WcmAdapterFlashLoanForkTest is Test {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    address internal constant MORPHO = 0x18120312A7cf44DcfEc6dCe5632a431579ED9100;
    address internal constant WORLD_SWAP_ROUTER = 0x94b6706FA26a4F3DCF501Ff25E1e4628B75AdC69;
    address internal constant USDM = 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7;
    address internal constant WITRY = 0x15B271D9012b5820FC42b1c495B4C1e206547De5;
    address internal constant ORACLE = 0xEebB019a6C66826f8BA8A583177E0dd5feEd0F22;
    address internal constant IRM = 0x56875764185548B0ca72A1877b3aE15E44e8A323;
    bytes32 internal constant WORLD_SWAP_ROUTER_CODE_HASH =
        0x4fd3bfa5a8737b3e7411a83d8968153870956c17e0caac728dbfdc3399ba8a66;

    uint256 internal constant LLTV = 770000000000000000;
    uint256 internal constant MEGAETH_CHAIN_ID = 4326;
    uint256 internal constant FORK_BLOCK = 19_054_909;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal collateralSupplier = makeAddr("collateralSupplier");

    Bundler3 internal bundler3;
    GeneralAdapter1 internal generalAdapter1;
    WcmAdapter internal wcmAdapter;
    MarketParams internal marketParams;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL_4326"), FORK_BLOCK);
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
    }

    function testFlashLoanFundedCloseViaBuyMorphoDebt() public {
        uint256 collateral = 1000e18;
        uint256 borrowAmount = 12e18;
        uint256 maxAmountIn = 700e18;

        _supplyLoanLiquidity(200e18);
        _supplyFlashLoanCollateralLiquidity(collateral);
        _createBorrowerPosition(collateral, borrowAmount);

        uint256 debtBefore = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams, borrower);
        assertGe(debtBefore, borrowAmount, "debt too small");
        assertLe(maxAmountIn, collateral, "flashloan transfer exceeds collateral");

        Call[] memory callbackBundle = new Call[](4);
        callbackBundle[0] = _erc20Transfer(generalAdapter1, WITRY, address(wcmAdapter), maxAmountIn);
        callbackBundle[1] = _wcmBuyMorphoDebt(WITRY, marketParams, maxAmountIn, borrower, address(generalAdapter1));
        callbackBundle[2] = _morphoRepayAll(borrower);
        callbackBundle[3] = _morphoWithdrawAllCollateral(address(generalAdapter1));

        Call[] memory calls = new Call[](4);
        calls[0] = _morphoFlashLoan(WITRY, collateral, abi.encode(callbackBundle));
        calls[1] = _erc20Transfer(generalAdapter1, USDM, borrower, type(uint256).max);
        calls[2] = _erc20Transfer(generalAdapter1, WITRY, borrower, type(uint256).max);
        calls[3] = _erc20Transfer(wcmAdapter, WITRY, borrower, type(uint256).max);

        uint256 borrowerWitryBefore = IERC20(WITRY).balanceOf(borrower);
        vm.prank(borrower);
        bundler3.multicall(calls);

        assertEq(MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams, borrower), 0, "debt");
        assertEq(IMorpho(MORPHO).position(marketParams.id(), borrower).collateral, 0, "collateral");
        assertGt(IERC20(WITRY).balanceOf(borrower), borrowerWitryBefore, "borrower wiTRY returned");
        _assertAdaptersClean();
        assertEq(IERC20(WITRY).allowance(address(wcmAdapter), WORLD_SWAP_ROUTER), 0, "wcm wiTRY allowance");
    }

    function testDirectExactInputUsdmToWitryReference() public {
        uint256 amountIn = 12e18;
        uint256 minAmountOut = 500e18;

        deal(USDM, address(wcmAdapter), amountIn);

        Call[] memory calls = new Call[](1);
        calls[0] = _wcmSell(USDM, WITRY, amountIn, minAmountOut, false, borrower);
        bundler3.multicall(calls);

        assertGe(IERC20(WITRY).balanceOf(borrower), minAmountOut, "borrower wiTRY");
        _assertAdaptersClean();
    }

    function testFlashLoanAssistedOpenViaSell() public {
        uint256 seedCollateral = 800e18;
        uint256 flashLoanAmount = 12e18;
        uint256 minAmountOut = 500e18;

        _supplyLoanLiquidity(200e18);
        _authorizeBorrower();
        deal(WITRY, borrower, seedCollateral);
        vm.prank(borrower);
        IERC20(WITRY).forceApprove(address(generalAdapter1), seedCollateral);

        Call[] memory callbackBundle = new Call[](4);
        callbackBundle[0] = _erc20Transfer(generalAdapter1, USDM, address(wcmAdapter), flashLoanAmount);
        callbackBundle[1] = _wcmSell(USDM, WITRY, flashLoanAmount, minAmountOut, false, address(generalAdapter1));
        callbackBundle[2] = _morphoSupplyCollateral(type(uint256).max, borrower);
        callbackBundle[3] = _morphoBorrow(flashLoanAmount, address(generalAdapter1));

        Call[] memory calls = new Call[](5);
        calls[0] = _erc20TransferFrom(WITRY, address(generalAdapter1), seedCollateral);
        calls[1] = _morphoSupplyCollateral(seedCollateral, borrower);
        calls[2] = _morphoFlashLoan(USDM, flashLoanAmount, abi.encode(callbackBundle));
        calls[3] = _erc20Transfer(generalAdapter1, USDM, borrower, type(uint256).max);
        calls[4] = _erc20Transfer(generalAdapter1, WITRY, borrower, type(uint256).max);

        vm.prank(borrower);
        bundler3.multicall(calls);

        uint256 debtAfter = MorphoBalancesLib.expectedBorrowAssets(IMorpho(MORPHO), marketParams, borrower);
        uint256 collateralAfter = IMorpho(MORPHO).position(marketParams.id(), borrower).collateral;
        assertGe(debtAfter, flashLoanAmount, "debt");
        assertGe(collateralAfter, seedCollateral + minAmountOut, "collateral");
        _assertAdaptersClean();
        assertEq(IERC20(USDM).allowance(address(wcmAdapter), WORLD_SWAP_ROUTER), 0, "wcm USDm allowance");
    }

    function testFlashLoanCallbackCanInvokeExactOutputBuy() public {
        uint256 amountOut = 600e18;
        uint256 maxAmountIn = 15e18;

        _supplyLoanLiquidity(200e18);
        deal(USDM, borrower, maxAmountIn);
        vm.prank(borrower);
        IERC20(USDM).forceApprove(address(generalAdapter1), maxAmountIn);

        Call[] memory callbackBundle = new Call[](2);
        callbackBundle[0] = _erc20Transfer(generalAdapter1, USDM, address(wcmAdapter), maxAmountIn);
        callbackBundle[1] = _wcmBuy(USDM, WITRY, amountOut, maxAmountIn, address(generalAdapter1));

        Call[] memory calls = new Call[](5);
        calls[0] = _erc20TransferFrom(USDM, address(generalAdapter1), maxAmountIn);
        calls[1] = _morphoFlashLoan(USDM, maxAmountIn, abi.encode(callbackBundle));
        calls[2] = _erc20Transfer(generalAdapter1, USDM, borrower, type(uint256).max);
        calls[3] = _erc20Transfer(generalAdapter1, WITRY, borrower, type(uint256).max);
        calls[4] = _erc20Transfer(wcmAdapter, USDM, borrower, type(uint256).max);

        uint256 borrowerWitryBefore = IERC20(WITRY).balanceOf(borrower);
        vm.prank(borrower);
        bundler3.multicall(calls);

        assertGe(IERC20(WITRY).balanceOf(borrower) - borrowerWitryBefore, amountOut, "borrower wiTRY");
        _assertAdaptersClean();
        assertEq(IERC20(USDM).allowance(address(wcmAdapter), WORLD_SWAP_ROUTER), 0, "wcm USDm allowance");
    }

    function _supplyLoanLiquidity(uint256 assets) internal {
        deal(USDM, lender, assets);
        vm.startPrank(lender);
        IERC20(USDM).forceApprove(MORPHO, assets);
        IMorpho(MORPHO).supply(marketParams, assets, 0, lender, hex"");
        vm.stopPrank();
    }

    function _supplyFlashLoanCollateralLiquidity(uint256 assets) internal {
        deal(WITRY, collateralSupplier, assets);
        vm.startPrank(collateralSupplier);
        IERC20(WITRY).forceApprove(MORPHO, assets);
        IMorpho(MORPHO).supplyCollateral(marketParams, assets, collateralSupplier, hex"");
        vm.stopPrank();
    }

    function _createBorrowerPosition(uint256 collateral, uint256 borrowAmount) internal {
        deal(WITRY, borrower, collateral);
        _authorizeBorrower();
        vm.startPrank(borrower);
        IERC20(WITRY).forceApprove(MORPHO, collateral);
        IMorpho(MORPHO).supplyCollateral(marketParams, collateral, borrower, hex"");
        IMorpho(MORPHO).borrow(marketParams, borrowAmount, 0, borrower, borrower);
        vm.stopPrank();
    }

    function _authorizeBorrower() internal {
        vm.prank(borrower);
        IMorpho(MORPHO).setAuthorization(address(generalAdapter1), true);
    }

    function _call(address to, bytes memory data) internal pure returns (Call memory) {
        return _call(to, data, bytes32(0));
    }

    function _call(address to, bytes memory data, bytes32 callbackHash) internal pure returns (Call memory) {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: callbackHash});
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

    function _erc20TransferFrom(address token, address to, uint256 amount) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.erc20TransferFrom, (token, to, amount)));
    }

    function _morphoFlashLoan(address token, uint256 amount, bytes memory data) internal view returns (Call memory) {
        return _call(
            address(generalAdapter1),
            abi.encodeCall(GeneralAdapter1.morphoFlashLoan, (token, amount, data)),
            keccak256(data)
        );
    }

    function _morphoSupplyCollateral(uint256 assets, address onBehalf) internal view returns (Call memory) {
        return _call(
            generalAdapter1,
            abi.encodeCall(GeneralAdapter1.morphoSupplyCollateral, (marketParams, assets, onBehalf, hex""))
        );
    }

    function _morphoBorrow(uint256 assets, address receiver) internal view returns (Call memory) {
        return
            _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.morphoBorrow, (marketParams, assets, 0, 0, receiver)));
    }

    function _morphoRepayAll(address onBehalf) internal view returns (Call memory) {
        return _call(
            generalAdapter1,
            abi.encodeCall(
                GeneralAdapter1.morphoRepay, (marketParams, 0, type(uint256).max, type(uint256).max, onBehalf, hex"")
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

    function _assertAdaptersClean() internal view {
        assertEq(IERC20(USDM).balanceOf(address(wcmAdapter)), 0, "wcm USDm");
        assertEq(IERC20(WITRY).balanceOf(address(wcmAdapter)), 0, "wcm wiTRY");
        assertEq(IERC20(USDM).balanceOf(address(generalAdapter1)), 0, "general USDm");
        assertEq(IERC20(WITRY).balanceOf(address(generalAdapter1)), 0, "general wiTRY");
        assertEq(IERC20(USDM).allowance(address(wcmAdapter), WORLD_SWAP_ROUTER), 0, "wcm USDm allowance");
        assertEq(IERC20(WITRY).allowance(address(wcmAdapter), WORLD_SWAP_ROUTER), 0, "wcm wiTRY allowance");
    }
}
