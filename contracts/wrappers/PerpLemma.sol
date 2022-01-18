// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.3;
// pragma abicoder v2;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { ERC2771ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import { SafeCastUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import { IPerpetualDEXWrapper } from "../interfaces/IPerpetualDEXWrapper.sol";
import { Utils } from "../libraries/Utils.sol";
import { SafeMathExt } from "../libraries/SafeMathExt.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../libraries/TransferHelper.sol";
import "../interfaces/Perpetual/IClearingHouse.sol";
import "../interfaces/Perpetual/IClearingHouseConfig.sol";
import "../interfaces/Perpetual/IAccountBalance.sol";
import "../interfaces/Perpetual/IMarketRegistry.sol";
import "../interfaces/UniswapV3/IQuoter.sol";
import "hardhat/console.sol";

interface IPerpVault {
    function deposit(address token, uint256 amount) external;

    function withdraw(address token, uint256 amountX10_D) external;

    function getBalance(address trader) external view returns (int256);

    function decimals() external view returns (uint8);
    function getFreeCollateralByRatio(address trader, uint24 ratio)
        external
        view
        returns (int256 freeCollateralByRatio);
}

interface IUSDLemma {
    function lemmaTreasury() external view returns (address);
}

contract PerpLemma is OwnableUpgradeable, ERC2771ContextUpgradeable, IPerpetualDEXWrapper {
    using SafeCastUpgradeable for uint256;
    using SafeCastUpgradeable for int256;
    using Utils for int256;
    using SafeMathExt for int256;

    bytes32 public HashZero;
    uint256 public constant MAX_UINT256 = type(uint256).max;
    int256 public constant MAX_INT256 = type(int256).max;
    uint256 public constant HUNDREAD_PERCENT = 1000000; // 100% 

    address public usdLemma;
    address public reBalancer;
    address public baseTokenAddress;
    address public quoteTokenAddress;
    bytes32 public referrerCode;

    IERC20Upgradeable public collateral; // ETH
    uint256 public collateralDecimals;

    IClearingHouse public iClearingHouse;
    IClearingHouseConfig public iClearingHouseConfig;
    IPerpVault public iPerpVault;
    IAccountBalance public iAccountBalance;
    IMarketRegistry public iMarketRegistry;

    IQuoter public iUniV3Router;

    // Has the Market Settled
    bool public hasSettled;
    // Gets set only when Settlement has already happened 
    uint256 public positionAtSettlement;

    uint256 public maxPosition;

    //events
    event USDLemmaUpdated(address usdlAddress);
    event ReferrerUpdated(bytes32 referrerCode);
    event RebalancerUpdated(address rebalancerAddress);
    event MaxPositionUpdated(uint256 maxPos);

    modifier onlyUSDLemma() {
        require(msg.sender == usdLemma, "only usdLemma is allowed");
        _;
    }

    //@sunnyRK do not take redudunt arguments. e.g. _collateral is not required because _iPerpVault.getSettlementToken() will return collateral address. We can remove _collateral from the arguments.
    function initialize(
        address _collateral,
        address _baseToken,
        address _quoteToken,
        address _iClearingHouse, 
        address _iClearingHouseConfig,
        address _iPerpVault,
        address _iAccountBalance,
        address _iMarketRegistry,
        address _iUniV3Router,
        address _usdLemma,
        uint256 _maxPosition
    ) public initializer {
        __Ownable_init();
        usdLemma = _usdLemma;
        maxPosition = _maxPosition;
        baseTokenAddress = _baseToken;
        quoteTokenAddress = _quoteToken;
        collateral = IERC20Upgradeable(_collateral);
        iClearingHouse = IClearingHouse(_iClearingHouse);
        iClearingHouseConfig = IClearingHouseConfig(_iClearingHouseConfig);
        iPerpVault = IPerpVault(_iPerpVault);
        iMarketRegistry = IMarketRegistry(_iMarketRegistry);
        iUniV3Router = IQuoter(_iUniV3Router);
        iAccountBalance = IAccountBalance(_iAccountBalance);
        collateralDecimals = iPerpVault.decimals(); // need to verify
        collateral.approve(_iClearingHouse, MAX_UINT256);

        // NOTE: Even though it is not necessary, it is for clarity 
        hasSettled = false;
    }

    ///@notice sets USDLemma address - only owner can set
    ///@param _usdlemma USDLemma address to set
    function setUSDLemma(address _usdlemma) public onlyOwner {
        usdLemma = _usdlemma;
        emit USDLemmaUpdated(usdLemma);
    }

    ///@notice sets refferer address - only owner can set
    ///@param _referrerCode referrerCode of address to set
    function setReferrerCode(bytes32 _referrerCode) external onlyOwner {
        referrerCode = _referrerCode;
        emit ReferrerUpdated(referrerCode);
    }

    ///@notice sets reBalncer address - only owner can set
    ///@param _reBalancer reBalancer address to set
    function setReBalancer(address _reBalancer) public onlyOwner {
        reBalancer = _reBalancer;
        emit RebalancerUpdated(reBalancer);
    }

    ///@param _maxPosition reBalancer address to set
    function setMaxPosition(uint256 _maxPosition) public onlyOwner {
        maxPosition = _maxPosition;
        emit MaxPositionUpdated(maxPosition);
    }

    /// @notice reset approvals
    function resetApprovals() external {
        SafeERC20Upgradeable.safeApprove(collateral, address(iPerpVault), 0);
        SafeERC20Upgradeable.safeApprove(collateral, address(iPerpVault), MAX_UINT256);
    }

    //go short to open
    /// @notice Open short position on dex and deposit collateral
    /// @param amount worth in USD short position which is to be opened
    /// @param collateralAmountRequired collateral amount required to open the position
    function open(uint256 amount, uint256 collateralAmountRequired) external override onlyUSDLemma {
        // No Implementation
    }

    function openWExactCollateral(uint256 collateralAmount)
        external
        override
        onlyUSDLemma
        returns (uint256 USDLToMint)
    {
        require(!hasSettled, 'Market Closed');
        require(
            collateral.balanceOf(address(this)) >= getAmountInCollateralDecimals(collateralAmount, true),
            "not enough collateral"
        );
        iPerpVault.deposit(address(collateral), getAmountInCollateralDecimals(collateralAmount, true));

        IMarketRegistry.MarketInfo memory marketInfo = iMarketRegistry.getMarketInfo(baseTokenAddress);
        // fees cut from user's collateral by lemma for open position
        collateralAmount = collateralAmount - ((collateralAmount * marketInfo.exchangeFeeRatio) / HUNDREAD_PERCENT);
                
        // create short position by giving isBaseToQuote=true
        // and amount in eth(baseToken) by giving isExactInput=true
        IClearingHouse.OpenPositionParams memory params = IClearingHouse.OpenPositionParams({
            baseToken: baseTokenAddress,
            isBaseToQuote: false,
            isExactInput: true,
            amount: collateralAmount,
            oppositeAmountBound: 0,
            deadline: MAX_UINT256,
            sqrtPriceLimitX96: 0,
            referralCode: referrerCode
        });
        (uint256 base, uint256 quote) = iClearingHouse.openPosition(params);

        int256 positionSize = iAccountBalance.getTotalPositionValue(address(this), baseTokenAddress);
        console.log(positionSize.abs().toUint256());
        console.log(maxPosition);
        require(positionSize.abs().toUint256() <= maxPosition, "max position reached");
        //Is the fees considered internally or do we need to do it here?
        USDLToMint = base;
    }

    function close(uint256 amount, uint256 collateralAmountToGetBack) external override onlyUSDLemma {
        // No Implementation
    }

    function closeWExactCollateral(uint256 collateralAmount) external override returns (uint256 USDLToBurn) {
        require(_msgSender() == usdLemma, "only usdLemma is allowed");
        int256 temp1 = iAccountBalance.getQuote(address(this), baseTokenAddress);
        console.log("[PerpLemma closeWExactCollateral()] T1 getQuote() = %s%d", (temp1<0)?"-":"", uint256(temp1.abs()));

        console.log("[PerpLemma closeWExactCollateral()] Before Fees collateralAmountInCollateralDecimals = ", getAmountInCollateralDecimals(collateralAmount, true));
        if (hasSettled) return closeWExactCollateralAfterSettlement(collateralAmount);

        IMarketRegistry.MarketInfo memory marketInfo = iMarketRegistry.getMarketInfo(baseTokenAddress);
        // fees cut from user's collateral by lemma for close position
        console.log("[PerpLemma closeWExactCollateral()] marketInfo.exchangeFeeRatio = ", marketInfo.exchangeFeeRatio);
        uint256 fees = ((collateralAmount * marketInfo.exchangeFeeRatio) / HUNDREAD_PERCENT)*199/100;
        collateralAmount = collateralAmount - fees;
        console.log("[PerpLemma closeWExactCollateral()] collateralAmount = %d, Fees = %d", 
            collateralAmount, 
            fees);

        console.log("[PerpLemma closeWExactCollateral()] collateralAmount = %d, Fees = %d", 
            getAmountInCollateralDecimals(collateralAmount, true), 
            getAmountInCollateralDecimals(fees, true));

        //simillar to openWExactCollateral but for close
        IClearingHouse.OpenPositionParams memory params = IClearingHouse.OpenPositionParams({
            baseToken: baseTokenAddress,
            isBaseToQuote: true,        // Close Short
            isExactInput: false,        // Input in Quote = ETH --> See https://github.com/perpetual-protocol/perp-lushan/blob/main/contracts/lib/UniswapV3Broker.sol#L157
            amount: collateralAmount,
            oppositeAmountBound: 0,
            deadline: MAX_UINT256,
            sqrtPriceLimitX96: 0,
            referralCode: referrerCode
        });
        (, uint256 quote) = iClearingHouse.openPosition(params);


        int256 temp2 = iAccountBalance.getQuote(address(this), baseTokenAddress);
        console.log("[PerpLemma closeWExactCollateral()] T2 getQuote() = %s%d", (temp2<0)?"-":"", uint256(temp2.abs()));

        uint256 amountToWithdraw = getAmountInCollateralDecimals(quote, true);

        console.log("[PerpLemma closeWExactCollateral()] quote = %d, amountToWithdraw = %d", quote, amountToWithdraw);

        iPerpVault.withdraw(address(collateral), amountToWithdraw); // withdraw closed position fund

        int256 temp3 = iAccountBalance.getQuote(address(this), baseTokenAddress);
        console.log("[PerpLemma closeWExactCollateral()] T3 getQuote() = %s%d", (temp3<0)?"-":"", uint256(temp3.abs()));

        SafeERC20Upgradeable.safeTransfer(collateral, usdLemma, amountToWithdraw);
        console.log("[PerpLemma closeWExactCollateral()] DONE");
    }

    function closeWExactCollateralAfterSettlement(uint256 collateralAmount) internal returns (uint256 USDLToBurn) {
        console.log("[PerpLemma closeWExactCollateralAfterSettlement()] Start");
        // WPL_NP : Wrapper PerpLemma, No Position at settlement --> no more USDL to Burn
        require(positionAtSettlement > 0, 'WPL_NP');

        // WPL_NC : Wrapper PerpLemma, No Collateral 
        require(collateral.balanceOf(address(this)) > 0, 'WPL_NC');

        uint256 amountCollateralToTransfer = getAmountInCollateralDecimals(collateralAmount, true);

        USDLToBurn = amountCollateralToTransfer * positionAtSettlement / collateral.balanceOf(address(this));

        console.log("[PerpLemma closeWExactCollateralAfterSettlement()] PerpLemma Balance = %d and trying to transfer %d", collateral.balanceOf(address(this)), amountCollateralToTransfer);

        SafeERC20Upgradeable.safeTransfer(
            collateral,
            usdLemma,
            amountCollateralToTransfer
        );

        positionAtSettlement -= USDLToBurn;
    }

    function closeAfterSettlement(uint256 USDLAmount) internal
    {
        console.log("[PerpLemma closeAfterSettlement()] Start");
        require(positionAtSettlement > 0, 'Nothing to transfer');
        uint256 collateralAmountToGetBack = USDLAmount * collateral.balanceOf(address(this)) / positionAtSettlement;
        SafeERC20Upgradeable.safeTransfer(
            collateral,
            usdLemma,
            collateralAmountToGetBack
        );

        positionAtSettlement -= USDLAmount;
    }

    function getCollateralAmountGivenUnderlyingAssetAmount(uint256 amount, bool isShorting)
        external
        override
        returns (uint256 collateralAmountRequired)
    {
        // // TODO: K-Aizen Implement
        // address tokenIn;
        // address tokenOut;
        // uint24 fee = 10000;
        // uint160 sqrtPriceLimitX96 = 0;

        // if (isShorting) {
        //     tokenIn = address(baseTokenAddress);
        //     tokenOut = address(quoteTokenAddress);
        //     // Need to deposit `collateralAmountRequired` of collateral to mint `amount` USD
        //     collateralAmountRequired = iUniV3Router.quoteExactInputSingle(
        //         tokenIn, // token in
        //         tokenOut, // token out
        //         fee,
        //         amount,
        //         sqrtPriceLimitX96
        //     );
        // } else {
        //     int256 getBase = iAccountBalance.getBase(address(this), baseTokenAddress);

        //     int256 getBalance = iPerpVault.getBalance(address(this));
        //     getBalance = (getBalance * 1e18) / 1e6;

        //     int256 getCollateralForAmount = (int256(amount) * getBalance) / getBase.abs();
        //     collateralAmountRequired = uint256(getCollateralForAmount);

        //     console.log("getBase: ", uint256(getBase.abs()));
        //     console.log("getBalance: ", uint256(getBalance));
        //     console.log("getCollateralForAmount: ", uint256(getCollateralForAmount));

        //     // tokenIn = address(quoteTokenAddress);
        //     // tokenOut = address(baseTokenAddress);
        //     // // Burning `amount` USD we get `collateralAmountRequired` collateral
        //     // collateralAmountRequired = iUniV3Router.quoteExactInputSingle(
        //     //     tokenIn,
        //     //     tokenOut,
        //     //     fee,
        //     //     amount,
        //     //     sqrtPriceLimitX96
        //     // );
        // }
    }

    //// @notice when perpetual is in CLEARED state, withdraw the collateral
    function settle() public override {
        uint256 initialCollateral = collateral.balanceOf(address(this));
        console.log("[PerpLemma settle()] initialCollateral = ", initialCollateral);
        positionAtSettlement = iAccountBalance.getBase(address(this), baseTokenAddress).abs().toUint256();

        (uint256 base, uint256 quote) = iClearingHouse.closePositionInClosedMarket(address(this), baseTokenAddress);

        uint24 imRatio = iClearingHouseConfig.getImRatio();
        int256 freeCollateralByImRatioX10_D = iPerpVault.getFreeCollateralByRatio(address(this), imRatio);
        uint256 collateralAmountToWithdraw = freeCollateralByImRatioX10_D.abs().toUint256();

        console.log("[PerpLemma settle()] Trying to withdraw ", collateralAmountToWithdraw);

        iPerpVault.withdraw(address(collateral), collateralAmountToWithdraw);

        uint256 currentCollateral = collateral.balanceOf(address(this));
        console.log("[PerpLemma settle()] currentCollateral = ", currentCollateral);

        //require(currentCollateral - initialCollateral == collateralAmountToWithdraw, "Withdraw failed");

        // All the collateral is now back
        hasSettled = true;
    }


    /// @notice Rebalance position of dex based on accumulated funding, since last rebalancing
    /// @param _reBalancer Address of rebalancer who called function on USDL contract
    /// @param amount Amount of accumulated funding fees used to rebalance by opening or closing a short position
    /// @param data Abi encoded data to call respective perpetual function, contains limitPrice and deadline
    /// @return True if successful, False if unsuccessful
    function reBalance(
        address _reBalancer,
        int256 amount,
        bytes calldata data
    ) external override returns (bool) {
        require(_msgSender() == usdLemma, "only usdLemma is allowed");
        require(_reBalancer == reBalancer, "only rebalancer is allowed");

        (uint160 _sqrtPriceLimitX96, uint256 _deadline) = abi.decode(data, (uint160, uint256));

        bool _isBaseToQuote;
        bool _isExactInput;
        if (amount > 0) {
            // open long position and amount in usdc
            _isBaseToQuote = false;
            _isExactInput = true;
        } else {
            // open short position and amount in usdc
            _isBaseToQuote = true;
            _isExactInput = false;
        }

        IClearingHouse.OpenPositionParams memory params = IClearingHouse.OpenPositionParams({
            baseToken: baseTokenAddress,
            isBaseToQuote: _isBaseToQuote,
            isExactInput: _isExactInput,
            amount: uint256(amount.abs()),
            oppositeAmountBound: 0,
            deadline: _deadline,
            sqrtPriceLimitX96: _sqrtPriceLimitX96,
            referralCode: referrerCode
        });
        iClearingHouse.openPosition(params);
        return true;
    }

    /// @notice Get Amount in collateral decimals, provided amount is in 18 decimals
    /// @param amount Amount in 18 decimals
    /// @param roundUp If needs to round up
    /// @return decimal adjusted value
    function getAmountInCollateralDecimals(uint256 amount, bool roundUp) public view override returns (uint256) {
        if (roundUp && (amount % (uint256(10**(18 - collateralDecimals))) != 0)) {
            return amount / uint256(10**(18 - collateralDecimals)) + 1; // need to verify
        }

        return amount / uint256(10**(18 - collateralDecimals));
    }
    

    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address sender)
    {
        //ERC2771ContextUpgradeable._msgSender();
        return super._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        //ERC2771ContextUpgradeable._msgData();
        return super._msgData();
    }
}
