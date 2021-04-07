pragma solidity ^0.6.6;

interface Bank {
    function liquidateBorrow(
        address borrower,
        address underlyingBorrow,
        address underlyingCollateral,
        uint256 repayAmount
    ) payable external;
}
