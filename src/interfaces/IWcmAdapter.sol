// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @notice World Markets / WCM SwapRouter interface used by the WCM adapter.
interface IWcmSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/// @custom:security-contact security@morpho.org
/// @notice Interface of the WCM adapter.
interface IWcmAdapter {
    function sell(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bool sellEntireBalance,
        address receiver,
        uint256 deadline
    ) external;

    function buy(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        uint256 deadline
    ) external;

    function buyMorphoDebt(
        address tokenIn,
        MarketParams calldata marketParams,
        uint256 maxAmountIn,
        address onBehalf,
        address receiver,
        uint256 deadline
    ) external;
}
