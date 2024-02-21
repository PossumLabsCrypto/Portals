// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import {MintBurnToken} from "./MintBurnToken.sol";
import {IWater} from "./interfaces/IWater.sol";
import {ISingleStaking} from "./interfaces/ISingleStaking.sol";
import {IDualStaking} from "./interfaces/IDualStaking.sol";
import {IPortalV2MultiAsset} from "./interfaces/IPortalV2MultiAsset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Portal V2 Virtual LP
/// @author Possum Labs
/** @notice This contract serves as the shared, virtual LP for multiple Portals
 * Each Portal registers with an individual constantProduct K
 * The full amount of PSM inside the LP is available for each Portal
 * The LP is refilled by convert() calls which exchanges ERC20 balances for PSM
 * The contract is owned for a predetermined time to enable registering more Portals
 * Registering more Portals must be permissioned because it can be malicious
 * Portals cannot be removed from the registry to guarantee Portal integrity
 */

// ============================================
// ==              CUSTOM ERRORS             ==
// ============================================
error InactiveLP();
error ActiveLP();
error NotOwner();
error PortalNotRegistered();
error OwnerNotExpired();
error InsufficientReceived();
error InvalidConstructor();
error InvalidAddress();
error InvalidAmount();
error DeadlineExpired();
error FailedToSendNativeToken();
error FundingPhaseOngoing();
error FundingInsufficient();
error bTokenNotDeployed();
error TokenExists();
error TimeLockActive();
error NoProfit();
error PortalAlreadyRegistered();
error OwnerRevoked();

