pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./BankController.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router.sol";
import "./Bank.sol";
import "./FlashLoanReceiverBase.sol";
import "./FToken.sol";
import "./ILendingPool.sol";

contract FortubeFlashLiquidator is Ownable, FlashLoanReceiverBase {

    address public bankControllerAddress = 0xc78248D676DeBB4597e88071D3d889eCA70E5469;
    address public uniswapIntermediateAsset = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public uniswapRouter02Address = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F;
    address public uniswapFactoryAddress = 0xBCfCcbde45cE874adCB698cC183deBcF17952812;
    address public wBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public fBNB = 0xf330b39f74e7f71ab9604A5307690872b8125aC8;
    address public bnb = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

    using SafeERC20 for IERC20;

    constructor() FlashLoanReceiverBase(ILendingPoolAddressesProvider(0xCc0479a98cC66E85806D0Cd7970d6e07f77Fd633)) Ownable() public {

    }

    struct LiquidationData {
        address fTokenCollateral;
        address fTokenDebt;
        address user;
        uint256 borrowAmount;
    }

    // @notice Call this function to make a flash swap
    function liquidate(
        address _fTokenCollateral,
        address _fTokenDebt,
        address _user,
        uint256 _borrowAmount) external onlyOwner payable {

        BankController bankcontroller = BankController(bankControllerAddress);
        uint256 healthFactor = bankcontroller.getHealthFactor(_user);
        require(healthFactor < 1 ether, "user was healthy");
        bytes memory data = abi.encode(
            LiquidationData(
            {
            user : _user,
            fTokenCollateral : _fTokenCollateral,
            fTokenDebt : _fTokenDebt,
            borrowAmount : _borrowAmount
            }
            )
        );

        ILendingPool lendingPool = ILendingPool(
            addressesProvider.getLendingPool()
        );
        lendingPool.flashLoan(address(this), BNB_ADDRESS, _borrowAmount, data);
    }

    function executeOperation(
        address _reserve,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _params
    ) override external {
        require(
            _amount <= getBalanceInternal(address(this), _reserve),
            "Invalid balance, was the flashLoan successful?"
        );

        LiquidationData memory liquidationData = abi.decode(_params, (LiquidationData));
        if (liquidationData.fTokenDebt == fBNB) {
            //debt is bnb, we can just liquidate this
        } else {
            //first wrap the BNB
            IWETH(wBNB).deposit{value : _amount}();
            uint256 wbnbBalance = IERC20(wBNB).balanceOf(address(this));
            if(wbnbBalance > 0) {
                uniswap(wBNB, FToken(liquidationData.fTokenDebt).underlying(), wbnbBalance, 0);
            }
        }

        doLiquidation(liquidationData.fTokenDebt, _amount, liquidationData.user, liquidationData.fTokenCollateral);

        //we switch everything back to WBNB
        if (liquidationData.fTokenCollateral != fBNB) {
            uint256 collateralBalance = IERC20(FToken(liquidationData.fTokenCollateral).underlying()).balanceOf(address(this));
            if(collateralBalance > 0) {
                uniswap(FToken(liquidationData.fTokenCollateral).underlying(), wBNB, collateralBalance, 0);
            }
        }
        if (liquidationData.fTokenDebt != fBNB) {
            uint256 debtBalance = IERC20(FToken(liquidationData.fTokenDebt).underlying()).balanceOf(address(this));
            if(debtBalance > 0) {
                uniswap(FToken(liquidationData.fTokenDebt).underlying(), wBNB, debtBalance, 0);
            }
        }

        //withdraw everything from wbnb
        uint256 wbnbBalance = IERC20(wBNB).balanceOf(address(this));
        if(wbnbBalance > 0) {
            IWETH(wBNB).withdraw(wbnbBalance);
        }

        uint256 totalDebt = _amount.add(_fee);
        transferFundsBackToPoolInternal(_reserve, totalDebt);
    }

    function uniswap(address _fromToken, address _toToken, uint256 _fromAmount, uint256 _minimumToAmount) private {
        safeAllow(_fromToken, uniswapRouter02Address);
        IUniswapV2Router uniswapRouter = IUniswapV2Router(uniswapRouter02Address);

        if (directPairExists(_fromToken, _toToken)) {
            address[] memory path = new address[](2);
            path[0] = address(_fromToken);
            path[1] = address(_toToken);
            uniswapRouter.swapExactTokensForTokens(
                _fromAmount,
                _minimumToAmount,
                path,
                address(this),
                block.timestamp + 1
            );
        } else {
            address[] memory path = new address[](3);
            path[0] = address(_fromToken);
            path[1] = address(uniswapIntermediateAsset);
            path[2] = address(_toToken);
            uniswapRouter.swapExactTokensForTokens(
                _fromAmount,
                _minimumToAmount,
                path,
                address(this),
                block.timestamp + 1
            );
        }
    }

    function doLiquidation(address _fTokenDebt, uint256 _amount, address _userToLiquidate, address _fTokenCollateral) internal {
        BankController bankcontroller = BankController(bankControllerAddress);
        Bank bank = Bank(bankcontroller.bankEntryAddress());
        if (_fTokenDebt == fBNB) {
            address underlyingDebt = bnb;
            address underlyingCollateral = FToken(_fTokenCollateral).underlying();
            bank.liquidateBorrow{value: _amount}(_userToLiquidate, underlyingDebt, underlyingCollateral, _amount);
        } else {
            safeAllow(FToken(_fTokenDebt).underlying(), address(bank));

            address underlyingDebt = FToken(_fTokenDebt).underlying();
            address underlyingCollateral = FToken(_fTokenCollateral).underlying();

            bank.liquidateBorrow(_userToLiquidate, underlyingDebt, underlyingCollateral, _amount);
        }
    }

    function directPairExists(address fromToken, address toToken) view public returns (bool) {
        return IUniswapV2Factory(uniswapFactoryAddress).getPair(fromToken, toToken) != address(0);
    }

    function safeAllow(address asset, address allowee) private {
        IERC20 token = IERC20(asset);

        if (token.allowance(address(this), allowee) == 0) {
            token.safeApprove(allowee, uint256(- 1));
        }
    }
}
