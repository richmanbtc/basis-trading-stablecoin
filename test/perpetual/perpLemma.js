const { ethers } = require("hardhat");
const { expect, use } = require("chai");
const {solidity} = require('ethereum-waffle');
const { utils } = require('ethers');
const { parseEther, parseUnits } = require("ethers/lib/utils")
const { BigNumber } = require("@ethersproject/bignumber")
const { loadPerpLushanInfo, snapshot, revertToSnapshot, fromBigNumber } = require("../utils");
const bn = require("bignumber.js");
bn.config({ EXPONENTIAL_AT: 999999, DECIMAL_PLACES: 40 })

const ClearingHouseAbi = require('../../perp-lushan/artifacts/contracts/test/TestClearingHouse.sol/TestClearingHouse.json')
const OrderBookAbi = require('../../perp-lushan/artifacts/contracts/OrderBook.sol/OrderBook.json')
const ClearingHouseConfigAbi = require('../../perp-lushan/artifacts/contracts/ClearingHouseConfig.sol/ClearingHouseConfig.json')
const VaultAbi = require('../../perp-lushan/artifacts/contracts/Vault.sol/Vault.json')
const ExchangeAbi = require('../../perp-lushan/artifacts/contracts/Exchange.sol/Exchange.json')
const MarketRegistryAbi = require('../../perp-lushan/artifacts/contracts/MarketRegistry.sol/MarketRegistry.json')
const TestERC20Abi = require('../../perp-lushan/artifacts/contracts/test/TestERC20.sol/TestERC20.json')
const BaseTokenAbi = require('../../perp-lushan/artifacts/contracts/BaseToken.sol/BaseToken.json')
const BaseToken2Abi = require('../../perp-lushan/artifacts/contracts/BaseToken.sol/BaseToken.json')
const QuoteTokenAbi = require('../../perp-lushan/artifacts/contracts/QuoteToken.sol/QuoteToken.json')
const AccountBalanceAbi = require('../../perp-lushan/artifacts/contracts/AccountBalance.sol/AccountBalance.json')
const MockTestAggregatorV3Abi = require('../../perp-lushan/artifacts/contracts/mock/MockTestAggregatorV3.sol/MockTestAggregatorV3.json')
const UniswapV3PoolAbi = require('../../perp-lushan/artifacts/@uniswap/v3-core/contracts/UniswapV3Pool.sol/UniswapV3Pool.json')
const UniswapV3Pool2Abi = require('../../perp-lushan/artifacts/@uniswap/v3-core/contracts/UniswapV3Pool.sol/UniswapV3Pool.json');
const QuoterAbi = require('../../perp-lushan/artifacts/@uniswap/v3-periphery/contracts/lens/Quoter.sol/Quoter.json')
const UniswapV3FactoryAbi = require('../../perp-lushan/artifacts/@uniswap/v3-core/contracts/UniswapV3Factory.sol/UniswapV3Factory.json');

use(solidity);

function encodePriceSqrt(reserve1, reserve0) {
    return BigNumber.from(
        new bn(reserve1.toString())
            .div(reserve0.toString())
            .sqrt()
            .multipliedBy(new bn(2).pow(96))
            .integerValue(3)
            .toString(),
    )
}