/// @dev Deployment Process:
/// @dev 1. Deploy VirtualLP, 2. Deploy Portals, 3. Register Portals in VirtualLP
contract VirtualLP is ReentrancyGuard {
    constructor(
        address _owner,
        uint256 _AMOUNT_TO_CONVERT,
        uint256 _FUNDING_PHASE_DURATION,
        uint256 _FUNDING_MIN_AMOUNT
    ) {
        if (_owner == address(0)) {
            revert InvalidConstructor();
        }
        if (_AMOUNT_TO_CONVERT == 0) {
            revert InvalidConstructor();
        }
        if (
            _FUNDING_PHASE_DURATION < 259200 ||
            _FUNDING_PHASE_DURATION > 2592000
        ) {
            revert InvalidConstructor();
        }
        if (_FUNDING_MIN_AMOUNT == 0) {
            revert InvalidConstructor();
        }

        AMOUNT_TO_CONVERT = _AMOUNT_TO_CONVERT;
        FUNDING_PHASE_DURATION = _FUNDING_PHASE_DURATION;
        FUNDING_MIN_AMOUNT = _FUNDING_MIN_AMOUNT;

        owner = _owner;
        OWNER_EXPIRY_TIME = OWNER_DURATION + block.timestamp;

        CREATION_TIME = block.timestamp;
    }

    // ============================================
    // ==            GLOBAL VARIABLES            ==
    // ============================================
    using SafeERC20 for IERC20;

    MintBurnToken public bToken; // the receipt token for funding the Portal

    uint256 constant SECONDS_PER_YEAR = 31536000; // seconds in a 365 day year
    uint256 constant MAX_UINT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935;

    address public owner;
    uint256 private constant OWNER_DURATION = 31536000; // 1 Year
    uint256 public immutable OWNER_EXPIRY_TIME; // Time required to pass before owner can be revoked
    uint256 public immutable AMOUNT_TO_CONVERT; // fixed amount of PSM tokens required to withdraw yield in the contract
    uint256 public immutable FUNDING_PHASE_DURATION; // seconds after deployment before Portal can be activated
    uint256 public immutable FUNDING_MIN_AMOUNT; // minimum funding required before Portal can be activated
    uint256 public immutable CREATION_TIME; // time stamp of deployment

    uint256 constant FUNDING_APR = 36; // annual redemption value increase (APR) of bTokens
    uint256 constant FUNDING_MAX_RETURN_PERCENT = 1000; // maximum redemption value percent of bTokens (must be >100)
    uint256 constant FUNDING_REWARD_SHARE = 10; // 10% of yield goes to the funding pool until investors are paid back

    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5; // address of PSM token
    address constant SINGLE_STAKING =
        0x314223E2fA375F972E159002Eb72A96301E99e22;
    address constant DUAL_STAKING = 0x31Fa38A6381e9d1f4770C73AB14a0ced1528A65E;
    address constant esVKA = 0x95b3F9797077DDCa971aB8524b439553a220EB2A;

    bool public isActiveLP; // Will be set to true when funding phase ends
    bool public bTokenCreated; // flag for bToken deployment
    uint256 public fundingBalance; // sum of all PSM funding contributions
    uint256 public fundingRewardPool; // amount of PSM available for redemption against bTokens

    mapping(address portal => bool isRegistered) public registeredPortals;
    mapping(address portal => mapping(address asset => address vault))
        public vaults;
    mapping(address portal => mapping(address asset => uint256 pid))
        public poolID;

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event LP_Activated(address indexed, uint256 fundingBalance);
    event ConvertExecuted(
        address indexed token,
        address indexed caller,
        address indexed recipient,
        uint256 amount
    );

    event bTokenDeployed(address bToken);
    event FundingReceived(address indexed, uint256 amount);
    event FundingWithdrawn(address indexed, uint256 amount);
    event RewardsRedeemed(
        address indexed,
        uint256 amountBurned,
        uint256 amountReceived
    );

    // ============================================
    // ==               MODIFIERS                ==
    // ============================================
    modifier activeLP() {
        if (!isActiveLP) {
            revert InactiveLP();
        }
        _;
    }

    modifier inactiveLP() {
        if (isActiveLP) {
            revert ActiveLP();
        }
        _;
    }

    modifier registeredPortal() {
        /// @dev Check that the caller is a registered address (Portal)
        if (!registeredPortals[msg.sender]) {
            revert PortalNotRegistered();
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    // ============================================
    // ==             LP FUNCTIONS               ==
    // ============================================
    /// @notice This function transfers PSM to a recipient address
    /// @dev Can only be called by a registered address (Portal)
    /// @dev All critical logic is handled by the Portal, hence no additional checks
    function PSM_sendToPortalUser(
        address _recipient,
        uint256 _amount
    ) external nonReentrant registeredPortal {
        /// @dev Transfer PSM to the recipient
        IERC20(PSM_ADDRESS).transfer(_recipient, _amount);
    }

    /// @notice Function to add new Portals to the registry
    /// @dev Portals can only be added, never removed
    /// @dev Only callable by owner to prevent malicious Portals
    /// @dev Function can override existing registries to correct potential errors
    function registerPortal(
        address _portal,
        address _asset,
        address _vault,
        uint256 _pid
    ) external onlyOwner {
        ///@dev register Portal so that it can call permissioned functions
        registeredPortals[_portal] = true;

        /// @dev update the Portal asset mappings
        vaults[_portal][_asset] = _vault;
        poolID[_portal][_asset] = _pid;
    }

    /// @notice This function disables the ownership access
    /// @dev Set the zero address as owner
    /// @dev Callable by anyone after duration passed
    function removeOwner() external {
        if (block.timestamp < OWNER_EXPIRY_TIME) {
            revert OwnerNotExpired();
        }
        if (owner == address(0)) {
            revert OwnerRevoked();
        }

        owner = address(0);
    }

    // ============================================
    // ==      EXTERNAL PROTOCOL INTEGRATION     ==
    // ============================================
    /// @notice Deposit principal into the yield source
    /// @dev This function deposits principal tokens from the Portal into the external protocol
    /// @dev Transfer the tokens from the Portal to the external protocol via interface
    function depositToYieldSource(
        address _asset,
        uint256 _amount
    ) external registeredPortal {
        /// @dev Check that timeLock is zero to protect from griefing attack
        if (IWater(vaults[msg.sender][_asset]).lockTime() > 0) {
            revert TimeLockActive();
        }

        /// @dev Deposit Token into Vault to receive Shares (WATER)
        /// @dev Approval of token spending is handled with separate function to save gas
        uint256 depositShares = IWater(vaults[msg.sender][_asset]).deposit(
            _amount,
            address(this)
        );

        /// @dev Stake the Vault Shares into the staking contract using the pool identifier (pid)
        /// @dev Approval of token spending is handled with separate function to save gas
        ISingleStaking(SINGLE_STAKING).deposit(
            poolID[msg.sender][_asset],
            depositShares
        );
    }

    /// @notice Withdraw principal from the yield source to the Portal
    /// @dev This function withdraws principal tokens from the external protocol to the Portal
    /// @dev It transfers the tokens from the external protocol to the Portal via interface
    /// @param _amount The amount of tokens to withdraw
    function withdrawFromYieldSource(
        address _asset,
        address _user,
        uint256 _amount
    ) external registeredPortal {
        /// @dev Calculate number of Vault Shares that equal the withdraw amount
        uint256 withdrawShares = IWater(vaults[msg.sender][_asset])
            .convertToShares(_amount);

        /// @dev Get the withdrawable assets from burning Vault Shares (consider rounding)
        uint256 withdrawAssets = IWater(vaults[msg.sender][_asset])
            .convertToAssets(withdrawShares);

        /// @dev Initialize helper variables for withdraw amount sanity check
        uint256 balanceBefore;
        uint256 balanceAfter;

        /// @dev Withdraw Vault Shares from Single Staking Contract
        ISingleStaking(SINGLE_STAKING).withdraw(
            poolID[msg.sender][_asset],
            withdrawShares
        );

        /// @dev Check if handling native ETH
        if (_asset == address(0)) {
            /// @dev Withdraw the staked ETH from Vault
            balanceBefore = address(this).balance;
            IWater(vaults[msg.sender][_asset]).withdrawETH(withdrawAssets);
            balanceAfter = address(this).balance;

            /// @dev Sanity check on obtained amount from Vault
            _amount = balanceAfter - balanceBefore;

            /// @dev Transfer the obtained ETH to the user
            (bool sent, ) = payable(_user).call{value: _amount}("");
            if (!sent) {
                revert FailedToSendNativeToken();
            }
        }

        /// @dev Check if handling ERC20 token
        if (_asset != address(0)) {
            /// @dev Withdraw the staked assets from Vault
            balanceBefore = IERC20(_asset).balanceOf(address(this));
            IWater(vaults[msg.sender][_asset]).withdraw(
                withdrawAssets,
                address(this),
                address(this)
            );
            balanceAfter = IERC20(_asset).balanceOf(address(this));

            /// @dev Sanity check on obtained amount from Vault
            _amount = balanceAfter - balanceBefore;

            /// @dev Transfer the obtained assets to the user
            IERC20(_asset).safeTransfer(_user, _amount);
        }
    }

    /// @dev Claim pending esVKA and USDC rewards, restake esVKA
    function claimRewards(address _portal) external {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        // Claim esVKA rewards from staking the asset
        ISingleStaking(SINGLE_STAKING).deposit(poolID[_portal][asset], 0);

        uint256 esVKABalance = IERC20(esVKA).balanceOf(address(this));

        // Stake esVKA
        // Approval of token spending is handled with separate function to save gas
        if (esVKABalance > 0) {
            IDualStaking(DUAL_STAKING).stake(esVKABalance, esVKA);
        }

        // Claim esVKA and USDC from DualStaking, stake the esVKA reward and send USDC to contract
        IDualStaking(DUAL_STAKING).compound();
    }

    /// @dev Get the surplus assets in the Vault excluding withdrawal fee for internal use
    function _getProfitOfPortal(
        address _portal
    ) private view returns (uint256 profitAsset, uint256 profitShares) {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        /// @dev Get the Vault shares owned by Portal
        uint256 sharesOwned = ISingleStaking(SINGLE_STAKING).getUserAmount(
            poolID[_portal][asset],
            address(this)
        );

        /// @dev Calculate the shares to be reserved for user withdrawals
        uint256 sharesDebt = IWater(vaults[_portal][asset]).convertToShares(
            portal.totalPrincipalStaked()
        );

        /// @dev Calculate the surplus shares owned by the Portal
        profitShares = (sharesOwned > sharesDebt)
            ? sharesOwned - sharesDebt
            : 0;

        /// @dev Calculate the net profit in assets
        profitAsset = IWater(vaults[_portal][asset]).convertToAssets(
            profitShares
        );
    }

    /// @dev Show the surplus assets in the Vault after deducting withdrawal fees
    /// @dev May underestimate the real reward slightly due to precision limit
    function getProfitOfPortal(
        address _portal
    ) external view returns (uint256 profitOfAsset) {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        (uint256 profit, ) = _getProfitOfPortal(_portal);

        uint256 denominator = IWater(vaults[_portal][asset]).DENOMINATOR();
        uint256 withdrawalFee = IWater(vaults[_portal][asset]).withdrawalFees();

        profitOfAsset = (profit * (denominator - withdrawalFee)) / denominator;
    }

    /// @dev Withdraw the asset surplus from Vault to contract
    function collectProfitOfPortal(address _portal) public {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        (uint256 profit, uint256 shares) = _getProfitOfPortal(_portal);

        /// @dev Check if there is profit to withdraw
        if (profit == 0 || shares == 0) {
            revert NoProfit();
        }

        /// @dev Withdraw the surplus Vault Shares from Single Staking Contract
        ISingleStaking(SINGLE_STAKING).withdraw(poolID[_portal][asset], shares);

        /// @dev Withdraw the profit Assets from the Vault to contract (collects WETH from ETH Vault)
        IWater(vaults[_portal][asset]).withdraw(
            profit,
            address(this),
            address(this)
        );
    }

    /// @notice Read the pending USDC protocol rewards earned by the LP
    /// @dev Get current USDC rewards pending from protocol fees
    function getPendingRewardsUSDC() external view returns (uint256 rewards) {
        rewards = IDualStaking(DUAL_STAKING).pendingRewardsUSDC(address(this));
    }

    function getPortalVaultLockTime(
        address _portal
    ) public view returns (uint256 lockTime) {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        lockTime = IWater(vaults[_portal][asset]).lockTime();
    }

    /// @dev This function allows to update the Boost Multiplier to earn more esVKA
    function updatePortalBoostMultiplier(address _portal) public {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        ISingleStaking(SINGLE_STAKING).updateBoostMultiplier(
            address(this),
            poolID[_portal][asset]
        );
    }

    // Increase the token spending allowance of Assets by the associated Vault (WATER)
    function increaseAllowanceVault(address _portal) public {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        // Allow spending of Assets by the associated Vault
        address tokenAdr = (asset == address(0)) ? WETH_ADDRESS : asset;
        IERC20(tokenAdr).safeIncreaseAllowance(
            vaults[_portal][asset],
            MAX_UINT
        );
    }

    // Increase the token spending allowance of Vault Shares by the Single Staking contract
    function increaseAllowanceSingleStaking(address _portal) public {
        /// @dev Get the asset of the Portal
        IPortalV2MultiAsset portal = IPortalV2MultiAsset(_portal);
        address asset = portal.PRINCIPAL_TOKEN_ADDRESS();

        // Allow spending of Vault shares of an asset by the single staking contract
        IERC20(vaults[_portal][asset]).safeIncreaseAllowance(
            SINGLE_STAKING,
            MAX_UINT
        );
    }

    // Increase the token spending allowance of esVKA by the Dual Staking contract
    function increaseAllowanceDualStaking() public {
        // Allow spending of esVKA by the Dual Staking contract
        IERC20(esVKA).safeIncreaseAllowance(DUAL_STAKING, MAX_UINT);
    }

    // ============================================
    // ==              PSM CONVERTER             ==
    // ============================================
    /// @notice Handle the arbitrage conversion of tokens inside the contract for PSM tokens
    /// @dev This function handles the conversion of tokens inside the contract for PSM tokens
    /// @dev Collect rewards for funders and reallocate reward overflow to the LP (indirect)
    /// @dev Transfer the input (PSM) token from the caller to the contract
    /// @dev Transfer the specified output token from the contract to the caller
    /// @param _token The token to be obtained by the recipient
    /// @param _minReceived The minimum amount of tokens received
    function convert(
        address _token,
        address _recipient,
        uint256 _minReceived,
        uint256 _deadline
    ) external nonReentrant activeLP {
        /// @dev Check the validity of token and recipient addresses
        if (_token == PSM_ADDRESS || _recipient == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Prevent zero value
        if (_minReceived == 0) {
            revert InvalidAmount();
        }

        /// @dev Check that the deadline has not expired
        if (_deadline < block.timestamp) {
            revert DeadlineExpired();
        }

        /// @dev Get the contract balance of the specified token
        uint256 contractBalance;
        if (_token == address(0)) {
            contractBalance = address(this).balance;
        } else {
            contractBalance = IERC20(_token).balanceOf(address(this));
        }

        /// @dev Check that enough output tokens are available for frontrun protection
        if (contractBalance < _minReceived) {
            revert InsufficientReceived();
        }

        /// @dev initialize helper variables
        uint256 maxRewards = (bToken.totalSupply() *
            FUNDING_MAX_RETURN_PERCENT) / 100;
        uint256 newRewards = (AMOUNT_TO_CONVERT * FUNDING_REWARD_SHARE) / 100;

        /// @dev Check if rewards must be added, adjust reward pool accordingly
        if (fundingRewardPool + newRewards >= maxRewards) {
            fundingRewardPool = maxRewards;
        } else {
            fundingRewardPool += newRewards;
        }

        /// @dev transfer PSM to the LP
        IERC20(PSM_ADDRESS).transferFrom(
            msg.sender,
            address(this),
            AMOUNT_TO_CONVERT
        );

        /// @dev Transfer the output token from the contract to the recipient
        if (_token == address(0)) {
            (bool sent, ) = payable(_recipient).call{value: contractBalance}(
                ""
            );
            if (!sent) {
                revert FailedToSendNativeToken();
            }
        } else {
            IERC20(_token).safeTransfer(_recipient, contractBalance);
        }

        emit ConvertExecuted(_token, msg.sender, _recipient, contractBalance);
    }

    // ============================================
    // ==                FUNDING                 ==
    // ============================================
    /// @notice End the funding phase and enable normal contract functionality
    /// @dev This function activates the portal and initializes the internal LP
    /// @dev Can only be called when the Portal is inactive
    /// @dev Calculate the constant product K, which is used to initialize the internal LP
    function activateLP() external inactiveLP {
        /// @dev Check that the funding phase is over and enough funding has been contributed
        if (block.timestamp < CREATION_TIME + FUNDING_PHASE_DURATION) {
            revert FundingPhaseOngoing();
        }
        if (fundingBalance < FUNDING_MIN_AMOUNT) {
            revert FundingInsufficient();
        }

        /// @dev Activate the portal
        isActiveLP = true;

        /// @dev Emit the PortalActivated event with the address of the contract and the funding balance
        emit LP_Activated(address(this), fundingBalance);
    }

    /// @notice Allow users to deposit PSM to provide the initial upfront yield
    /// @dev This function allows users to deposit PSM tokens during the funding phase
    /// @dev The bToken must have been deployed via the contract in advance
    /// @dev Increase the fundingBalance tracker by the amount of PSM deposited
    /// @dev Transfer the PSM tokens from the user to the contract
    /// @dev Mint bTokens to the user
    /// @param _amount The amount of PSM to deposit
    function contributeFunding(uint256 _amount) external inactiveLP {
        /// @dev Prevent zero amount transaction
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Calculate the amount of bTokens to be minted based on the maximum return
        uint256 mintableAmount = (_amount * FUNDING_MAX_RETURN_PERCENT) / 100;

        /// @dev Increase the funding tracker balance by the amount of PSM deposited
        fundingBalance += _amount;

        /// @dev Transfer the PSM tokens from the user to the contract
        IERC20(PSM_ADDRESS).transferFrom(msg.sender, address(this), _amount);

        /// @dev Mint bTokens to the user
        bToken.mint(msg.sender, mintableAmount);

        /// @dev Emit the FundingReceived event with the user's address and the mintable amount
        emit FundingReceived(msg.sender, mintableAmount);
    }

    /// @notice Allow users to burn bTokens to recover PSM funding before the Portal is activated
    /// @dev This function allows users to withdraw PSM tokens during the funding phase of the contract
    /// @dev The bToken must have been deployed via the contract in advance
    /// @dev Decrease the fundingBalance tracker by the amount of PSM withdrawn
    /// @dev Burn the appropriate amount of bTokens from the caller
    /// @dev Transfer the PSM tokens from the contract to the caller
    /// @param _amount The amount of bTokens burned to withdraw PSM
    function withdrawFunding(uint256 _amount) external inactiveLP {
        /// @dev Prevent zero amount transaction
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Calculate the amount of PSM returned to the user
        uint256 withdrawAmount = (_amount * 100) / FUNDING_MAX_RETURN_PERCENT;

        /// @dev Decrease the fundingBalance tracker by the amount of PSM withdrawn
        fundingBalance -= withdrawAmount;

        /// @dev Transfer the PSM tokens from the contract to the user
        IERC20(PSM_ADDRESS).transfer(msg.sender, withdrawAmount);

        /// @dev Burn bTokens from the user
        bToken.burnFrom(msg.sender, _amount);

        /// @dev Emit the FundingReceived event with the user's address and the mintable amount
        emit FundingWithdrawn(msg.sender, withdrawAmount);
    }

    /// @notice Calculate the current burn value of bTokens
    /// @param _amount The amount of bTokens to burn
    /// @return burnValue The amount of PSM received when redeeming bTokens
    function getBurnValuePSM(
        uint256 _amount
    ) public view activeLP returns (uint256 burnValue) {
        /// @dev Calculate the minimum burn value
        uint256 minValue = (_amount * 100) / FUNDING_MAX_RETURN_PERCENT;

        /// @dev Calculate the time based burn value
        uint256 accruedValue = (_amount *
            (block.timestamp - CREATION_TIME) *
            FUNDING_APR) / (100 * SECONDS_PER_YEAR);

        /// @dev Calculate the maximum and current burn value
        uint256 maxValue = (_amount * FUNDING_MAX_RETURN_PERCENT) / 100;
        uint256 currentValue = minValue + accruedValue;

        burnValue = (currentValue < maxValue) ? currentValue : maxValue;
    }

    /// @notice Get the amount of bTokens that can be burned against the reward Pool
    /// @dev Calculate how many bTokens can be burned to redeem the full reward Pool
    /// @return amountBurnable The amount of bTokens that can be redeemed for rewards
    function getBurnableBtokenAmount()
        public
        view
        activeLP
        returns (uint256 amountBurnable)
    {
        /// @dev Calculate the burn value of 1 full bToken in PSM
        /// @dev Add 1 WEI to handle potential rounding issue in the next step
        uint256 burnValueFullToken = getBurnValuePSM(1e18) + 1;

        /// @dev Calculate and return the amount of bTokens burnable
        /// @dev Because of the 1 WEI above, this will slightly underestimate for safety reasons
        uint256 rewards = IERC20(PSM_ADDRESS).balanceOf(address(this));
        amountBurnable = (rewards * 1e18) / burnValueFullToken;
    }

    /// @notice Users redeem bTokens for PSM tokens
    /// @dev This function allows users to burn bTokens to receive PSM when the Portal is active
    /// @dev Reduce the funding reward pool by the amount of PSM payable to the user
    /// @dev Burn the bTokens from the user's wallet
    /// @dev Transfer the PSM tokens to the user
    /// @param _amount The amount of bTokens to burn
    function burnBtokens(uint256 _amount) external {
        /// @dev Check that the burn amount is not zero
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Check that the burn amount is not larger than what can be redeemed
        uint256 burnable = getBurnableBtokenAmount();
        if (_amount > burnable) {
            revert InvalidAmount();
        }

        /// @dev Calculate how many PSM the user receives based on the burn amount
        uint256 amountToReceive = getBurnValuePSM(_amount);

        /// @dev Reduce the funding reward pool by the amount of PSM payable to the user
        fundingRewardPool -= amountToReceive;

        /// @dev Burn the bTokens from the user's balance
        bToken.burnFrom(msg.sender, _amount);

        /// @dev Transfer the PSM to the user
        IERC20(PSM_ADDRESS).transfer(msg.sender, amountToReceive);

        /// @dev Event that informs about burn amount and received PSM by the caller
        emit RewardsRedeemed(msg.sender, _amount, amountToReceive);
    }

    // ============================================
    // ==           GENERAL FUNCTIONS            ==
    // ============================================
    /// @notice Deploy the bToken of this Portal
    /// @dev This function deploys the bToken of this Portal with the Portal as owner
    /// @dev Must be called before Portal is activated
    /// @dev Can only be called once
    function create_bToken() external inactiveLP {
        if (bTokenCreated) {
            revert TokenExists();
        }

        /// @dev Update the token creation flag to prevent future calls.
        bTokenCreated = true;

        /// @dev Set the token name and symbol
        string memory name = "bVaultkaLending";
        string memory symbol = "bVKA-L";

        /// @dev Deploy the token and update the related storage variable so that other functions can work.
        bToken = new MintBurnToken(name, symbol);

        emit bTokenDeployed(address(bToken));
    }
}
