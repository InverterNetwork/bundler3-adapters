// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IWcmExchange, IWcmPriceHelper, IWcmSpotOrderBook} from "../../../src/interfaces/IWcmAdapter.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {Test} from "../../../lib/forge-std/src/Test.sol";

contract WcmExchangeMock is Test, IWcmExchange, IWcmPriceHelper, IWcmSpotOrderBook {
    uint32 internal constant USDM_ID = 1;
    uint32 internal constant WITRY_ID = 9;
    uint256 internal constant USDM_TICK = 1e14;
    uint256 internal constant WITRY_TICK = 1e15;

    address public usdm;
    address public witry;
    uint64 public nextAccountId = 1;
    uint256 public toGive = type(uint256).max;
    uint256 public toTake = type(uint256).max;
    uint256 public bestBidOfferValue = uint256(2) | (uint256(2) << 128);
    bool public sequesterOnExecute;

    mapping(address => uint64) public userId;
    mapping(uint64 => mapping(uint32 => uint128)) public balances;
    mapping(uint64 => mapping(uint32 => uint128)) public sequestered;

    uint32 internal pendingTokenInId;
    uint32 internal pendingTokenOutId;
    uint64 internal pendingAmountIn;
    uint64 internal pendingAmountOut;

    function configure(address usdm_, address witry_) external {
        usdm = usdm_;
        witry = witry_;
    }

    function setToGive(uint256 amount) external {
        toGive = amount;
    }

    function setToTake(uint256 amount) external {
        toTake = amount;
    }

    function setBestBidOffer(uint256 value) external {
        bestBidOfferValue = value;
    }

    function setSequesterOnExecute(bool value) external {
        sequesterOnExecute = value;
    }

    function createAccount() external returns (uint64 accountId) {
        require(userId[msg.sender] == 0, "account exists");
        accountId = nextAccountId++;
        userId[msg.sender] = accountId;
    }

    function getUserId(address account) external view returns (uint64) {
        return userId[account];
    }

    function getDefaultErc20TokenConfig(address token) external view returns (uint256 config) {
        if (token == usdm) return _tokenConfig(USDM_ID, 4, token);
        if (token == witry) return _tokenConfig(WITRY_ID, 3, token);
    }

    function getSpotOrderBook(uint32 fromToken, uint32 toToken)
        external
        view
        returns (address orderBook, uint32 resolvedFromToken, uint32 resolvedToToken)
    {
        if (fromToken == WITRY_ID && toToken == USDM_ID) return (address(this), fromToken, toToken);
    }

    function getBalance(uint64 accountId, uint32 tokenId)
        external
        view
        returns (uint128 balance, uint128 sequesteredAmount)
    {
        return (balances[accountId][tokenId], sequestered[accountId][tokenId]);
    }

    function depositErc20(address token, uint256 amount) external {
        (uint32 tokenId,) = _token(token);
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        balances[userId[msg.sender]][tokenId] += uint128(amount);
    }

    function withdrawErc20(address token, uint256 amount) external {
        (uint32 tokenId,) = _token(token);
        balances[userId[msg.sender]][tokenId] -= uint128(amount);
        IERC20(token).transfer(msg.sender, amount);
    }

    function newSpotBuyOrder(address, uint256 orderData) external {
        _execute(orderData);
    }

    function newSpotSellOrder(address, uint256 orderData) external {
        _execute(orderData);
    }

    function estimatePrices(address exchange, uint256[] calldata batch) external returns (uint256[] memory results) {
        require(exchange == address(this) && batch.length == 2, "bad quote");
        uint8 priceType = uint8(batch[0] >> 160);
        bool isBuy = priceType == 2 || priceType == 4;
        bool exactIn = priceType == 1 || priceType == 4;
        uint64 requestedIn = uint64(batch[1] >> 128);
        uint64 requestedOut = uint64(batch[1] >> 64);

        pendingTokenInId = isBuy ? USDM_ID : WITRY_ID;
        pendingTokenOutId = isBuy ? WITRY_ID : USDM_ID;
        uint256 inputTick = isBuy ? USDM_TICK : WITRY_TICK;
        uint256 outputTick = isBuy ? WITRY_TICK : USDM_TICK;
        uint256 defaultRaw = exactIn ? uint256(requestedIn) * inputTick : uint256(requestedOut) * outputTick;
        uint256 rawInput = toTake == type(uint256).max ? defaultRaw : toTake;
        uint256 rawOutput = toGive == type(uint256).max ? defaultRaw : toGive;
        pendingAmountIn = uint64(rawInput / inputTick);
        pendingAmountOut = uint64(rawOutput / outputTick);

        results = new uint256[](1);
        results[0] = (uint256(1) << 192) | (uint256(pendingAmountIn) << 128) | (uint256(pendingAmountOut) << 64) | 1;
    }

    function clear() external {}

    function bestBidOffer() external view returns (uint256) {
        return bestBidOfferValue;
    }

    function _execute(uint256 orderData) internal {
        uint64 accountId = uint64((orderData >> 128) & ((uint256(1) << 44) - 1));
        uint256 inputTick = pendingTokenInId == USDM_ID ? USDM_TICK : WITRY_TICK;
        uint256 outputTick = pendingTokenOutId == USDM_ID ? USDM_TICK : WITRY_TICK;
        balances[accountId][pendingTokenInId] -= uint128(uint256(pendingAmountIn) * inputTick);
        balances[accountId][pendingTokenOutId] += uint128(uint256(pendingAmountOut) * outputTick);
        if (sequesterOnExecute) ++sequestered[accountId][pendingTokenInId];
        address tokenOut = pendingTokenOutId == USDM_ID ? usdm : witry;
        deal(
            tokenOut, address(this), IERC20(tokenOut).balanceOf(address(this)) + uint256(pendingAmountOut) * outputTick
        );
        toGive = type(uint256).max;
        toTake = type(uint256).max;
    }

    function _token(address token) internal view returns (uint32 tokenId, uint256 tick) {
        if (token == usdm) return (USDM_ID, USDM_TICK);
        require(token == witry, "unsupported token");
        return (WITRY_ID, WITRY_TICK);
    }

    function _tokenConfig(uint32 tokenId, uint8 positionDecimals, address token) internal pure returns (uint256) {
        return (uint256(tokenId) << 200) | (uint256(18) << 184) | (uint256(positionDecimals) << 168) | uint160(token);
    }
}
