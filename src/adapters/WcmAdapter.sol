// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IWcmAdapter, IWcmSwapRouter} from "../interfaces/IWcmAdapter.sol";
import {CoreAdapter, ErrorsLib, IERC20, SafeERC20} from "./CoreAdapter.sol";

import {MarketParams, IMorpho} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

/// @custom:security-contact security@morpho.org
/// @notice Bundler3 adapter for World Markets / WCM SwapRouter swaps.
contract WcmAdapter is CoreAdapter, IWcmAdapter {
    /* IMMUTABLES */

    /// @notice The address of the Morpho contract.
    IMorpho public immutable MORPHO;

    /// @notice The World Markets / WCM SwapRouter.
    IWcmSwapRouter public immutable ROUTER;

    /// @notice The chain id supported by this adapter deployment.
    uint256 public immutable CHAIN_ID;

    /// @notice The expected runtime code hash of the World Markets / WCM SwapRouter.
    bytes32 public immutable ROUTER_CODE_HASH;

    /// @notice The USDm token supported by this adapter deployment.
    address public immutable USDM;

    /// @notice The wiTRY token supported by this adapter deployment.
    address public immutable WITRY;

    /// @notice The oracle of the Morpho market supported by `buyMorphoDebt`.
    address public immutable MARKET_ORACLE;

    /// @notice The IRM of the Morpho market supported by `buyMorphoDebt`.
    address public immutable MARKET_IRM;

    /// @notice The LLTV of the Morpho market supported by `buyMorphoDebt`.
    uint256 public immutable MARKET_LLTV;

    /* CONSTANTS */

    /// @dev USDm has 4 World position decimals and 18 ERC-20 decimals.
    uint256 internal constant USDM_WORLD_TICK = 1e14;

    /* CONSTRUCTOR */

    /// @param bundler3 The address of the Bundler3 contract.
    /// @param morpho The address of the Morpho protocol.
    /// @param router The address of the World Markets / WCM SwapRouter.
    /// @param chainId The chain id supported by this adapter deployment.
    /// @param routerCodeHash The expected runtime code hash of the World Markets / WCM SwapRouter.
    /// @param usdm The USDm token supported by this adapter deployment.
    /// @param witry The wiTRY token supported by this adapter deployment.
    /// @param marketOracle The oracle of the supported Morpho market.
    /// @param marketIrm The IRM of the supported Morpho market.
    /// @param marketLltv The LLTV of the supported Morpho market.
    constructor(
        address bundler3,
        address morpho,
        address router,
        uint256 chainId,
        bytes32 routerCodeHash,
        address usdm,
        address witry,
        address marketOracle,
        address marketIrm,
        uint256 marketLltv
    ) CoreAdapter(bundler3) {
        require(morpho != address(0), ErrorsLib.ZeroAddress());
        require(router != address(0), ErrorsLib.ZeroAddress());
        require(chainId != 0, ErrorsLib.ZeroAmount());
        require(routerCodeHash != bytes32(0), ErrorsLib.ZeroAmount());
        require(usdm != address(0), ErrorsLib.ZeroAddress());
        require(witry != address(0), ErrorsLib.ZeroAddress());
        require(marketOracle != address(0), ErrorsLib.ZeroAddress());
        require(marketIrm != address(0), ErrorsLib.ZeroAddress());
        require(marketLltv != 0, ErrorsLib.ZeroAmount());
        require(usdm != witry, ErrorsLib.InvalidWcmPair());

        MORPHO = IMorpho(morpho);
        ROUTER = IWcmSwapRouter(router);
        CHAIN_ID = chainId;
        ROUTER_CODE_HASH = routerCodeHash;
        USDM = usdm;
        WITRY = witry;
        MARKET_ORACLE = marketOracle;
        MARKET_IRM = marketIrm;
        MARKET_LLTV = marketLltv;
    }

    /* SWAP ACTIONS */

    /// @notice Sells an exact input amount through WCM.
    /// @dev Tokens must have been sent to the adapter before this call.
    /// @param tokenIn Token to sell.
    /// @param tokenOut Token to buy.
    /// @param amountIn Amount of `tokenIn` to sell. Ignored when `sellEntireBalance` is true.
    /// @param minAmountOut Minimum acceptable bought amount.
    /// @param sellEntireBalance If true, sells the adapter's full `tokenIn` balance.
    /// @param receiver Address receiving the bought tokens.
    /// @param deadline World router deadline.
    function sell(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bool sellEntireBalance,
        address receiver,
        uint256 deadline
    ) external onlyBundler3 {
        if (sellEntireBalance) amountIn = IERC20(tokenIn).balanceOf(address(this));

        require(amountIn != 0, ErrorsLib.ZeroAmount());
        require(minAmountOut != 0, ErrorsLib.ZeroAmount());

        _swapExactIn(tokenIn, tokenOut, amountIn, minAmountOut, receiver, deadline);
    }

    /// @notice Buys an exact output amount through WCM.
    /// @dev Tokens must have been sent to the adapter before this call. `receiver` is the swap beneficiary: it
    /// receives the bought tokens and up to the unspent `maxAmountIn` source-token remainder.
    /// @param tokenIn Token to sell.
    /// @param tokenOut Token to buy.
    /// @param amountOut Exact output amount to buy.
    /// @param maxAmountIn Maximum acceptable input amount.
    /// @param receiver Address receiving the bought tokens and bounded unspent `tokenIn` refund.
    /// @param deadline World router deadline.
    function buy(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        uint256 deadline
    ) external onlyBundler3 {
        require(amountOut != 0, ErrorsLib.ZeroAmount());
        require(maxAmountIn != 0, ErrorsLib.ZeroAmount());

        _swapExactOut(tokenIn, tokenOut, amountOut, maxAmountIn, receiver, receiver, deadline);
    }

    /// @notice Buys an amount corresponding to a user's Morpho debt.
    /// @dev The bought loan token is forwarded to `receiver`, usually `GeneralAdapter1`. Unlike generic `buy`,
    /// unspent `tokenIn` is refunded to `onBehalf` because `receiver` may be an intermediate adapter for repayment.
    /// `onBehalf` must be the Bundler3 initiator, and `marketParams` must match the market pinned at deployment.
    /// @param tokenIn Token to sell.
    /// @param marketParams Market parameters of the market with Morpho debt.
    /// @param maxAmountIn Maximum acceptable input amount.
    /// @param onBehalf Account whose live Morpho debt is bought.
    /// @param receiver Address receiving the bought loan tokens.
    /// @param deadline World router deadline.
    function buyMorphoDebt(
        address tokenIn,
        MarketParams calldata marketParams,
        uint256 maxAmountIn,
        address onBehalf,
        address receiver,
        uint256 deadline
    ) external onlyBundler3 {
        require(maxAmountIn != 0, ErrorsLib.ZeroAmount());
        require(onBehalf != address(0), ErrorsLib.ZeroAddress());
        require(onBehalf == initiator(), ErrorsLib.UnexpectedOwner());
        _validateMarket(marketParams);

        uint256 debtAmount = MorphoBalancesLib.expectedBorrowAssets(MORPHO, marketParams, onBehalf);
        require(debtAmount != 0, ErrorsLib.ZeroAmount());

        uint256 amountOut = _roundUpToUsdmWorldTick(debtAmount);
        _swapExactOut(tokenIn, marketParams.loanToken, amountOut, maxAmountIn, receiver, onBehalf, deadline);
    }

    /* INTERNAL FUNCTIONS */

    function _swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        uint256 deadline
    ) internal returns (uint256 spent, uint256 received) {
        _validateSwap(tokenIn, tokenOut, receiver, deadline);

        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        SafeERC20.forceApprove(IERC20(tokenIn), address(ROUTER), amountIn);

        ROUTER.exactInputSingle(
            IWcmSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: 0,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );

        SafeERC20.forceApprove(IERC20(tokenIn), address(ROUTER), 0);

        spent = tokenInBefore - IERC20(tokenIn).balanceOf(address(this));
        received = IERC20(tokenOut).balanceOf(address(this)) - tokenOutBefore;

        require(spent <= amountIn, ErrorsLib.SellAmountTooHigh());
        require(spent == amountIn, ErrorsLib.SellAmountTooLow());
        require(received >= minAmountOut, ErrorsLib.BuyAmountTooLow());

        SafeERC20.safeTransfer(IERC20(tokenOut), receiver, received);
    }

    function _swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        address refundReceiver,
        uint256 deadline
    ) internal returns (uint256 spent, uint256 received) {
        _validateSwap(tokenIn, tokenOut, receiver, deadline);
        require(refundReceiver != address(0), ErrorsLib.ZeroAddress());
        require(refundReceiver != address(this), ErrorsLib.AdapterAddress());

        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        SafeERC20.forceApprove(IERC20(tokenIn), address(ROUTER), maxAmountIn);

        ROUTER.exactOutputSingle(
            IWcmSwapRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: 0,
                recipient: address(this),
                deadline: deadline,
                amountOut: amountOut,
                amountInMaximum: maxAmountIn,
                sqrtPriceLimitX96: 0
            })
        );

        SafeERC20.forceApprove(IERC20(tokenIn), address(ROUTER), 0);

        uint256 tokenInAfter = IERC20(tokenIn).balanceOf(address(this));
        spent = tokenInBefore - tokenInAfter;
        received = IERC20(tokenOut).balanceOf(address(this)) - tokenOutBefore;

        require(spent <= maxAmountIn, ErrorsLib.SellAmountTooHigh());
        require(received >= amountOut, ErrorsLib.BuyAmountTooLow());

        SafeERC20.safeTransfer(IERC20(tokenOut), receiver, received);

        uint256 unspentAllowance = maxAmountIn - spent;
        if (unspentAllowance != 0) {
            uint256 refund = tokenInAfter < unspentAllowance ? tokenInAfter : unspentAllowance;
            if (refund != 0) SafeERC20.safeTransfer(IERC20(tokenIn), refundReceiver, refund);
        }
    }

    function _validateSwap(address tokenIn, address tokenOut, address receiver, uint256 deadline) internal view {
        require(block.chainid == CHAIN_ID, ErrorsLib.InvalidChainId());
        require(address(ROUTER).codehash == ROUTER_CODE_HASH, ErrorsLib.InvalidWcmRouter());
        require(
            (tokenIn == USDM && tokenOut == WITRY) || (tokenIn == WITRY && tokenOut == USDM), ErrorsLib.InvalidWcmPair()
        );
        require(receiver != address(0), ErrorsLib.ZeroAddress());
        require(receiver != address(this), ErrorsLib.AdapterAddress());
        require(deadline >= block.timestamp, ErrorsLib.DeadlineExpired());
    }

    function _validateMarket(MarketParams calldata marketParams) internal view {
        require(marketParams.loanToken == USDM && marketParams.collateralToken == WITRY, ErrorsLib.InvalidWcmPair());
        require(
            marketParams.oracle == MARKET_ORACLE && marketParams.irm == MARKET_IRM && marketParams.lltv == MARKET_LLTV,
            ErrorsLib.InvalidMorphoMarket()
        );
    }

    function _roundUpToUsdmWorldTick(uint256 amount) internal pure returns (uint256) {
        uint256 ticks = amount / USDM_WORLD_TICK;
        if (amount % USDM_WORLD_TICK != 0) ++ticks;
        return ticks * USDM_WORLD_TICK;
    }
}
