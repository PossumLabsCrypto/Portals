// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MintBurnToken} from "./MintBurnToken.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {ICompounder} from "./interfaces/ICompounder.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";

/// @title Portal Contract
/// @author Possum Labs
/** @notice This contract accepts user deposits and withdrawals of a specific token
* The deposits are redirected to an external protocol to generate yield
* Yield is claimed and collected into this contract
* Users accrue portalEnergy points over time while staking their tokens
* portalEnergy can be exchanged against the PSM token using the internal Liquidity Pool or minted as ERC20
* The contract can receive PSM tokens during the funding phase and issues bTokens as receipt
* bTokens can be redeemed against the fundingRewardPool which consists of PSM tokens
* The fundingRewardPool is filled over time by taking a 10% cut from the Converter
* The Converter is an arbitrage mechanism that allows anyone to sweep the contract balance of a token
* When triggering the Converter, the arbitrager must send a fixed amount of PSM tokens to the contract
*/

error DeadlineExpired();

contract Portal is ReentrancyGuard {
    constructor(uint256 _fundingPhaseDuration, 
        uint256 _fundingExchangeRatio,
        uint256 _fundingRewardRate, 
        address _principalToken,
        address _tokenToAcquire, 
        uint256 _terminalMaxLockDuration, 
        uint256 _amountToConvert)
        {
            fundingPhaseDuration = _fundingPhaseDuration;
            fundingExchangeRatio = _fundingExchangeRatio;
            fundingRewardRate = _fundingRewardRate;
            principalToken = _principalToken;
            bToken = new MintBurnToken(address(this),"bToken","BT");
            portalEnergyToken = new MintBurnToken(address(this),"Portal Energy","PE");
            tokenToAcquire = _tokenToAcquire;
            terminalMaxLockDuration = _terminalMaxLockDuration;
            amountToConvert = _amountToConvert;
            creationTime = block.timestamp;
    }

    // ============================================
    // ==        GLOBAL VARIABLES & EVENTS       ==
    // ============================================
    using SafeERC20 for IERC20;

    // general
    MintBurnToken bToken;                                   // the receipt token from bootstrapping
    MintBurnToken portalEnergyToken;                        // the ERC20 representation of portalEnergy
    
    //address immutable public bToken;                        // address of the bToken which is the receipt token from bootstrapping
    //address immutable public portalEnergyToken;             // address of portalEnergyToken, the ERC20 representation of portalEnergy
    address immutable public tokenToAcquire;                // address of PSM token
    uint256 immutable public amountToConvert;               // constant amount of PSM tokens required to withdraw yield in the contract
    uint256 immutable public terminalMaxLockDuration;       // terminal maximum lock duration of user´s balance in seconds
    uint256 immutable public creationTime;                  // time stamp of deployment
    uint256 constant private secondsPerYear = 31536000;     // seconds in a 365 day year
    uint256 public maxLockDuration = 7776000;               // starting value for maximum allowed lock duration of user´s balance in seconds (90 days)
    uint256 public totalPrincipalStaked;                    // shows how much principal is staked by all users combined
    bool private lockDurationUpdateable = true;             // flag to signal if the lock duration can still be updated

    // principal management related
    address immutable public principalToken;                // address of the token accepted by the strategy as deposit (HLP)
    address payable private constant compounderAddress = payable (0x8E5D083BA7A46f13afccC27BFB7da372E9dFEF22);

    address payable private constant HLPstakingAddress = payable (0xbE8f8AF5953869222eA8D39F1Be9d03766010B1C);
    address private constant HLPprotocolRewarder = 0x665099B3e59367f02E5f9e039C3450E31c338788;
    address private constant HLPemissionsRewarder = 0x6D2c18B559C5343CB0703bB55AADB5f22152cC32;

    address private constant HMXstakingAddress = 0x92E586B8D4Bf59f4001604209A292621c716539a;
    address private constant HMXprotocolRewarder = 0xB698829C4C187C85859AD2085B24f308fC1195D3;
    address private constant HMXemissionsRewarder = 0x94c22459b145F012F1c6791F2D729F7a22c44764;
    address private constant HMXdragonPointsRewarder = 0xbEDd351c62111FB7216683C2A26319743a06F273;

    // bootstrapping related
    uint256 immutable public fundingPhaseDuration;         // seconds that the funding phase lasts before Portal can be activated
    uint256 public fundingBalance;                          // sum of all PSM funding contributions
    uint256 public fundingRewardPool;                       // amount of PSM available for redemption against bTokens
    uint256 public fundingRewardsCollected;                 // tracker of PSM collected over time for the reward pool
    uint256 public fundingMaxRewards;                       // maximum amount of PSM to be collected for reward pool
    uint256 immutable public fundingRewardRate;             // baseline return on funding the Portal
    uint256 immutable private fundingExchangeRatio;         // amount of portalEnergy per PSM for calculating k during funding process
    uint256 constant public fundingRewardShare = 10;        // 10% of yield goes to the funding pool until investors are paid back
    bool public isActivePortal = false;                     // this will be set to true when funding phase ends.

    // exchange related
    uint256 public constantProduct;                        // the K constant of the (x*y = K) constant product formula

    // user related
    struct Account {                                       // contains information of user stake positions
        bool isExist;
        uint256 lastUpdateTime;
        uint256 stakedBalance;
        uint256 maxStakeDebt;
        uint256 portalEnergy;
        uint256 availableToWithdraw;
    }

    mapping(address => Account) public accounts;            // Associate users with their stake position

    // --- Events related to the funding phase ---
    event PortalActivated(address indexed, uint256 fundingBalance);
    event FundingReceived(address indexed, uint256 amount);
    event RewardsRedeemed(address indexed, uint256 amountBurned, uint256 amountReceived);

    // --- Events related to internal exchange PSM vs. portalEnergy ---
    event portalEnergyBuyExecuted(address indexed, uint256 amount);
    event portalEnergySellExecuted(address indexed, uint256 amount);

    // --- Events related to minting and burning portalEnergyToken ---
    event portalEnergyMinted(address indexed, address recipient, uint256 amount);
    event portalEnergyBurned(address indexed, address recipient, uint256 amount);

    // --- Events related to staking & unstaking ---
    event TokenStaked(address indexed user, uint256 amountStaked);
    event TokenUnstaked(address indexed user, uint256 amountUnstaked);
    event RewardsClaimed(address[] indexed pools, address[][] rewarders, uint256 timeStamp);

    event StakePositionUpdated(address indexed user, 
        uint256 lastUpdateTime,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy,
        uint256 availableToWithdraw);                       // principal available to withdraw

    // ============================================
    // ==           STAKING & UNSTAKING          ==
    // ============================================

    /// @notice Update user data to the current state
    /// @dev This function updates the user data to the current state
    /// @dev It calculates the accrued portalEnergy since the last update
    /// @dev It calculates the added portalEnergy due to increased stake balance
    /// @dev It updates the last update time stamp
    /// @dev It updates the user's staked balance
    /// @dev It updates the user's maxStakeDebt
    /// @dev It updates the user's portalEnergy
    /// @dev It updates the amount available to unstake
    /// @param _user The user whose data is to be updated
    /// @param _amount The amount to be added to the user's staked balance
    function _updateAccount(address _user, uint256 _amount) private {
        /// @dev Calculate the accrued portalEnergy since the last update
        uint256 portalEnergyEarned = (accounts[_user].stakedBalance * 
            (block.timestamp - accounts[_user].lastUpdateTime)) / secondsPerYear;

        /// @dev Calculate the increase of portalEnergy due to balance increase
        uint256 portalEnergyIncrease = (_amount * maxLockDuration) / secondsPerYear;

        /// @dev Update the last update time stamp
        accounts[_user].lastUpdateTime = block.timestamp;

        /// @dev Update the user's staked balance
        accounts[_user].stakedBalance += _amount;

        /// @dev Update the user's maxStakeDebt based on the new stake amount
        /// @dev If the maxLockDuration increases, already staked balances will not increase their maxStakeDebt
        /// @dev This is required so that the withdrawal math works as intended
        /// @notice Users seeking to increase their maxStakeDebt to the fullest extent must re-stake after duration increase
        accounts[_user].maxStakeDebt += portalEnergyIncrease;

        /// @dev Update the user's portalEnergy
        accounts[_user].portalEnergy += portalEnergyEarned + portalEnergyIncrease;

        /// @dev Update the amount available to unstake
        if (accounts[_user].portalEnergy >= accounts[_user].maxStakeDebt) {
            accounts[_user].availableToWithdraw = accounts[_user].stakedBalance;
        } else {
            accounts[_user].availableToWithdraw = (accounts[_user].stakedBalance * accounts[_user].portalEnergy) / accounts[_user].maxStakeDebt;
        }
    }


    /// @notice Stake the principal token into the Portal & redirect principal to yield source
    /// @dev This function allows users to stake their principal tokens into the Portal
    /// @dev It checks if the Portal is active
    /// @dev It transfers the user's principal tokens to the contract
    /// @dev It updates the total stake balance
    /// @dev It deposits the principal into the yield source (external protocol)
    /// @dev It checks if the user has a staking position, else it initializes a new stake
    /// @dev It emits an event with the updated stake information
    /// @param _amount The amount of tokens to stake    
    function stake(uint256 _amount) external nonReentrant {
        /// @dev Require that the Portal is active
        require(isActivePortal, "Portal inactive");
        
        /// @dev Transfer the user's principal tokens to the contract
        IERC20(principalToken).safeTransferFrom(msg.sender, address(this), _amount);
        
        /// @dev Update the total stake balance
        totalPrincipalStaked += _amount;

        /// @dev Deposit the principal into the yield source (external protocol)
        _depositToYieldSource();

        /// @dev Check if the user has a staking position, else initialize a new stake
        if(accounts[msg.sender].isExist == true){
            /// @dev Update the user's stake info
            _updateAccount(msg.sender, _amount);
        } 
        else {
            uint256 maxStakeDebt = (_amount * maxLockDuration) / secondsPerYear;
            uint256 availableToWithdraw = _amount;
            uint256 portalEnergy = maxStakeDebt;
            
            accounts[msg.sender] = Account(true, 
                block.timestamp, 
                _amount, 
                maxStakeDebt, 
                portalEnergy,
                availableToWithdraw);     
        }
        
        /// @dev Emit an event with the updated stake information
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].portalEnergy, 
        accounts[msg.sender].availableToWithdraw);
    }


    /// @notice Serve unstaking requests & withdraw principal from yield source
    /// @dev This function allows users to unstake their tokens and withdraw the principal from the yield source
    /// @dev It checks if the user has a stake and updates the user's stake data
    /// @dev It checks if the amount to be unstaked is less than or equal to the available withdrawable balance and the staked balance
    /// @dev It withdraws the matching amount of principal from the yield source (external protocol)
    /// @dev It updates the user's staked balance
    /// @dev It updates the user's maximum stake debt
    /// @dev It updates the user's withdrawable balance
    /// @dev It updates the global tracker of staked principal
    /// @dev It sends the principal tokens to the user
    /// @dev It emits an event with the updated stake information
    /// @param _amount The amount of tokens to unstake
    function unstake(uint256 _amount) external nonReentrant {
        /// @dev Require that the user has a stake
        require(accounts[msg.sender].isExist == true,"User has no stake");
        /// @dev Update the user's stake data
        _updateAccount(msg.sender,0);

        /// @dev Require that the amount to be unstaked is less than or equal to the available withdrawable balance and the staked balance
        require(_amount <= accounts[msg.sender].availableToWithdraw, "Insufficient withdrawable balance");
        require(_amount <= accounts[msg.sender].stakedBalance, "Insufficient stake balance");

        /// @dev Withdraw the matching amount of principal from the yield source (external protocol)
        _withdrawFromYieldSource(_amount);

        /// @dev Update the user's stake info
        accounts[msg.sender].stakedBalance -= _amount;
        accounts[msg.sender].maxStakeDebt -= (_amount * maxLockDuration) / secondsPerYear;
        accounts[msg.sender].portalEnergy -= (_amount * maxLockDuration) / secondsPerYear;
        accounts[msg.sender].availableToWithdraw -= _amount;

        /// @dev Update the global tracker of staked principal
        totalPrincipalStaked -= _amount;

        /// @dev Send the principal tokens to the user
        IERC20(principalToken).safeTransfer(msg.sender, _amount);

        /// @dev Emit an event with the updated stake information
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].portalEnergy,
        accounts[msg.sender].availableToWithdraw);
    }


    /// @notice Force unstaking via burning portalEnergyToken from user wallet to decrease debt sufficiently
    /// @dev This function allows users to force unstake all their tokens by burning portalEnergyToken from their wallet
    /// @dev It checks if the user has a stake and updates the user's stake data
    /// @dev It calculates how many portalEnergyToken must be burned from the user's wallet, if any
    /// @dev It burns the appropriate portalEnergyToken from the user's wallet to increase portalEnergy sufficiently
    /// @dev It withdraws the principal from the yield source to pay the user
    /// @dev It updates the user's information
    /// @dev It sends the full stake balance to the user
    /// @dev It emits an event with the updated stake information
    function forceUnstakeAll() external nonReentrant {
        /// @dev Require that the user has a stake
        require(accounts[msg.sender].isExist == true,"User has no stake");
        /// @dev Update the user's stake data
        _updateAccount(msg.sender,0);

        /// @dev Calculate how many portalEnergyToken must be burned from the user's wallet, if any
        if(accounts[msg.sender].portalEnergy < accounts[msg.sender].maxStakeDebt) {

            uint256 remainingDebt = accounts[msg.sender].maxStakeDebt - accounts[msg.sender].portalEnergy;

            /// @dev Require that the user has enough Portal Energy Tokens
            require(IERC20(portalEnergyToken).balanceOf(address(msg.sender)) >= remainingDebt, "Not enough Portal Energy Tokens");
            /// @dev Burn the appropriate portalEnergyToken from the user's wallet to increase portalEnergy sufficiently
            _burnPortalEnergyToken(msg.sender, remainingDebt);
        }

        /// @dev Withdraw the principal from the yield source to pay the user
        uint256 balance = accounts[msg.sender].stakedBalance;
        _withdrawFromYieldSource(balance);

        /// @dev Update the user's stake info
        accounts[msg.sender].stakedBalance = 0;
        accounts[msg.sender].maxStakeDebt = 0;
        accounts[msg.sender].portalEnergy -= (balance * maxLockDuration) / secondsPerYear;
        accounts[msg.sender].availableToWithdraw = 0;

        /// @dev Send the user´s staked balance to the user
        IERC20(principalToken).safeTransfer(msg.sender, balance);
        
        /// @dev Update the global tracker of staked principal
        totalPrincipalStaked -= balance;

        /// @dev Emit an event with the updated stake information
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].portalEnergy,
        accounts[msg.sender].availableToWithdraw);
    }

    // ============================================
    // ==      PRINCIPAL & REWARD MANAGEMENT     ==
    // ============================================

    /// @notice Deposit principal into yield source
    /// @dev This function deposits principal tokens from the Portal into the external protocol
    /// @dev It approves the amount of tokens to be transferred
    /// @dev It transfers the tokens from the Portal to the external protocol via interface
    /// @dev It emits an Event that tokens have been staked
    function _depositToYieldSource() private {
        /// @dev Read how many principalTokens are in the contract and approve this amount
        uint256 balance = IERC20(principalToken).balanceOf(address(this));
        IERC20(principalToken).approve(HLPstakingAddress, balance);

        /// @dev Transfer the approved balance to the external protocol using the interface
        IStaking(HLPstakingAddress).deposit(address(this), balance);

        /// @dev Emit an event that tokens have been staked for the user
        emit TokenStaked(msg.sender, balance);
    }


    /// @notice Withdraw principal from yield source into this contract
    /// @dev This function withdraws principal tokens from the external protocol to the Portal
    /// @dev It transfers the tokens from the external protocol to the Portal via interface
    /// @dev It emits an Event that tokens have been unstaked
    /// @param _amount The amount of tokens to withdraw
    function _withdrawFromYieldSource(uint256 _amount) private {

        /// @dev Withdraw the staked balance from external protocol using the interface
        IStaking(HLPstakingAddress).withdraw(_amount);

        /// @dev Emit and event that tokens have been unstaked for the user
        emit TokenUnstaked(msg.sender, _amount);
    }


    /// @notice Claim rewards related to HLP and HMX staked by this contract
    /// @dev This function claims staking rewards from the external protocol to the Portal
    /// @dev It transfers the tokens from the external protocol to the Portal via interface
    /// @dev It emits an Event that tokens have been claimed
    function claimRewardsHLPandHMX() external {
        /// @dev Initialize the first input array for the compounder and assign values
        address[] memory pools = new address[](2);
        pools[0] = HLPstakingAddress;
        pools[1] = HMXstakingAddress;

        /// @dev Initialize the second input array for the compounder and assign values    
        address[][] memory rewarders = new address[][](2);
        rewarders[0] = new address[](2);
        rewarders[0][0] = HLPprotocolRewarder;
        rewarders[0][1] = HLPemissionsRewarder;

        rewarders[1] = new address[](3);
        rewarders[1][0] = HMXprotocolRewarder;
        rewarders[1][1] = HMXemissionsRewarder;
        rewarders[1][2] = HMXdragonPointsRewarder;

        /// @dev Claim rewards from HLP and HMX staking via the interface
        /// @dev esHMX and DP rewards are staked automatically, USDC is transferred to contract
        ICompounder(compounderAddress).compound(
            pools,
            rewarders,
            1689206400,
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            new uint256[](0)
        );

        /// @dev Emit event that rewards have been claimed
        emit RewardsClaimed(pools, rewarders, block.timestamp);
    }


    /// @notice If the above claim function breaks in the future, use this function to claim specific rewards
    /// @param _pools The pools to claim rewards from
    /// @param _rewarders The rewarders to claim rewards from
    function claimRewardsManual(address[] memory _pools, address[][] memory _rewarders) external {
        /// @dev claim rewards from any staked token and any rewarder via interface
        /// @dev esHMX and DP rewards are staked automatically, USDC or other reward tokens are transferred to contract
        ICompounder(compounderAddress).compound(
            _pools,
            _rewarders,
            1689206400,
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            new uint256[](0)
        );

        /// @dev Emit event that rewards have been claimed
        emit RewardsClaimed(_pools, _rewarders, block.timestamp);
    }

    // ============================================
    // ==               INTERNAL LP              ==
    // ============================================

    /// @notice Sell PSM into contract to top up portalEnergy balance
    /// @dev This function allows users to sell PSM tokens to the contract to increase their portalEnergy
    /// @dev It checks if the user has a stake and updates the stake data
    /// @dev It checks if the user has enough PSM tokens
    /// @dev It updates the input token reserve and calculates the reserve of portalEnergy (Output)
    /// @dev It calculates the amount of portalEnergy received based on the amount of PSM tokens sold
    /// @dev It checks if the amount of portalEnergy received is greater than or equal to the minimum expected output
    /// @dev It transfers the PSM tokens from the user to the contract
    /// @dev It increases the portalEnergy of the user by the amount of portalEnergy received
    /// @dev It emits a portalEnergyBuyExecuted event
    /// @param _amountInput The amount of PSM tokens to sell
    /// @param _minReceived The minimum amount of portalEnergy to receive
    function buyPortalEnergy(uint256 _amountInput, uint256 _minReceived, uint256 _deadline) external nonReentrant {
        /// @dev Require that the user has a stake
        require(accounts[msg.sender].isExist == true,"User has no stake");

        /// @dev Require that the deadline has not expired
        if (_deadline < block.timestamp) {revert DeadlineExpired();}

        /// @dev Update the stake data of the user
        _updateAccount(msg.sender,0);

        /// @dev Require that the user has enough PSM token
        require(IERC20(tokenToAcquire).balanceOf(msg.sender) >= _amountInput, "Insufficient balance");
        
        /// @dev Calculate the PSM token reserve (input)
        uint256 reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        /// @dev Calculate the reserve of portalEnergy (output)
        uint256 reserve1 = constantProduct / reserve0;

        /// @dev Calculate the amount of portalEnergy received based on the amount of PSM tokens sold
        uint256 amountReceived = (_amountInput * reserve1) / (_amountInput + reserve0);

        /// @dev Require that the amount of portalEnergy received is greater than or equal to the minimum expected output
        require(amountReceived >= _minReceived, "Output too small");

        /// @dev Transfer the PSM tokens from the user to the contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), _amountInput);

        /// @dev Increase the portalEnergy of the user by the amount of portalEnergy received
        accounts[msg.sender].portalEnergy += amountReceived;

        /// @dev Emit the portalEnergyBuyExecuted event with the user's address and the amount of portalEnergy received
        emit portalEnergyBuyExecuted(msg.sender, amountReceived);
    }

    /// @notice Sell portalEnergy into contract to receive PSM
    /// @dev This function allows users to sell their portalEnergy to the contract to receive PSM tokens
    /// @dev It checks if the user has a stake and updates the stake data
    /// @dev It checks if the user has enough portalEnergy to sell
    /// @dev It updates the output token reserve and calculates the reserve of portalEnergy (Input)
    /// @dev It calculates the amount of output token received based on the amount of portalEnergy sold
    /// @dev It checks if the amount of output token received is greater than or equal to the minimum expected output
    /// @dev It reduces the portalEnergy balance of the user by the amount of portalEnergy sold
    /// @dev It sends the output token to the user
    /// @dev It emits a portalEnergySellExecuted event
    /// @param _amountInput The amount of portalEnergy to sell
    /// @param _minReceived The minimum amount of PSM tokens to receive
    function sellPortalEnergy(uint256 _amountInput, uint256 _minReceived, uint256 _deadline) external nonReentrant {
        /// @dev Require that the user has a stake
        require(accounts[msg.sender].isExist == true,"User has no stake");

        /// @dev Require that the deadline has not expired
        if (_deadline < block.timestamp) {revert DeadlineExpired();}

        /// @dev Update the stake data of the user
        _updateAccount(msg.sender,0);
        
        /// @dev Require that the user has enough portalEnergy to sell
        require(accounts[msg.sender].portalEnergy >= _amountInput, "Insufficient balance");

        /// @dev Calculate the PSM token reserve (output)
        uint256 reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        /// @dev Calculate the reserve of portalEnergy (input)
        uint256 reserve1 = constantProduct / reserve0;

        /// @dev Calculate the amount of output token received based on the amount of portalEnergy sold
        uint256 amountReceived = (_amountInput * reserve0) / (_amountInput + reserve1);

        /// @dev Require that the amount of output token received is greater than or equal to the minimum expected output
        require(amountReceived >= _minReceived, "Output too small");

        /// @dev Reduce the portalEnergy balance of the user by the amount of portalEnergy sold
        accounts[msg.sender].portalEnergy -= _amountInput;

        /// @dev Send the output token to the user
        IERC20(tokenToAcquire).safeTransfer(msg.sender, amountReceived);

        /// @dev Emit the portalEnergySellExecuted event with the user's address and the amount of portalEnergy sold
        emit portalEnergySellExecuted(msg.sender, _amountInput);
    }

    /// @notice Simulate buying portalEnergy (output) with PSM tokens (input) and return amount received (output)
    /// @dev This function allows the caller to simulate a portalEnergy buy order of any size
    function quoteBuyPortalEnergy(uint256 _amountInput) public view returns(uint256) { 
        /// @dev Calculate the PSM token reserve (input)
        uint256 reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        /// @dev Calculate the reserve of portalEnergy (output)
        uint256 reserve1 = constantProduct / reserve0;

        /// @dev Calculate the amount of portalEnergy received based on the amount of PSM tokens sold
        uint256 amountReceived = (_amountInput * reserve1) / (_amountInput + reserve0);

        return (amountReceived);
    }


    /// @notice Simulate selling portalEnergy (input) against PSM tokens (output) and return amount received (output)
    /// @dev This function allows the caller to simulate a portalEnergy sell order of any size
    function quoteSellPortalEnergy(uint256 _amountInput) public view returns(uint256) {
        /// @dev Calculate the PSM token reserve (output)
        uint256 reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        /// @dev Calculate the reserve of portalEnergy (input)
        uint256 reserve1 = constantProduct / reserve0;

        /// @dev Calculate the amount of PSM tokens received based on the amount of portalEnergy sold
        uint256 amountReceived = (_amountInput * reserve0) / (_amountInput + reserve1);

        return (amountReceived);
    }

    // ============================================
    // ==              PSM CONVERTER             ==
    // ============================================

    /// @notice Handle the arbitrage conversion of tokens inside the contract for PSM tokens
    /// @dev This function handles the conversion of tokens inside the contract for PSM tokens
    /// @dev It checks if the output token is not the input or stake token (PSM / HLP)
    /// @dev It checks if sufficient output token is available in the contract for frontrun protection
    /// @dev It transfers the input (PSM) token from the user to the contract
    /// @dev It updates the funding reward pool balance and the tracker of collected rewards
    /// @dev It transfers the output token from the contract to the user
    /// @param _token The token to convert
    /// @param _minReceived The minimum amount of tokens to receive
    function convert(address _token, uint256 _minReceived, uint256 _deadline) external nonReentrant {
        /// @dev Require that the output token is not the input or stake token (PSM / HLP)
        require(_token != tokenToAcquire, "Cannot receive the input token");
        require(_token != principalToken, "Cannot receive the stake token");

        /// @dev Require that the deadline has not expired
        if (_deadline < block.timestamp) {revert DeadlineExpired();}

        /// @dev Check if sufficient output token is available in the contract for frontrun protection
        uint256 contractBalance = IERC20(_token).balanceOf(address(this));
        require (contractBalance >= _minReceived, "Not enough tokens in contract");

        /// @dev Transfer the input (PSM) token from the user to the contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), amountToConvert); 

        /// @dev Update the funding reward pool balance and the tracker of collected rewards
        if (bToken.totalSupply() > 0 && fundingRewardsCollected < fundingMaxRewards) {
            uint256 newRewards = (fundingRewardShare * amountToConvert) / 100;
            fundingRewardPool += newRewards;
            fundingRewardsCollected += newRewards;
        }

        /// @dev Transfer the output token from the contract to the user
        IERC20(_token).safeTransfer(msg.sender, contractBalance);
    }

    // ============================================
    // ==              BOOTSTRAPPING             ==
    // ============================================
    
    /// @notice Allow users to deposit PSM to provide initial upfront yield
    /// @dev This function allows users to deposit PSM tokens during the funding phase of the contract
    /// @dev The contract must be the owner of the specific bToken
    /// @dev It checks if the portal is not already active and if the funding phase is ongoing before proceeding
    /// @dev It increases the funding tracker balance by the amount of PSM deposited
    /// @dev It calculates the amount of bTokens to be minted based on the funding reward rate
    /// @dev It transfers the PSM tokens from the user to the contract
    /// @dev It mints bTokens to the user and emits a FundingReceived event
    /// @param _amount The amount of PSM to deposit
    function contributeFunding(uint256 _amount) external nonReentrant {
        /// @dev Require that the deposit amount is greater than zero
        require(_amount > 0, "Invalid amount");
        /// @dev Require that the funding phase is ongoing
        require(isActivePortal == false,"Funding phase concluded");

        /// @dev Increase the funding tracker balance by the amount of PSM deposited
        fundingBalance += _amount;

        /// @dev Calculate the amount of bTokens to be minted based on the funding reward rate
        uint256 mintableAmount = _amount * fundingRewardRate;

        /// @dev Transfer the PSM tokens from the user to the contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), _amount); 

        /// @dev Mint bTokens to the user
        bToken.mint(msg.sender, mintableAmount);

        /// @dev Emit the FundingReceived event with the user's address and the mintable amount
        emit FundingReceived(msg.sender, mintableAmount);
    }


    /// @notice Calculate the current burn value of amount bTokens. Return value is amount PSM tokens
    /// @param _amount The amount of bTokens to burn
    function getBurnValuePSM(uint256 _amount) public view returns(uint256 burnValue) {
        burnValue = (fundingRewardPool * _amount) / bToken.totalSupply();
        return burnValue;
    }


    /// @notice Burn user bTokens to receive PSM
    /// @dev This function allows users to burn bTokens to receive PSM during the active phase of the contract
    /// @dev It checks if the portal is active and if the burn amount is greater than zero before proceeding
    /// @dev It calculates how many PSM the user receives based on the burn amount
    /// @dev It burns the bTokens from the user's balance
    /// @dev It reduces the funding reward pool by the amount of PSM payable to the user
    /// @dev It transfers the PSM to the user
    /// @param _amount The amount of bTokens to burn
    function burnBtokens(uint256 _amount) external nonReentrant {
        /// @dev Require that the burn amount is greater than zero
        require(_amount > 0, "Invalid amount");
        /// @dev Require that the portal is active
        require(isActivePortal == true, "Portal not active");

        /// @dev Calculate how many PSM the user receives based on the burn amount
        uint256 amountToReceive = getBurnValuePSM(_amount);

        /// @dev Burn the bTokens from the user's balance
        bToken.burnFrom(msg.sender, _amount);

        /// @dev Reduce the funding reward pool by the amount of PSM payable to the user
        fundingRewardPool -= amountToReceive;

        /// @dev Transfer the PSM to the user
        IERC20(tokenToAcquire).safeTransfer(msg.sender, amountToReceive);

        /// @dev Event that informs about burn amount and received PSM by the caller
        emit RewardsRedeemed(address(msg.sender), _amount, amountToReceive);
    }


    /// @notice End the funding phase and enable normal contract functionality
    /// @dev This function activates the portal and prepares it for normal operation
    /// @dev It checks if the portal is not already active and if the funding phase is over before proceeding
    /// @dev It calculates the amount of portalEnergy to match the funding amount in the internal liquidity pool
    /// @dev It sets the constant product K, which is used in the calculation of the amount of assets in the liquidity pool
    /// @dev It calculates the maximum rewards to be collected in PSM tokens over time
    /// @dev It activates the portal and emits the PortalActivated event
    /// @dev The PortalActivated event is emitted with the address of the contract and the funding balance
    function activatePortal() external {
        /// @dev Require that the portal is not already active
        require(isActivePortal == false, "Portal already active");
        /// @dev Require that the funding phase is over
        require(block.timestamp >= creationTime + fundingPhaseDuration,"Funding phase ongoing");

        /// @dev Calculate the amount of portalEnergy to match the funding amount in the internal liquidity pool
        uint256 requiredPortalEnergyLiquidity = fundingBalance * fundingExchangeRatio;
        
        /// @dev Set the constant product K, which is used in the calculation of the amount of assets in the liquidity pool
        constantProduct = fundingBalance * requiredPortalEnergyLiquidity;

        /// @dev Calculate the maximum rewards to be collected in PSM tokens over time
        fundingMaxRewards = bToken.totalSupply();

        /// @dev Activate the portal  
        isActivePortal = true;

        /// @dev Emit the PortalActivated event with the address of the contract and the funding balance
        emit PortalActivated(address(this), fundingBalance);
    }

    // ============================================
    // ==           GENERAL FUNCTIONS            ==
    // ============================================
    
    /// @notice Mint portalEnergyToken to recipient and decrease portalEnergy of caller equally
    /// @dev Contract must be owner of the portalEnergyToken
    /// @param _recipient The recipient of the portalEnergyToken
    /// @param _amount The amount of portalEnergyToken to mint
    function mintPortalEnergyToken(address _recipient, uint256 _amount) external nonReentrant {   
        /// @dev Get the current portalEnergy of the user
        (, , , , uint256 portalEnergy,) = getUpdateAccount(msg.sender,0);

        /// @dev Require that the caller has sufficient portalEnergy to mint the amount of portalEnergyToken
        require(portalEnergy >= _amount, "Insufficient portalEnergy");

        ///@dev Update the user´s stake data
        _updateAccount(msg.sender,0);

        /// @dev Reduce the portalEnergy of the caller by the amount of portal energy tokens to be minted
        accounts[msg.sender].portalEnergy -= _amount;

        /// @dev Mint portal energy tokens to the recipient's wallet
        portalEnergyToken.mint(_recipient, _amount);

        /// @dev Emit the event that the ERC20 representation has been minted to recipient
        emit portalEnergyMinted(address(msg.sender), _recipient, _amount);
    }


    /// @notice Burn portalEnergyToken from user wallet and increase portalEnergy of recipient equally
    /// @param _recipient The recipient of the portalEnergy increase
    /// @param _amount The amount of portalEnergyToken to burn
    function burnPortalEnergyToken(address _recipient, uint256 _amount) external nonReentrant {   
        /// @dev Require that the recipient has a stake position
        require(accounts[_recipient].isExist == true,"recipient has no stake");

        /// @dev Require that the caller has sufficient tokens to burn
        require(portalEnergyToken.balanceOf(address(msg.sender)) >= _amount,"Insufficient balance");

        /// @dev Burn portalEnergyToken from the caller's wallet
        portalEnergyToken.burnFrom(msg.sender, _amount);

        ///@dev Update the user´s stake data
        _updateAccount(_recipient,0);

        /// @dev Increase the portalEnergy of the recipient by the amount of portalEnergyToken burned
        accounts[_recipient].portalEnergy += _amount;

        /// @dev Emit the event that the ERC20 representation has been burned and value accrued to recipient
        emit portalEnergyMinted(address(msg.sender), _recipient, _amount);
    }


    /// @notice Burn portalEnergyToken from user wallet and increase portalEnergy of user equally
    /// @dev This function is private and can only be called internally
    /// @param _user The user whose portalEnergy is to be increased
    /// @param _amount The amount of portalEnergyToken to burn
    function _burnPortalEnergyToken(address _user, uint256 _amount) private {   
        /// @dev Require that the user has a stake position
        require(accounts[_user].isExist == true);

        /// @dev Burn portalEnergyToken from the caller's wallet
        portalEnergyToken.burnFrom(_user, _amount);

        /// @dev Increase the portalEnergy of the user by the amount of portalEnergyToken burned
        accounts[_user].portalEnergy += _amount;
    }


    /// @notice Update the maximum lock duration up to the terminal value
    function updateMaxLockDuration() external {
        /// @dev Require that the lock duration can be updated        
        require(lockDurationUpdateable == true,"Lock duration cannot increase");

        /// @dev Calculate new lock duration
        uint256 newValue = 2 * (block.timestamp - creationTime);

        /// @dev Require that the new value will be larger than the existing value
        require(newValue > maxLockDuration,"Duration not ready to update");

        if (newValue >= terminalMaxLockDuration) {
            maxLockDuration = terminalMaxLockDuration;
            lockDurationUpdateable = false;
        } 
        else if (newValue > maxLockDuration) {
            maxLockDuration = newValue;
        }
    }


    /// @notice Simulate updating a user stake position and return the values without updating the struct
    /// @param _user The user whose stake position is to be updated
    /// @param _amount The amount to add to the user's stake position
    /// @dev Returns the simulated up-to-date user stake information
    function getUpdateAccount(address _user, uint256 _amount) public view returns(
        address user,
        uint256 lastUpdateTime,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy,
        uint256 availableToWithdraw) {

        /// @dev Calculate the portalEnergy earned since the last update
        uint256 portalEnergyEarned = (accounts[_user].stakedBalance * 
            (block.timestamp - accounts[_user].lastUpdateTime)) / secondsPerYear;
      
        /// @dev Set the last update time to the current timestamp
        lastUpdateTime = block.timestamp;

        /// @dev Calculate the user's staked balance
        stakedBalance = accounts[_user].stakedBalance + _amount;

        /// @dev Update the user's max stake debt
        maxStakeDebt = accounts[_user].maxStakeDebt + (_amount * maxLockDuration) / secondsPerYear;

        /// @dev Update the user's portalEnergy by adding the portalEnergy earned since the last update
        portalEnergy = accounts[_user].portalEnergy + portalEnergyEarned;

        /// @dev Update the amount available to unstake based on the updated portalEnergy and max stake debt
        if (portalEnergy >= maxStakeDebt) {
            availableToWithdraw = stakedBalance;
        } else {
            availableToWithdraw = (stakedBalance * portalEnergy) / maxStakeDebt;
        }

    return (_user, lastUpdateTime, stakedBalance, maxStakeDebt, portalEnergy, availableToWithdraw);
    }


    /// @notice Simulate forced unstake and return the number of portal energy tokens to be burned      
    /// @param _user The user whose stake position is to be updated for the simulation
    /// @return portalEnergyTokenToBurn Returns the number of portal energy tokens to be burned for a full unstake
    function quoteforceUnstakeAll(address _user) public view returns(uint256 portalEnergyTokenToBurn) {

        /// @dev Get the relevant data from the simulated account update
        (, , , uint256 maxStakeDebt, uint256 portalEnergy,) = getUpdateAccount(_user,0);

        /// @dev Calculate how many portal energy tokens must be burned for a full unstake
        if(maxStakeDebt > portalEnergy) {
            portalEnergyTokenToBurn = maxStakeDebt - portalEnergy;
        }

        /// @dev Return the amount of portal energy tokens to be burned for a full unstake
        return portalEnergyTokenToBurn; 
    }


    /// @notice View balance of tokens inside the contract
    /// @param _token The token for which the balance is to be checked
    /// @return Returns the balance of the specified token inside the contract
    function getBalanceOfToken(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }


    /// @notice View claimable yield from a specific rewarder contract of the yield source
    /// @dev This function allows you to view the claimable yield from a specific rewarder contract of the yield source
    /// @param _rewarder The rewarder contract whose pending reward is to be viewed
    function getPendingRewards(address _rewarder) public view returns(uint256 claimableReward){

        claimableReward = IRewarder(_rewarder).pendingReward(address(this));

        return(claimableReward);
    }
}