describe("perpLemma", async function () {
    let defaultSigner, usdLemma, reBalancer, hasWETH, keeperGasReward, signer1, signer2, usdl2;
    let perpAddresses;
    const ZERO = BigNumber.from("0");
    let snapshotId;

    let clearingHouse
    let marketRegistry
    let clearingHouseConfig
    let exchange
    let orderBook
    let accountBalance
    let vault
    let collateral
    let baseToken
    let baseToken2
    let quoteToken
    let univ3factory
    let pool
    let pool2
    let mockedBaseAggregator
    let mockedBaseAggregator2
    let quoter
    let perpLemma
    let collateralDecimals
    const lowerTick = 0
    const upperTick = 100000

    before(async function () {
        [defaultSigner, usdLemma, reBalancer, hasWETH, signer1, signer2, usdl2] = await ethers.getSigners();
        perpAddresses = await loadPerpLushanInfo();
        clearingHouse = new ethers.Contract(perpAddresses.clearingHouse.address, ClearingHouseAbi.abi, defaultSigner)
        orderBook = new ethers.Contract(perpAddresses.orderBook.address, OrderBookAbi.abi, defaultSigner);
        clearingHouseConfig = new ethers.Contract(perpAddresses.clearingHouseConfig.address, ClearingHouseConfigAbi.abi, defaultSigner);
        vault = new ethers.Contract(perpAddresses.vault.address, VaultAbi.abi, defaultSigner);
        exchange = new ethers.Contract(perpAddresses.exchange.address, ExchangeAbi.abi, defaultSigner);
        marketRegistry = new ethers.Contract(perpAddresses.marketRegistry.address, MarketRegistryAbi.abi, defaultSigner);
        collateral = new ethers.Contract(perpAddresses.collateral.address, TestERC20Abi.abi, defaultSigner);
        baseToken = new ethers.Contract(perpAddresses.baseToken.address, BaseTokenAbi.abi, defaultSigner);
        baseToken2 = new ethers.Contract(perpAddresses.baseToken2.address, BaseToken2Abi.abi, defaultSigner);
        quoteToken = new ethers.Contract(perpAddresses.quoteToken.address, QuoteTokenAbi.abi, defaultSigner);
        univ3factory = new ethers.Contract(perpAddresses.univ3factory.address, UniswapV3FactoryAbi.abi, defaultSigner)
        accountBalance = new ethers.Contract(perpAddresses.accountBalance.address, AccountBalanceAbi.abi, defaultSigner);
        mockedBaseAggregator = new ethers.Contract(perpAddresses.mockedBaseAggregator.address, MockTestAggregatorV3Abi.abi, defaultSigner);
        mockedBaseAggregator2 = new ethers.Contract(perpAddresses.mockedBaseAggregator2.address, MockTestAggregatorV3Abi.abi, defaultSigner);
        pool = new ethers.Contract(perpAddresses.pool.address, UniswapV3PoolAbi.abi, defaultSigner);
        pool2 = new ethers.Contract(perpAddresses.pool2.address, UniswapV3Pool2Abi.abi, defaultSigner);
        quoter = new ethers.Contract(perpAddresses.quoter.address, QuoterAbi.abi, defaultSigner)
        collateralDecimals = await collateral.decimals()

        const maxPosition = ethers.constants.MaxUint256;
        const perpLemmaFactory = await ethers.getContractFactory("PerpLemma")
        perpLemma = await upgrades.deployProxy(perpLemmaFactory, 
            [
                baseToken.address,
                quoteToken.address,
                clearingHouse.address,
                marketRegistry.address,
                quoter.address,
                usdLemma.address,
                maxPosition
        ], { initializer: 'initialize' });
        await perpLemma.connect(signer1).resetApprovals()

        await mockedBaseAggregator.setLatestRoundData(0, parseUnits("1", collateralDecimals), 0, 0, 0)
        await mockedBaseAggregator2.setLatestRoundData(0, parseUnits("100", collateralDecimals), 0, 0, 0)

        await pool.initialize(encodePriceSqrt("1", "100"))
        // the initial number of oracle can be recorded is 1; thus, have to expand it
        await pool.increaseObservationCardinalityNext((2 ^ 16) - 1)
        await pool2.initialize(encodePriceSqrt("1", "100")) // tick = 50200 (1.0001^50200 = 151.373306858723226652)

        await marketRegistry.addPool(baseToken.address, 10000)
        await marketRegistry.addPool(baseToken2.address, 10000)
        await marketRegistry.setFeeRatio(baseToken.address, 10000)
        await marketRegistry.setFeeRatio(baseToken2.address, 10000)

        // prepare collateral for maker
        const makerCollateralAmount = parseUnits("1000000", collateralDecimals)
        await collateral.mint(signer1.address, makerCollateralAmount)
        await collateral.mint(signer2.address, makerCollateralAmount)
        
        const parsedAmount = parseUnits("100000", collateralDecimals)
        await collateral.connect(signer1).approve(vault.address, ethers.constants.MaxUint256)
        await collateral.connect(signer2).approve(vault.address, ethers.constants.MaxUint256)

        // Deposit into vault
        // await vault.connect(signer1).deposit(collateral.address, parsedAmount)
        await vault.connect(signer2).deposit(collateral.address, parsedAmount)
        await clearingHouse.connect(signer2).addLiquidity({
            baseToken: baseToken.address,
            base: parseEther('10000'),
            quote: parseEther('100'),
            lowerTick: -887200, //50000,
            upperTick: 887200, //50400,
            minBase: 0,
            minQuote: 0,
            useTakerBalance: false,
            deadline: ethers.constants.MaxUint256,
        })
    })
    
    beforeEach(async function () {
        snapshotId = await snapshot();
    });
    
    afterEach(async function () {
        await revertToSnapshot(snapshotId);
    });

    it("should set addresses correctly", async function () {
        //setUSDLemma
        await expect(perpLemma.connect(signer1).setUSDLemma(signer1.address)).to.be.revertedWith("Ownable: caller is not the owner");
        await perpLemma.connect(defaultSigner).setUSDLemma(signer1.address);
        expect(await perpLemma.usdLemma()).to.equal(signer1.address);

        //setReferrer
        await expect(perpLemma.connect(signer1).setReferrerCode(
            ethers.utils.formatBytes32String("Hello World")
        )).to.be.revertedWith("Ownable: caller is not the owner");

        await perpLemma.connect(defaultSigner).setReferrerCode(
            ethers.utils.formatBytes32String("Hello World")
        );
            
        const byteCode = await perpLemma.referrerCode()
        expect(ethers.utils.parseBytes32String(byteCode)).to.eq("Hello World")
    });

    it("should fail to open when max position is reached", async function () {
        const collateralAmount = parseUnits("1", collateralDecimals) // 6 decimal
        await perpLemma.setMaxPosition(collateralAmount);
        await collateral.mint(usdLemma.address, collateralAmount.add(1))
        await collateral.connect(usdLemma).transfer(perpLemma.address, collateralAmount.add(1))
        await expect(perpLemma.connect(usdLemma).openWExactCollateral(collateralAmount.add(1))).to.be.revertedWith("max position reached");
    })

    // need to correct more for collateralAmountToGetBack in close() position
    it("should close position correctly", async function () {
        const collateralAmount = parseUnits("100", collateralDecimals) // 6 decimal
        await collateral.mint(usdLemma.address, collateralAmount)

        // transfer Collateral to perpLemma
        await collateral.connect(usdLemma).transfer(perpLemma.address, parseEther('1'))
        // Deposit collateral in eth and Short eth and long usdc 
        await perpLemma.connect(usdLemma).openWExactCollateral(parseEther('1'))

        positionSize = await accountBalance.getTotalPositionSize(perpLemma.address, baseToken.address) 
        // long eth and close position, withdraw collateral
        await expect(await perpLemma.connect(usdLemma).closeWExactCollateral(positionSize)).to.emit(clearingHouse, 'PositionChanged')
    })

    describe("OpenPosition", () => {
        let collateralToGetBack_1e6, collateralToGetBack_1e18
        beforeEach(async function () {

            const collateralAmount = parseEther('1')
            await collateral.mint(usdLemma.address, collateralAmount)
            await collateral.connect(usdLemma).transfer(perpLemma.address, collateralAmount)
        });

        it("openPosition => emit event PositionChanged", async () => {
            await expect(perpLemma.connect(usdLemma).openWExactCollateral(parseEther('1'))).to.emit(clearingHouse, 'PositionChanged')            
        });

        it("openPosition => leverage should be 1x", async () => {
            await expect(perpLemma.connect(usdLemma).openWExactCollateral(parseEther('1'))).to.emit(clearingHouse, 'PositionChanged')            
            const depositedCollateral = await vault.getBalance(perpLemma.address)
            const positionSize = await accountBalance.getTotalPositionSize(perpLemma.address, baseToken.address)
            const ethPrice = await mockedBaseAggregator2.getRoundData(0) //ethPrice
            const leverage = depositedCollateral.mul(ethPrice[1]).div(positionSize) // 979999(close to 1e6 or 1x)
            // console.log('positionSize:' , positionSize.toString())
            // console.log('ethPrice:' , ethPrice[1].toString())
            // console.log('divisor:' , divisor.toString())
            // console.log('depositedCollateral:' , depositedCollateral.toString())
            // console.log('leverage:' , leverage.toString())
            expect(leverage).to.be.closeTo(parseUnits('1', collateralDecimals), parseEther('0.031')); // leverage should be 1x(1e6) or close to 1e6
        });
    })

    describe("OpenPosition with getCollateralAmountGivenUnderlyingAssetAmount", () => {
        let collateralmintAmount
        beforeEach(async function () {
            collateralmintAmount = parseEther('1')
            await collateral.mint(usdLemma.address, collateralmintAmount)
        });

        it("openPosition => open position for short and close position for 2 time longs", async () => {
            // let collateralToGetBack_1e18 = await perpLemma.callStatic.getCollateralAmountGivenUnderlyingAssetAmount(parseEther('1'), true)
            // let collateralToGetBack_1e6 = collateralToGetBack_1e18.mul(parseUnits('1', collateralDecimals)).div(parseEther('1'))
            await collateral.connect(usdLemma).transfer(perpLemma.address, collateralmintAmount)
            await perpLemma.connect(usdLemma).openWExactCollateral(parseEther('1'))

            let positionSize = await accountBalance.getTotalPositionSize(perpLemma.address, baseToken.address)
            // #1    
            await expect(perpLemma.connect(usdLemma).closeWExactCollateral(positionSize.div(2))).to.emit(clearingHouse, 'PositionChanged')
            // #2
            await expect(perpLemma.connect(usdLemma).closeWExactCollateral(positionSize.div(2))).to.emit(clearingHouse, 'PositionChanged')
            positionSize = await accountBalance.getTotalPositionSize(perpLemma.address, baseToken.address) 
            expect(positionSize).to.be.closeTo(parseEther('1'), parseEther('0.1'))
        });

        it("openPosition => open position for short and close position for long", async () => {
            await collateral.connect(usdLemma).transfer(perpLemma.address, collateralmintAmount)
            await perpLemma.connect(usdLemma).openWExactCollateral(collateralmintAmount)
            let positionSize = await accountBalance.getTotalPositionSize(perpLemma.address, baseToken.address)
            await expect(perpLemma.connect(usdLemma).closeWExactCollateral(positionSize)).to.emit(clearingHouse, 'PositionChanged')
            positionSize = await accountBalance.getTotalPositionSize(perpLemma.address, baseToken.address) 
            expect(positionSize).to.be.closeTo(parseEther('1'), parseEther('0.1'))
        });
    })

    describe("re balance", async function () {
        let collateralmintAmount, collateralAmount, parsedAmount, leveragedAmount
        before(async function () {
            await perpLemma.connect(defaultSigner).setReBalancer(reBalancer.address);
        })
        beforeEach(async function () {
            collateralmintAmount = parseEther('1')
            // collateralAmount = parseUnits("1000", collateralDecimals) // 6 decimal
            // parsedAmount =  collateralAmount.mul(parseEther('1')).div(parseUnits('1', 6)) // 18 decimal
            // leveragedAmount = parsedAmount.mul('1') // for 1x
            await collateral.mint(usdLemma.address, collateralmintAmount)
        });

        it("if amount is positive then it should long", async () => {
            const sqrtPriceLimitX96 = 0;
            const deadline = ethers.constants.MaxUint256;
            await collateral.connect(usdLemma).transfer(perpLemma.address, collateralmintAmount)
            await perpLemma.connect(usdLemma).openWExactCollateral(collateralmintAmount)
            const rebalanceAmount = parseEther('0.05') // 5% of 1 ether
            await perpLemma.connect(usdLemma).reBalance(
                reBalancer.address, 
                BigNumber.from(rebalanceAmount), // positive amount(+ve)
                ethers.utils.defaultAbiCoder.encode(
                    ["uint160", "uint256"], 
                    [sqrtPriceLimitX96, deadline]
                )
            );
        })

        it("if amount is negative then it should short", async () => {
            const sqrtPriceLimitX96 = 0;
            const deadline = ethers.constants.MaxUint256;
            // await expect(perpLemma.connect(usdLemma).open(leveragedAmount, collateralAmount)).to.emit(clearingHouse, 'PositionChanged')
            await collateral.connect(usdLemma).transfer(perpLemma.address, collateralmintAmount)
            await perpLemma.connect(usdLemma).openWExactCollateral(collateralmintAmount)
            const rebalanceAmount = parseEther('0.05') // 5% of 1 ether
            await perpLemma.connect(usdLemma).reBalance(
                reBalancer.address, 
                BigNumber.from(rebalanceAmount).mul(-1), // negative amount(-ve)
                ethers.utils.defaultAbiCoder.encode(
                    ["uint160", "uint256"], 
                    [sqrtPriceLimitX96, deadline]
                )
            );
        })
    })
})
