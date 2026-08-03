// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @notice World Markets exchange interface used by the WCM adapter.
interface IWcmExchange {
    function createAccount() external returns (uint64 accountId);
    function getUserId(address account) external view returns (uint64 accountId);
    function getDefaultErc20TokenConfig(address erc20) external view returns (uint256 config);
    function getSpotOrderBook(uint32 fromToken, uint32 toToken)
        external
        view
        returns (address orderBook, uint32 resolvedFromToken, uint32 resolvedToToken);
    function getBalance(uint64 accountId, uint32 tokenId) external view returns (uint128 balance, uint128 sequestered);
    function depositErc20(address erc20, uint256 amount) external;
    function withdrawErc20(address erc20, uint256 amount) external;
    function newSpotBuyOrder(address orderBook, uint256 orderData) external;
    function newSpotSellOrder(address orderBook, uint256 orderData) external;
}

/// @notice World Markets price helper used to quote fee- and depth-aware market orders.
/// @dev The deployed helper is intentionally called non-statically, matching the World router, because it uses
/// transaction-scoped scratch state while traversing an order book.
interface IWcmPriceHelper {
    function estimatePrices(address exchange, uint256[] calldata batch) external returns (uint256[] memory results);
    function clear() external;
}

/// @notice World Markets spot order book reads used to seed price-helper traversal.
interface IWcmSpotOrderBook {
    function bestBidOffer() external view returns (uint256);
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
