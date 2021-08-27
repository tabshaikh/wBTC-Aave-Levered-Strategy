// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ERC20} from "../deps/@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "../deps/@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/badger/IController.sol";

import {ILendingPoolAddressesProvider} from "../interfaces/aave/ILendingPoolAddressesProvider.sol";
import "../interfaces/aave/ILendingPool.sol";
import {IPriceOracle} from "../interfaces/aave/IPriceOracle.sol";
import {DataTypes} from "../interfaces/aave/DataTypes.sol";
import "../interfaces/aave/IAaveIncentivesController.sol";

import "../interfaces/uniswap/ISwapRouter.sol";

import {BaseStrategy} from "../deps/BaseStrategy.sol";

contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    // Setting up address provider as stated in aave docs - https://docs.aave.com/developers/the-core-protocol/addresses-provider
    ILendingPoolAddressesProvider public constant ADDRESS_PROVIDER =
        ILendingPoolAddressesProvider(
            0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5
        );

    //Initializing vToken - TODO: Make this immutable
    IERC20 public vToken;
    uint256 public DECIMALS; // For toETH conversion

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    address public aToken; // Token we provide liquidity with
    address public reward; // Token we farm and swap to want / aToken

    // Lending Pool Address from Aave docs
    address public constant LENDING_POOL =
        0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;

    // Incentives controller address from liquidity mining docs: https://docs.aave.com/developers/guides/liquidity-mining
    address public constant INCENTIVES_CONTROLLER =
        0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5;

    // For swapping
    address public constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public constant AAVE_TOKEN =
        0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address public constant WETH_TOKEN =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Leverage
    uint256 public constant MAX_BPS = 10000; // BPS - 0.01%
    uint256 public minHealth = 1080000000000000000; // 1.08 with 18 decimals this is slighly above 70% tvl
    uint256 public minRebalanceAmount = 50000000; // 0.5 should be changed based on decimals (btc has 8)

    uint256 public constant VARIABLE_RATE = 2;
    uint16 public constant REFERRAL_CODE = 0;

    // Used to signal to the Badger Tree that rewards where sent to it
    event TreeDistribution(
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256[3] memory _feeConfig
    ) public initializer {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );

        /// @dev Add config here
        want = _wantConfig[0];
        aToken = _wantConfig[1];
        reward = _wantConfig[2];

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        // Get Tokens Addresses
        DataTypes.ReserveData memory data = ILendingPool(LENDING_POOL)
            .getReserveData(address(want));

        // Get vToken
        vToken = IERC20(data.variableDebtTokenAddress);

        // Get Decimals
        DECIMALS = ERC20(address(want)).decimals();

        /// @dev do one off approvals here
        IERC20Upgradeable(want).safeApprove(LENDING_POOL, type(uint256).max);

        // Adding approve for uniswap router else it gives STF(Safe transfer failure) error
        IERC20Upgradeable(reward).safeApprove(ROUTER, type(uint256).max);
        IERC20Upgradeable(AAVE_TOKEN).safeApprove(ROUTER, type(uint256).max);
    }

    /// ===== View Functions =====

    // @dev Specify the name of the strategy
    function getName() external pure override returns (string memory) {
        return "wBTC AAVE Levered Strategy";
    }

    // @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public view override returns (uint256) {
        // Amount of aTokens
        return IERC20Upgradeable(aToken).balanceOf(address(this));
    }

    /// @dev Returns true if this strategy requires tending
    function isTendable() public view override returns (bool) {
        return balanceOfWant() > 0;
    }

    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](3);
        protectedTokens[0] = want;
        protectedTokens[1] = reward;
        protectedTokens[2] = AAVE_TOKEN;
        return protectedTokens;
    }

    /// ===== Permissioned Actions: Governance =====
    /// @notice Delete if you don't need!
    function setKeepReward(uint256 _setKeepReward) external {
        _onlyGovernance();
    }

    /// ===== Internal Core Implementations =====

    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        for (uint256 x = 0; x < protectedTokens.length; x++) {
            require(
                address(protectedTokens[x]) != _asset,
                "Asset is protected"
            );
        }
    }

    /// @dev invest the amount of want
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    function _deposit(uint256 _amount) internal override {
        ILendingPool(LENDING_POOL).deposit(want, _amount, address(this), 0); // aToken = deposit amount.
    }

    // Balance Helper functions -

    function AAVEToETH(uint256 _amt) public view returns (uint256) {
        address priceOracle = ADDRESS_PROVIDER.getPriceOracle();
        uint256 priceInEth = IPriceOracle(priceOracle).getAssetPrice(
            AAVE_TOKEN
        );
        // Price in ETH
        // AMT * Price in ETH / Decimals
        uint256 aaveToEth = _amt.mul(priceInEth).div(10**18);
        return aaveToEth;
    }

    function ethToWant(uint256 _amt) public view returns (uint256) {
        address priceOracle = ADDRESS_PROVIDER.getPriceOracle();
        uint256 priceInEth = IPriceOracle(priceOracle).getAssetPrice(want);
        // We Price of want in eth
        uint256 priceInWant = _amt.mul(10**DECIMALS).div(priceInEth);

        return priceInWant;
    }

    function valueOfAAVEToWant(uint256 aaveAmount)
        public
        view
        returns (uint256)
    {
        return ethToWant(AAVEToETH(aaveAmount));
    }

    function balanceOfRewards() public view returns (uint256) {
        address[] memory assets = new address[](2);
        assets[0] = aToken;
        assets[1] = address(vToken);

        uint256 totalRewards = IAaveIncentivesController(INCENTIVES_CONTROLLER)
            .getRewardsBalance(assets, address(this));

        return totalRewards;
    }

    function valueOfRewards() public view returns (uint256) {
        return valueOfAAVEToWant(balanceOfRewards());
    }

    ////////////////////////////////////////////////////////////////////////

    // Balance functions

    function estimatedTotalAssets() public view returns (uint256) {
        // Balance of want + balance in AAVE
        uint256 liquidBalance = IERC20Upgradeable(want)
            .balanceOf(address(this))
            .add(deposited())
            .sub(borrowed());

        // Return balance + reward
        return liquidBalance.add(valueOfRewards());
    }

    function deposited() public view returns (uint256) {
        return IERC20Upgradeable(aToken).balanceOf(address(this)); // When we deposit want, we get an equivalent amount of aToken
    }

    function borrowed() public view returns (uint256) {
        return vToken.balanceOf(address(this)); // When we borrow want to get an equivalent of vToken
    }

    ////////////////////////////////////////////////////////////////////////

    /* Leverage functions */
    // Gives the maximum amount we can borrow ...
    function canBorrow() internal returns (uint256) {
        (, , , , uint256 ltv, uint256 healthFactor) = ILendingPool(LENDING_POOL)
            .getUserAccountData(address(this));

        if (healthFactor > minHealth) {
            // Amount = deposited * ltv - borrowed
            // Div MAX_BPS because because ltv / maxbps is the percent
            uint256 maxValue = deposited().mul(ltv).div(MAX_BPS).sub(
                borrowed()
            );

            // Don't all borrow if
            if (maxValue < minRebalanceAmount) {
                return 0;
            }

            return maxValue;
        }

        return 0;
    }

    function _borrow(uint256 _amount) internal {
        // check how much maximum amount can one borrow
        // if amount <= maximum amount, allow borrow
        // update the params
        if (_amount <= canBorrow()) {
            ILendingPool(LENDING_POOL).borrow(
                want,
                _amount,
                VARIABLE_RATE,
                REFERRAL_CODE,
                address(this)
            ); // whenever we borrow vToken contract has amount
        }
    }

    function canRepay() public view returns (bool, uint256) {
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = ILendingPool(LENDING_POOL).getUserAccountData(address(this));

        uint256 aBalance = deposited();
        uint256 vBalance = borrowed();

        if (vBalance == 0) {
            return (false, 0); //You have repaid all
        }

        uint256 diff = aBalance.sub(
            vBalance.mul(MAX_BPS).div(currentLiquidationThreshold)
        );

        if (diff == 0) return (false, 0);

        return (true, diff);
    }

    function _repay(uint256 _amount) internal {
        (bool shouldRepay, uint256 repayAmount) = canRepay();
        if (shouldRepay) {
            if (_amount > repayAmount) {
                // who would want to repay more amount but still
                _amount = repayAmount;
            }
            if (_amount > 0) {
                ILendingPool(LENDING_POOL).withdraw( // would burn aToken when calling this method
                    want,
                    _amount,
                    address(this)
                );
                ILendingPool(LENDING_POOL).repay( // Repays a borrowed `amount` on a specific reserve, burning the equivalent debt tokens owned
                    want,
                    _amount,
                    VARIABLE_RATE,
                    address(this)
                );
            }
        }
    }

    /// @dev withdraw the specified amount of want, liquidate from aToken to want, paying off any necessary debt for the conversion
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        if (_amount > balanceOfPool()) {
            _amount = balanceOfPool();
        }

        ILendingPool(LENDING_POOL).withdraw(want, _amount, address(this));

        return _amount;
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest() external whenNotPaused returns (uint256 harvested) {
        _onlyAuthorizedActors();

        uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

        // Write your code here

        address[] memory assets = new address[](2);
        assets[0] = aToken;
        assets[1] = address(vToken);

        IAaveIncentivesController(INCENTIVES_CONTROLLER).claimRewards(
            assets,
            type(uint256).max,
            address(this)
        );

        uint256 rewardsAmount = IERC20Upgradeable(reward).balanceOf(
            address(this)
        );

        if (rewardsAmount == 0) {
            return 0;
        }

        // Still confusing ...

        ISwapRouter.ExactInputSingleParams memory fromRewardToAAVEParams = ISwapRouter
            .ExactInputSingleParams(
                reward,
                AAVE_TOKEN,
                10000,
                address(this),
                now, // exploitable how?
                rewardsAmount,
                0, //Minimum output
                0 // Minumum output in square root, 0 not suitable can be sandwitched? use chainlink
            );

        ISwapRouter(ROUTER).exactInputSingle(fromRewardToAAVEParams);

        bytes memory path = abi.encodePacked(
            AAVE_TOKEN,
            uint24(10000),
            WETH_TOKEN,
            uint24(10000),
            want
        );
        // why here ExactInputParams instead of single
        ISwapRouter.ExactInputParams memory fromAAVEToWBTCParams = ISwapRouter
            .ExactInputParams(
                path,
                address(this),
                now,
                IERC20Upgradeable(AAVE_TOKEN).balanceOf(address(this)),
                0
            );

        ISwapRouter(ROUTER).exactInput(fromAAVEToWBTCParams);

        uint256 earned = IERC20Upgradeable(want).balanceOf(address(this)).sub(
            _before
        );

        /// @notice Keep this in so you get paid!
        (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        ) = _processPerformanceFees(earned);

        // TODO: If you are harvesting a reward token you're not compounding
        // You probably still want to capture fees for it
        // // Process Sushi rewards if existing
        // if (sushiAmount > 0) {
        //     // Process fees on Sushi Rewards
        //     // NOTE: Use this to receive fees on the reward token
        //     _processRewardsFees(sushiAmount, SUSHI_TOKEN);

        //     // Transfer balance of Sushi to the Badger Tree
        //     // NOTE: Send reward to badgerTree
        //     uint256 sushiBalance = IERC20Upgradeable(SUSHI_TOKEN).balanceOf(address(this));
        //     IERC20Upgradeable(SUSHI_TOKEN).safeTransfer(badgerTree, sushiBalance);
        //
        //     // NOTE: Signal the amount of reward sent to the badger tree
        //     emit TreeDistribution(SUSHI_TOKEN, sushiBalance, block.number, block.timestamp);
        // }

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        /// @dev Harvest must return the amount of want increased
        return earned;
    }

    // Alternative Harvest with Price received from harvester, used to avoid exessive front-running
    function harvest(uint256 price)
        external
        whenNotPaused
        returns (uint256 harvested)
    {}

    /// @dev Rebalance, Compound or Pay off debt here
    function tend() external whenNotPaused {
        _onlyAuthorizedActors();

        if (balanceOfWant() > 0) {
            _deposit(balanceOfWant());
        }
    }

    /// @dev utility function to withdraw everything for migration
    // Would repay the loan and withdraw all the funds
    function _withdrawAll() internal override {
        // Before withdrawing all assets harvest rewards
        address[] memory assets = new address[](2);
        assets[0] = aToken;
        assets[1] = address(vToken);

        IAaveIncentivesController(INCENTIVES_CONTROLLER).claimRewards(
            assets,
            type(uint256).max,
            address(this)
        );

        uint256 rewardsAmount = IERC20Upgradeable(reward).balanceOf(
            address(this)
        );

        if (rewardsAmount > 0) {
            ISwapRouter.ExactInputSingleParams memory fromRewardToAAVEParams = ISwapRouter
                .ExactInputSingleParams(
                    reward,
                    AAVE_TOKEN,
                    10000,
                    address(this),
                    now, // exploitable how?
                    rewardsAmount,
                    0, //Minimum output
                    0 // Minumum output in square root, 0 not suitable can be sandwitched? use chainlink
                );

            ISwapRouter(ROUTER).exactInputSingle(fromRewardToAAVEParams);

            bytes memory path = abi.encodePacked(
                AAVE_TOKEN,
                uint24(10000),
                WETH_TOKEN,
                uint24(10000),
                want
            );
            // why here ExactInputParams instead of single
            ISwapRouter.ExactInputParams
                memory fromAAVEToWBTCParams = ISwapRouter.ExactInputParams(
                    path,
                    address(this),
                    now,
                    IERC20Upgradeable(AAVE_TOKEN).balanceOf(address(this)),
                    0
                );

            ISwapRouter(ROUTER).exactInput(fromAAVEToWBTCParams);
        }

        (bool shouldRepay, uint256 repayAmount) = canRepay();
        // Repay loan
        if (shouldRepay) {
            if (repayAmount > 0) {
                //Repay this step
                ILendingPool(LENDING_POOL).withdraw(
                    want,
                    repayAmount,
                    address(this)
                );
                ILendingPool(LENDING_POOL).repay(
                    want,
                    repayAmount,
                    VARIABLE_RATE,
                    address(this)
                );
            }
        }
        // Withdraw any more tokens left
        if (deposited() > 0) {
            ILendingPool(LENDING_POOL).withdraw(
                want,
                balanceOfPool(),
                address(this)
            );
        }
    }

    /// ===== Internal Helper Functions =====

    /// @dev used to manage the governance and strategist fee, make sure to use it to get paid!
    function _processPerformanceFees(uint256 _amount)
        internal
        returns (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        )
    {
        governancePerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistPerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }

    /// @dev used to manage the governance and strategist fee on earned rewards, make sure to use it to get paid!
    function _processRewardsFees(uint256 _amount, address _token)
        internal
        returns (uint256 governanceRewardsFee, uint256 strategistRewardsFee)
    {
        governanceRewardsFee = _processFee(
            _token,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistRewardsFee = _processFee(
            _token,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }
}
