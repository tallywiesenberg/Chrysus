pragma solidity ^0.8.0;

interface ISwap {
    function addLiquidity(address _collateralType, uint256 _amount)
        external
        payable;

    function swapExactOutput(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 deadline,
        uint256 amountOut,
        uint256 amountInMaximum
    ) external returns (uint256);
}
