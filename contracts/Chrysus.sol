//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "contracts/Math.sol";
import "contracts/interfaces/ISwap.sol";
import "contracts/interfaces/IStabilityModule.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "contracts/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract Chrysus is DSMath, ERC20 {
    uint256 public liquidationRatio;
    uint256 public collateralizationRatio;
    uint256 public ethBalance;
    uint256 public ethFees;

    address[] public approvedTokens;

    AggregatorV3Interface oracleCHC;
    AggregatorV3Interface oracleXAU;

    ISwapRouter public immutable swapRouter;
    ISwap public swapSolution;
    IStabilityModule public stabilityModule;

    address public governance;
    address public treasury;
    address public auction;

    struct Collateral {
        bool approved;
        uint256 balance;
        uint256 fees;
        uint256 collateralRequirement;
        AggregatorV3Interface oracle;
    }

    struct Deposit {
        uint256 deposited;
        uint256 minted;
    }

    mapping(address => mapping(address => Deposit)) public userDeposits; //user -> token address -> Deposit struct

    mapping(address => Collateral) public approvedCollateral;

    constructor(
        address _daiAddress,
        address _oracleDAI,
        address _oracleETH,
        address _oracleCHC,
        address _oracleXAU,
        address _governance,
        address _treasury,
        address _auction,
        ISwapRouter _swapRouter,
        address _swapSolution,
        address _stabilityModule
    ) ERC20("Chrysus", "CHC") {
        liquidationRatio = 110e6;

        //add Dai as approved collateral
        approvedCollateral[_daiAddress].approved = true;

        //represent eth deposits as address 0 (a placeholder)
        approvedCollateral[address(0)].approved = true;

        approvedTokens.push(_daiAddress);
        approvedTokens.push(address(0));

        //connect to oracles
        approvedCollateral[_daiAddress].oracle = AggregatorV3Interface(
            _oracleDAI
        );
        approvedCollateral[address(0)].oracle = AggregatorV3Interface(
            _oracleETH
        );

        approvedCollateral[_daiAddress].collateralRequirement = 267;
        approvedCollateral[address(0)].collateralRequirement = 120;

        oracleCHC = AggregatorV3Interface(_oracleCHC);
        oracleXAU = AggregatorV3Interface(_oracleXAU);

        governance = _governance;
        treasury = _treasury;
        auction = _auction;

        swapRouter = _swapRouter;

        swapSolution = ISwap(_swapSolution);
        stabilityModule = IStabilityModule(_stabilityModule);
    }


    function addCollateralType(
        address _collateralType,
        uint256 _collateralRequirement,
        address _oracleAddress
    ) external {
        require(
            msg.sender == governance,
            "can only be called by CGT governance"
        );
        require(
            approvedCollateral[_collateralType].approved == false,
            "this collateral type already approved"
        );

        approvedTokens.push(_collateralType);
        approvedCollateral[_collateralType].approved = true;
        approvedCollateral[_collateralType]
            .collateralRequirement = _collateralRequirement;
        approvedCollateral[_collateralType].oracle = AggregatorV3Interface(
            _oracleAddress
        );
    }

    function collateralRatio() public view returns (uint256) {
        //get CHC price using oracle
        (, int256 priceCHC, , , ) = oracleCHC.latestRoundData();

        //multiply CHC price * CHC total supply
        uint256 valueCHC = uint256(priceCHC) * totalSupply();

        address collateralType;

        int256 collateralPrice;
        //declare collateral sum
        uint256 totalcollateralValue;
        //declare usd price
        uint256 singleCollateralValue;

        //for each collateral type...
        for (uint256 i; i < approvedTokens.length; i++) {
            collateralType = approvedTokens[i];
            //read oracle price
            (, collateralPrice, , , ) = approvedCollateral[collateralType]
                .oracle
                .latestRoundData();

            //multiply collateral amount in contract * oracle price to get USD price
            singleCollateralValue =
                approvedCollateral[collateralType].balance *
                uint256(collateralPrice);
            //add to sum
            totalcollateralValue += singleCollateralValue;
        }

        if (valueCHC == 0) {
            return 110e6;
        }

        return wdiv(totalcollateralValue, valueCHC);
    }

    function depositCollateral(address _collateralType, uint256 _amount)
        public
        payable
    {
        //10% of initial collateral collected as fee
        uint256 ethFee = div(msg.value, 10);
        uint256 tokenFee = div(_amount, 10);

        //increase fee balance
        approvedCollateral[address(0)].fees += ethFee;

        if (_collateralType != address(0)) {
            approvedCollateral[_collateralType].fees += tokenFee;
        }
        // //catch ether deposits
        // userTokenDeposits[msg.sender][address(0)].amount += msg.value - ethFee;

        //catch token deposits
        userDeposits[msg.sender][_collateralType].deposited +=
            _amount -
            tokenFee;

        //increase balance in approvedColateral mapping
        approvedCollateral[_collateralType].balance += _amount - tokenFee;

        //read CHC/USD oracle
        (, int256 priceCHC, , , ) = oracleCHC.latestRoundData();

        //read XAU/USD oracle
        (, int256 priceXAU, , , ) = oracleXAU.latestRoundData();

        //create CHC/XAU ratio
        uint256 ratio = div(uint256(priceCHC), uint256(priceXAU));

        //read collateral price to calculate amount of CHC to mint
        (, int256 priceCollateral, , , ) = approvedCollateral[_collateralType]
            .oracle
            .latestRoundData();
        uint256 amountToMint = wdiv(
            (_amount - tokenFee) * uint256(priceCollateral),
            uint256(priceCHC)
        );

        //divide amount minted by CHC/XAU ratio
        amountToMint = div(
            amountToMint * 10000,
            ratio * approvedCollateral[_collateralType].collateralRequirement
        );

        //update collateralization ratio
        collateralizationRatio = collateralRatio();

        //approve and transfer from token (if address is not address 0)
        if (_collateralType != address(0)) {
            IERC20(_collateralType).transferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }
        //mint new tokens (mint _amount * CHC/XAU ratio)
        _mint(msg.sender, amountToMint);

        userDeposits[msg.sender][_collateralType].minted += amountToMint;
    }

    function liquidate(address _collateralType) external {
        //require collateralizaiton ratio is under liquidation ratio

        collateralizationRatio = collateralRatio();
        
        require(
            collateralizationRatio < liquidationRatio,
            "cannot liquidate position"
        );

        (, int256 priceCollateral, , , ) = approvedCollateral[_collateralType]
            .oracle
            .latestRoundData();
        (, int256 priceXAU, , , ) = oracleXAU.latestRoundData();

        uint256 amountOut = (userDeposits[msg.sender][_collateralType].minted *
            uint256(priceCollateral) *
            100) /
            uint256(priceXAU) /
            10000;
        uint256 amountInMaximum = userDeposits[msg.sender][_collateralType]
            .minted;

        //sell collateral on swap solution at or above price of XAU
        uint256 amountIn = swapSolution.swapExactOutput(
            address(this),
            _collateralType,
            3000,
            msg.sender,
            block.timestamp,
            amountOut,
            amountInMaximum
        );

        //sell collateral on uniswap at or above price of XAU

        TransferHelper.safeApprove(
            address(this),
            address(swapRouter),
            amountInMaximum
        );

        amountOut =
            (userDeposits[msg.sender][_collateralType].minted *
                uint256(priceCollateral) *
                100) /
            uint256(priceXAU) /
            10000;

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter
            .ExactOutputSingleParams({
                tokenIn: address(this),
                tokenOut: _collateralType,
                fee: 3000,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: 0
            });

        amountIn = swapRouter.exactOutputSingle(params);

        if (amountIn < amountInMaximum) {
            TransferHelper.safeApprove(_collateralType, address(swapRouter), 0);
            TransferHelper.safeTransfer(
                address(this),
                msg.sender,
                amountInMaximum - amountIn
            );

            amountInMaximum = amountIn;
        }

        //auction off the rest
        approve(auction, amountInMaximum);
        transferFrom(msg.sender, auction, amountInMaximum);
    }

    //withdraws collateral in exchange for a given amount of CHC tokens
    function withdrawCollateral(address _collateralType, uint256 _amount)
        external
    {

        console.log("balance", IERC20(_collateralType).balanceOf(address(this)));

        //transfer CHC back to contract
        transfer(address(this), _amount);

        //convert value of CHC into value of collateral
        //multiply by CHC/USD price
        (, int256 priceCHC, , , ) = oracleCHC.latestRoundData();
        (, int256 priceCollateral, , , ) = approvedCollateral[_collateralType]
            .oracle
            .latestRoundData();
        //divide by collateral to USD price
        uint256 collateralToReturn = div(_amount * uint256(priceCollateral),
            uint256(priceCHC));

        //decrease collateral balance at user's account
        userDeposits[msg.sender][_collateralType].deposited -= _amount;

        //burn the CHC amount
        _burn(address(this), _amount);

        userDeposits[msg.sender][_collateralType].minted -= collateralToReturn;

        //update collateralization ratio
        collateralizationRatio = collateralRatio();

        //require that the transfer to msg.sender of collat amount is successful
        if (_collateralType == address(0)) {
            (bool success, ) = msg.sender.call{value: collateralToReturn}("");
            require(success, "return of ether collateral was unsuccessful");
        } else {
            require(
                IERC20(_collateralType).transfer(msg.sender, collateralToReturn)
            );
        }
    }

    function withdrawFees() external {
        //30% to treasury
        //20% to swap solution for liquidity
        //50% to stability module

        //iterate through collateral types

        address collateralType;

        for (uint256 i; i < approvedTokens.length; i++) {
            collateralType = approvedTokens[i];

            //send as ether if ether
            if (collateralType == address(0)) {
                (bool success, ) = treasury.call{
                    value: wdiv(wmul(approvedCollateral[collateralType].fees, 3000), 
                        10000)
                }("");
                (success, ) = address(swapSolution).call{
                    value: wdiv(wmul(approvedCollateral[collateralType].fees, 2000), 
                        10000)
                }("");
                (success, ) = address(stabilityModule).call{
                    value: wdiv(wmul(approvedCollateral[collateralType].fees, 5000), 
                        10000)
                }("");

                approvedCollateral[collateralType].fees = 0;
            } else {

                console.log("fees", approvedCollateral[collateralType].fees);
                console.log("balance", IERC20(collateralType).balanceOf(address(this)));
                //transfer as token if token
                IERC20(collateralType).transfer(
                    treasury,
                    wdiv(wmul(approvedCollateral[collateralType].fees, 3000), 
                        10000)
                );

                IERC20(collateralType).approve(
                    address(swapSolution),
                    wdiv(wmul(approvedCollateral[collateralType].fees, 2000), 
                        10000)
                );
                swapSolution.addLiquidity(
                    collateralType,
                    wdiv(wmul(approvedCollateral[collateralType].fees, 2000), 
                        10000)
                );

                IERC20(collateralType).approve(
                    address(stabilityModule),
                    wdiv(wmul(approvedCollateral[collateralType].fees, 5000), 
                        10000)
                );
                stabilityModule.addTokens(
                    collateralType,
                    wdiv(wmul(approvedCollateral[collateralType].fees, 5000), 
                        10000)
                );

                approvedCollateral[collateralType].fees = 0;
            }
        }
    }

    //for depositing ETH as collateral
    receive() external payable {
        depositCollateral(address(0), msg.value);
    }
}
