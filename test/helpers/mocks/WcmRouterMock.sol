// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IWcmSwapRouter} from "../../../src/interfaces/IWcmAdapter.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {Test} from "../../../lib/forge-std/src/Test.sol";

contract WcmRouterMock is Test, IWcmSwapRouter {
    uint256 public toGive = type(uint256).max;
    uint256 public toTake = type(uint256).max;

    function setToGive(uint256 amount) external {
        toGive = amount;
    }

    function setToTake(uint256 amount) external {
        toTake = amount;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        uint256 amountIn = toTake != type(uint256).max ? toTake : params.amountIn;
        amountOut = toGive != type(uint256).max ? toGive : params.amountIn;

        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), amountIn);
        deal(params.tokenOut, address(this), IERC20(params.tokenOut).balanceOf(address(this)) + amountOut);
        IERC20(params.tokenOut).transfer(msg.sender, amountOut);

        _reset();
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn) {
        amountIn = toTake != type(uint256).max ? toTake : params.amountOut;
        uint256 amountOut = toGive != type(uint256).max ? toGive : params.amountOut;

        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), amountIn);
        deal(params.tokenOut, address(this), IERC20(params.tokenOut).balanceOf(address(this)) + amountOut);
        IERC20(params.tokenOut).transfer(msg.sender, amountOut);

        _reset();
    }

    function _reset() internal {
        toGive = type(uint256).max;
        toTake = type(uint256).max;
    }
}
