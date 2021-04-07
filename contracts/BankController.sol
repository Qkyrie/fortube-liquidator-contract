pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

abstract contract BankController {
    address public bankEntryAddress;

    function getHealthFactor(address account) public virtual view returns (
        uint256 healthFactor
    );
}