// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IWcmAdapter, IWcmExchange, IWcmPriceHelper, IWcmSpotOrderBook} from "../interfaces/IWcmAdapter.sol";
import {CoreAdapter, ErrorsLib, IERC20, SafeERC20} from "./CoreAdapter.sol";

import {MarketParams, IMorpho} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

/// @custom:security-contact security@morpho.org
/// @notice Bundler3 adapter for direct World Markets exchange swaps.
contract WcmAdapter is CoreAdapter, IWcmAdapter {
    /* IMMUTABLES */

    IMorpho public immutable MORPHO;
    IWcmExchange public immutable EXCHANGE;
    IWcmPriceHelper public immutable PRICE_HELPER;
    IWcmSpotOrderBook public immutable ORDER_BOOK;
    uint256 public immutable CHAIN_ID;
    bytes32 public immutable EXCHANGE_CODE_HASH;
    bytes32 public immutable PRICE_HELPER_CODE_HASH;
    bytes32 public immutable ORDER_BOOK_CODE_HASH;
    address public immutable USDM;
    address public immutable WITRY;
    uint32 public immutable USDM_TOKEN_ID;
    uint32 public immutable WITRY_TOKEN_ID;
    uint64 public immutable ACCOUNT_ID;
    address public immutable MARKET_ORACLE;
    address public immutable MARKET_IRM;
    uint256 public immutable MARKET_LLTV;

    /* CONSTANTS */

    uint256 internal constant USDM_WORLD_TICK = 1e14;
    uint256 internal constant WITRY_WORLD_TICK = 1e15;

    uint256 internal constant TOKEN_ID_SHIFT = 200;
    uint256 internal constant ERC20_DECIMALS_SHIFT = 184;
    uint256 internal constant POSITION_DECIMALS_SHIFT = 168;
    uint256 internal constant ADDRESS_MASK = type(uint160).max;

    uint8 internal constant PRICE_TYPE_SELL_IN = 1;
    uint8 internal constant PRICE_TYPE_BUY_OUT = 2;
    uint8 internal constant PRICE_TYPE_SELL_OUT = 3;
    uint8 internal constant PRICE_TYPE_BUY_IN = 4;
    uint256 internal constant ORDER_TYPE_FILL_ALL_OR_REVERT = 2;
    uint256 internal constant MAX_ACCOUNT_ID = (1 << 44) - 1;

    struct Quote {
        uint64 orderQuantity;
        uint64 amountIn;
        uint64 amountOut;
        uint64 limitPrice;
    }

    constructor(
        address bundler3,
        address morpho,
        address exchange,
        address priceHelper,
        uint256 chainId,
        bytes32 exchangeCodeHash,
        bytes32 priceHelperCodeHash,
        bytes32 orderBookCodeHash,
        address usdm,
        address witry,
        address marketOracle,
        address marketIrm,
        uint256 marketLltv
    ) CoreAdapter(bundler3) {
        require(morpho != address(0), ErrorsLib.ZeroAddress());
        require(exchange != address(0), ErrorsLib.ZeroAddress());
        require(priceHelper != address(0), ErrorsLib.ZeroAddress());
        require(chainId != 0, ErrorsLib.ZeroAmount());
        require(exchangeCodeHash != bytes32(0), ErrorsLib.ZeroAmount());
        require(priceHelperCodeHash != bytes32(0), ErrorsLib.ZeroAmount());
        require(orderBookCodeHash != bytes32(0), ErrorsLib.ZeroAmount());
        require(usdm != address(0), ErrorsLib.ZeroAddress());
        require(witry != address(0), ErrorsLib.ZeroAddress());
        require(marketOracle != address(0), ErrorsLib.ZeroAddress());
        require(marketIrm != address(0), ErrorsLib.ZeroAddress());
        require(marketLltv != 0, ErrorsLib.ZeroAmount());
        require(usdm != witry, ErrorsLib.InvalidWcmPair());
        require(exchange.code.length != 0 && exchange.codehash == exchangeCodeHash, ErrorsLib.InvalidWcmExchange());
        require(
            priceHelper.code.length != 0 && priceHelper.codehash == priceHelperCodeHash,
            ErrorsLib.InvalidWcmPriceHelper()
        );

        IWcmExchange worldExchange = IWcmExchange(exchange);
        (uint32 usdmTokenId, uint8 usdmPositionDecimals) = _readTokenConfig(worldExchange, usdm);
        (uint32 witryTokenId, uint8 witryPositionDecimals) = _readTokenConfig(worldExchange, witry);
        require(usdmPositionDecimals == 4 && witryPositionDecimals == 3, ErrorsLib.InvalidWcmPair());

        (address orderBook, uint32 fromTokenId, uint32 toTokenId) =
            worldExchange.getSpotOrderBook(witryTokenId, usdmTokenId);
        require(
            orderBook != address(0) && fromTokenId == witryTokenId && toTokenId == usdmTokenId,
            ErrorsLib.InvalidWcmOrderBook()
        );
        require(orderBook.code.length != 0 && orderBook.codehash == orderBookCodeHash, ErrorsLib.InvalidWcmOrderBook());

        uint64 accountId = worldExchange.createAccount();
        require(accountId != 0 && accountId <= MAX_ACCOUNT_ID, ErrorsLib.InvalidWcmAccount());
        require(worldExchange.getUserId(address(this)) == accountId, ErrorsLib.InvalidWcmAccount());

        MORPHO = IMorpho(morpho);
        EXCHANGE = worldExchange;
        PRICE_HELPER = IWcmPriceHelper(priceHelper);
        ORDER_BOOK = IWcmSpotOrderBook(orderBook);
        CHAIN_ID = chainId;
        EXCHANGE_CODE_HASH = exchangeCodeHash;
        PRICE_HELPER_CODE_HASH = priceHelperCodeHash;
        ORDER_BOOK_CODE_HASH = orderBookCodeHash;
        USDM = usdm;
        WITRY = witry;
        USDM_TOKEN_ID = usdmTokenId;
        WITRY_TOKEN_ID = witryTokenId;
        ACCOUNT_ID = accountId;
        MARKET_ORACLE = marketOracle;
        MARKET_IRM = marketIrm;
        MARKET_LLTV = marketLltv;
    }

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

        uint256 amountOut = _roundUpToWorldTick(marketParams.loanToken, debtAmount);
        _swapExactOut(tokenIn, marketParams.loanToken, amountOut, maxAmountIn, receiver, onBehalf, deadline);
    }

    function _swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        uint256 deadline
    ) internal returns (uint256 spent, uint256 received) {
        _validateSwap(tokenIn, tokenOut, receiver, deadline);

        uint256 swapAmountIn = _roundDownToWorldTick(tokenIn, amountIn);
        require(swapAmountIn != 0, ErrorsLib.ZeroAmount());
        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        require(tokenInBefore >= amountIn, ErrorsLib.InsufficientBalance());

        uint256 dust = amountIn - swapAmountIn;
        if (dust != 0) {
            SafeERC20.safeTransfer(IERC20(tokenIn), initiator(), dust);
            tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        }
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        uint64 amountInWorld = _toWorldAmount(tokenIn, swapAmountIn, false);
        uint64 minAmountOutWorld = _toWorldAmount(tokenOut, minAmountOut, true);
        Quote memory quote = _quote(tokenIn, true, amountInWorld, minAmountOutWorld);
        require(quote.amountIn == amountInWorld, ErrorsLib.SellAmountTooLow());
        require(quote.amountOut >= minAmountOutWorld, ErrorsLib.BuyAmountTooLow());

        _settle(tokenIn, tokenOut, quote);

        spent = tokenInBefore - IERC20(tokenIn).balanceOf(address(this));
        received = IERC20(tokenOut).balanceOf(address(this)) - tokenOutBefore;
        require(spent <= swapAmountIn, ErrorsLib.SellAmountTooHigh());
        require(spent == swapAmountIn, ErrorsLib.SellAmountTooLow());
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
        require(tokenInBefore >= maxAmountIn, ErrorsLib.InsufficientBalance());
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        uint256 roundedAmountOut = _roundUpToWorldTick(tokenOut, amountOut);
        uint64 amountOutWorld = _toWorldAmount(tokenOut, roundedAmountOut, false);
        uint64 maxAmountInWorld = _toWorldAmount(tokenIn, maxAmountIn, false);
        require(maxAmountInWorld != 0, ErrorsLib.ZeroAmount());

        Quote memory quote = _quote(tokenIn, false, maxAmountInWorld, amountOutWorld);
        require(quote.amountIn <= maxAmountInWorld, ErrorsLib.SellAmountTooHigh());
        require(quote.amountOut >= amountOutWorld, ErrorsLib.BuyAmountTooLow());

        _settle(tokenIn, tokenOut, quote);

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

    function _quote(address tokenIn, bool exactIn, uint64 amountIn, uint64 amountOut)
        internal
        returns (Quote memory quote)
    {
        bool isBuy = tokenIn == USDM;
        uint8 priceType = exactIn
            ? (isBuy ? PRICE_TYPE_BUY_IN : PRICE_TYPE_SELL_IN)
            : (isBuy ? PRICE_TYPE_BUY_OUT : PRICE_TYPE_SELL_OUT);

        uint256 bestBidOffer = ORDER_BOOK.bestBidOffer();
        uint64 startPrice;
        if (isBuy) {
            uint64 bestSellPrice = uint64(bestBidOffer);
            require(bestSellPrice != 0 && bestSellPrice != type(uint64).max, ErrorsLib.InvalidWcmQuote());
            startPrice = bestSellPrice - 1;
        } else {
            uint64 bestBuyPrice = uint64(bestBidOffer >> 128);
            require(bestBuyPrice != 0 && bestBuyPrice != type(uint64).max, ErrorsLib.InvalidWcmQuote());
            startPrice = bestBuyPrice + 1;
        }

        uint64 requiredAmountOut = amountOut;
        uint64 requestedAmountOut = amountOut;
        uint256[] memory batch = new uint256[](2);
        batch[0] = (uint256(priceType) << 160) | uint160(address(ORDER_BOOK));
        PRICE_HELPER.clear();

        for (uint256 i; i < 4; ++i) {
            batch[1] = (uint256(amountIn) << 128) | (uint256(requestedAmountOut) << 64) | startPrice;
            uint256[] memory results = PRICE_HELPER.estimatePrices(address(EXCHANGE), batch);
            PRICE_HELPER.clear();
            require(results.length == 1, ErrorsLib.InvalidWcmQuote());

            uint256 result = results[0];
            quote = Quote({
                orderQuantity: uint64(result >> 192),
                amountIn: uint64(result >> 128),
                amountOut: uint64(result >> 64),
                limitPrice: uint64(result)
            });
            require(
                quote.orderQuantity != 0 && quote.amountIn != 0 && quote.amountOut != 0 && quote.limitPrice != 0,
                ErrorsLib.InvalidWcmQuote()
            );
            if (exactIn || quote.amountOut >= requiredAmountOut) return quote;

            uint256 nextRequest = uint256(requestedAmountOut) + requiredAmountOut - quote.amountOut;
            require(nextRequest <= type(uint64).max, ErrorsLib.InvalidWcmQuote());
            requestedAmountOut = uint64(nextRequest);
        }
        revert ErrorsLib.InvalidWcmQuote();
    }

    function _settle(address tokenIn, address tokenOut, Quote memory quote) internal {
        (uint32 tokenInId, uint256 tokenInTick) = _tokenConfig(tokenIn);
        (uint32 tokenOutId,) = _tokenConfig(tokenOut);
        (uint128 internalInputBefore, uint128 sequesteredInputBefore) = EXCHANGE.getBalance(ACCOUNT_ID, tokenInId);
        (uint128 internalOutputBefore, uint128 sequesteredOutputBefore) = EXCHANGE.getBalance(ACCOUNT_ID, tokenOutId);

        uint256 quotedInput = uint256(quote.amountIn) * tokenInTick;
        SafeERC20.forceApprove(IERC20(tokenIn), address(EXCHANGE), quotedInput);
        EXCHANGE.depositErc20(tokenIn, quotedInput);
        SafeERC20.forceApprove(IERC20(tokenIn), address(EXCHANGE), 0);

        uint256 orderData = (ORDER_TYPE_FILL_ALL_OR_REVERT << 172) | (uint256(ACCOUNT_ID) << 128)
            | (uint256(quote.orderQuantity) << 64) | quote.limitPrice;
        if (tokenIn == USDM) EXCHANGE.newSpotBuyOrder(address(ORDER_BOOK), orderData);
        else EXCHANGE.newSpotSellOrder(address(ORDER_BOOK), orderData);

        (uint128 internalInputAfter, uint128 sequesteredInputAfter) = EXCHANGE.getBalance(ACCOUNT_ID, tokenInId);
        (uint128 internalOutputAfter, uint128 sequesteredOutputAfter) = EXCHANGE.getBalance(ACCOUNT_ID, tokenOutId);
        uint256 availableInput = uint256(internalInputBefore) + quotedInput;
        require(
            sequesteredInputAfter == sequesteredInputBefore && sequesteredOutputAfter == sequesteredOutputBefore,
            ErrorsLib.InvalidWcmQuote()
        );
        require(internalInputAfter >= internalInputBefore, ErrorsLib.SellAmountTooHigh());
        require(internalInputAfter <= availableInput, ErrorsLib.SellAmountTooHigh());
        require(internalOutputAfter >= internalOutputBefore, ErrorsLib.BuyAmountTooLow());

        uint256 unspentInput = uint256(internalInputAfter) - internalInputBefore;
        uint256 receivedOutput = uint256(internalOutputAfter) - internalOutputBefore;
        if (unspentInput != 0) EXCHANGE.withdrawErc20(tokenIn, unspentInput);
        if (receivedOutput != 0) EXCHANGE.withdrawErc20(tokenOut, receivedOutput);
    }

    function _validateSwap(address tokenIn, address tokenOut, address receiver, uint256 deadline) internal view {
        require(block.chainid == CHAIN_ID, ErrorsLib.InvalidChainId());
        require(address(EXCHANGE).codehash == EXCHANGE_CODE_HASH, ErrorsLib.InvalidWcmExchange());
        require(address(PRICE_HELPER).codehash == PRICE_HELPER_CODE_HASH, ErrorsLib.InvalidWcmPriceHelper());
        require(address(ORDER_BOOK).codehash == ORDER_BOOK_CODE_HASH, ErrorsLib.InvalidWcmOrderBook());
        require(EXCHANGE.getUserId(address(this)) == ACCOUNT_ID, ErrorsLib.InvalidWcmAccount());
        (uint32 usdmTokenId, uint8 usdmPositionDecimals) = _readTokenConfig(EXCHANGE, USDM);
        (uint32 witryTokenId, uint8 witryPositionDecimals) = _readTokenConfig(EXCHANGE, WITRY);
        require(
            usdmTokenId == USDM_TOKEN_ID && usdmPositionDecimals == 4 && witryTokenId == WITRY_TOKEN_ID
                && witryPositionDecimals == 3,
            ErrorsLib.InvalidWcmPair()
        );
        (address orderBook, uint32 fromTokenId, uint32 toTokenId) =
            EXCHANGE.getSpotOrderBook(WITRY_TOKEN_ID, USDM_TOKEN_ID);
        require(
            orderBook == address(ORDER_BOOK) && fromTokenId == WITRY_TOKEN_ID && toTokenId == USDM_TOKEN_ID,
            ErrorsLib.InvalidWcmOrderBook()
        );
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

    function _readTokenConfig(IWcmExchange exchange, address token)
        internal
        view
        returns (uint32 tokenId, uint8 positionDecimals)
    {
        uint256 config = exchange.getDefaultErc20TokenConfig(token);
        require(address(uint160(config & ADDRESS_MASK)) == token, ErrorsLib.InvalidWcmPair());
        require(uint8(config >> ERC20_DECIMALS_SHIFT) == 18, ErrorsLib.InvalidWcmPair());
        tokenId = uint32(config >> TOKEN_ID_SHIFT);
        positionDecimals = uint8(config >> POSITION_DECIMALS_SHIFT);
        require(tokenId != 0, ErrorsLib.InvalidWcmPair());
    }

    function _tokenConfig(address token) internal view returns (uint32 tokenId, uint256 tick) {
        if (token == USDM) return (USDM_TOKEN_ID, USDM_WORLD_TICK);
        if (token == WITRY) return (WITRY_TOKEN_ID, WITRY_WORLD_TICK);
        revert ErrorsLib.InvalidWcmPair();
    }

    function _toWorldAmount(address token, uint256 amount, bool roundUp) internal view returns (uint64 worldAmount) {
        (, uint256 tick) = _tokenConfig(token);
        uint256 value = amount / tick;
        if (roundUp && amount % tick != 0) ++value;
        require(value <= type(uint64).max, ErrorsLib.InvalidWcmQuote());
        worldAmount = uint64(value);
    }

    function _roundUpToWorldTick(address token, uint256 amount) internal view returns (uint256) {
        (, uint256 tick) = _tokenConfig(token);
        uint256 ticks = amount / tick;
        if (amount % tick != 0) ++ticks;
        return ticks * tick;
    }

    function _roundDownToWorldTick(address token, uint256 amount) internal view returns (uint256) {
        (, uint256 tick) = _tokenConfig(token);
        return amount / tick * tick;
    }
}
